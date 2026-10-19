#!/usr/bin/env python3
"""Fleet GCP database migration gate (verified-zero controller).

Invoked by terraform_data.fleet_migration_gate (cloud_run.tf) as

    python3 fleet_migration_gate.py run

with non-secret configuration in FLEET_GATE_* environment variables. It runs
the Fleet migration Cloud Run job (`fleet prepare db`) only while no Fleet
server instance can exist, and lets Fleet start again only after the migration
is verified successful. Every unknown fails closed for the current apply.

Upgrade path (the Cloud Run service exists):

 1. Read-only preflight: service, job, every job execution (cross-checked with
    the job's latestCreatedExecution), every revision (showDeleted=true) and
    Cloud Monitoring telemetry coverage. A prior execution that is running or
    not yet consistently visible is waited for (bounded, read-only), never
    treated as absent. Nothing is changed when a precondition fails.
 2. Claim: one etag-guarded job write records this run's ownership on the job
    annotation fleetdm.com/migration-gate. The read-back etag is the one :run
    is later sent with, so a :run prepared earlier with an older etag cannot
    match it. The execution inventory is re-read and must be settled.
 3. Stop: one etag-guarded PATCH sets service scaling to MANUAL with
    manualInstanceCount=0 and minInstanceCount=0 and, in the same write,
    records this run's checkpoint (run id, phase, pre-migration scaling) in
    the service annotation fleetdm.com/migration-gate.
 4. Verified zero: every revision from revisions.list(showDeleted=true) and
    every revision in the returned telemetry must report explicit raw
    run.googleapis.com/container/instance_count points active=0 AND idle=0 at
    the same measurement timestamp, strictly after a conservative server-clock
    fence (HTTP Date + 1 s of the stop confirmation). Missing, stale, partial,
    erroring or non-zero telemetry blocks the migration.
 5. Exactly one job execution (:run with the claimed job etag, never retried
    within an apply), launched only after the job is re-read as claimed and
    the complete execution inventory is re-listed, and polled to verified
    success: operation, execution counts and conditions, and the single
    task's completion and exit code.
    Image identity: the job and service templates must carry the configured
    image string exactly; the execution, task and serving revision may report
    it as Google resolved it (same canonical repository, configured tag or a
    sha256 digest), and every digest reported in the run must be the same
    (see "Image references" below).
 6. Resume: while still MANUAL/0, deploy the new image together with the
    serving env (MySQL/Redis addresses, secret references) and CMEK key taken
    from the migration job, which Terraform built from the same locals as the
    service; wait for a new Ready revision that runs exactly that and serves
    100% with no tags (or, if the service already runs it on a Ready latest
    revision, verify that revision instead), then restore the recorded
    pre-migration scaling. The job and its executions are re-verified before
    and during this step.

Fresh bootstrap path (the service does not exist): run the migration only when
no service named FLEET_GATE_SERVICE exists, including soft-deleted services
(services.list showDeleted=true), no telemetry exists for it in the lookback
window, and every job execution has settled. Ownership is claimed on the job
annotation (etag-guarded) and completed after the verified migration. Every
bootstrap run proves absence afresh and runs one fresh migration; an earlier
record never blocks it and never substitutes for it.

Automatic recovery: there is no operator recovery procedure and the checkpoint
is never a lock. When an apply fails (Terraform taints the gate resource), the
next apply runs the gate again under a new run id. A service that an earlier
run left stopped under a valid unfinished record keeps that record's
pre-migration scaling; the new run claims the job and the service, proves zero
afresh, runs at most one fresh migration, redeploys (including a fresh
explicit revision name when an earlier rollout of the unchanged template
failed) and restores the original scaling only after the migration and a
matching Ready revision are verified. Prior executions that are still running
or not consistently visible make the run wait (bounded) and then fail without
starting anything; a later apply re-checks. Every write that could clobber a
successor (restop, bootstrap completion, phase writes) is sent with the etag
of a read that still shows this run's own record in the expected phase. The
controller never resumes after an unverified migration, never restarts the old
image, never repairs or rolls back SQL, and never guesses scaling.

Trust boundary: Google's documented Cloud Run / Monitoring semantics (etag
preconditions, complete listings, latestCreatedExecution), and no other
writer (person, CI, controller) touching the service or job while the gate
runs. Etag compare-and-swap, the ownership record and the Terraform state lock
detect or prevent ordinary concurrent writers and stale requests from an
earlier controller; they are an engineering safeguard built on documented
behavior, not a proof that every request accepted before a takeover is already
visible, and they do not defend against a malicious administrator or a
platform bug.

Authentication uses Application Default Credentials through
`gcloud auth application-default print-access-token` at runtime. The token is
never logged, written or embedded in Terraform state. API payloads are never
logged because they contain environment variables.

Importing this module has no side effects.
"""

import datetime
import email.utils
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RUN_API = "https://run.googleapis.com/v2"
MONITORING_API = "https://monitoring.googleapis.com/v3"
INSTANCE_COUNT_METRIC = "run.googleapis.com/container/instance_count"
CHECKPOINT_ANNOTATION = "fleetdm.com/migration-gate"
CHECKPOINT_VERSION = 1

# Phases recorded in the checkpoint annotation. The record is internal,
# resumable metadata written by the gate itself: a later run reads an earlier
# run's unfinished service record only to keep its pre-migration scaling, then
# claims it. It is never an operator-maintained lock.
PHASE_STOPPED = "stopped"
PHASE_MIGRATING = "migrating"
PHASE_MIGRATED = "migrated"
PHASE_ROLLING_OUT = "rolling-out"
PHASE_COMPLETED = "completed"
PHASE_FAILED = "failed"
PHASE_BOOTSTRAP_MIGRATING = "bootstrap-migrating"
PHASE_CLAIMED = "claimed"  # job ownership record of an upgrade run
# Service phases in which an earlier run left Fleet stopped (or meant to).
SERVICE_UNFINISHED_PHASES = frozenset({PHASE_STOPPED, PHASE_MIGRATING, PHASE_MIGRATED, PHASE_ROLLING_OUT, PHASE_FAILED})

CONDITION_SUCCEEDED = "CONDITION_SUCCEEDED"
CONDITION_FAILED = "CONDITION_FAILED"
TRAFFIC_LATEST = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"

NANOS = 1_000_000_000

# Bounded timeouts (seconds). Not configurable: there is no skip, dry-run or
# force switch.
HTTP_TIMEOUT = 30
GET_ATTEMPTS = 4
TOKEN_MAX_AGE = 300
OPERATION_TIMEOUT = 600
OPERATION_POLL = 5
ZERO_TIMEOUT = 1200
ZERO_POLL = 30
MIGRATION_MARGIN = 900
MIGRATION_POLL = 15
ROLLOUT_TIMEOUT = 900
ROLLOUT_POLL = 10
COVERAGE_LOOKBACK = 1800
BOOTSTRAP_LOOKBACK = 3600
# Telemetry time bounds (see analyze_zero): a point may only count toward the
# proof if it ends at or before the query's endTime, which is itself an HTTP
# Date (floored to the second) already observed from Google. A point dated one
# second or more after the Date of the response that returned it is
# necessarily in the future and fails the gate as a clock anomaly; a point in
# the fractional second after that Date is ignored until a later query.

# Fields the Cloud Run Admin API v2 marks output-only. They are stripped from
# full-resource PATCH bodies (the server ignores them anyway); etag is kept for
# compare-and-swap.
SERVICE_OUTPUT_ONLY = (
    "uid", "generation", "createTime", "updateTime", "deleteTime",
    "expireTime", "creator", "lastModifier", "observedGeneration",
    "terminalCondition", "conditions", "latestReadyRevision",
    "latestCreatedRevision", "trafficStatuses", "uri", "urls", "reconciling",
    "satisfiesPzs",
)
JOB_OUTPUT_ONLY = (
    "uid", "generation", "createTime", "updateTime", "deleteTime",
    "expireTime", "creator", "lastModifier", "observedGeneration",
    "terminalCondition", "conditions", "executionCount",
    "latestCreatedExecution", "reconciling", "satisfiesPzs",
)
# Writing either of these on a job update starts an execution; they must never
# be present or sent.
JOB_EXECUTION_TOKENS = ("startExecutionToken", "runExecutionToken")

# HTTP statuses after which a write is known not to have been applied. Every
# other failure (5xx, 408, 429, transport errors, malformed bodies) leaves the
# write outcome unknown.
DEFINITIVE_REJECTIONS = (400, 401, 403, 404, 409, 412)

# Fleet state reported on failure.
FLEET_UNCHANGED = "unchanged: the gate did not modify the Fleet service"
FLEET_RESTART_DISABLED = (
    "restart disabled: desired scaling read back as MANUAL/0 under this run's record; "
    "actual instance zero is NOT verified (no current complete measured-zero proof)"
)
FLEET_MEASURED_ZERO = (
    "stopped: desired scaling read back as MANUAL/0 under this run's record, a complete measured zero "
    "(active=0 and idle=0 for every revision) was verified after the stop, and the service configuration "
    "is unchanged since"
)
FLEET_STATE_UNKNOWN = "UNKNOWN: the service state could not be verified; inspect it now"
FLEET_NOT_STOPPED = ("NOT verified stopped: the service is not MANUAL/0 under this run's record "
                     "(another writer, or a partial restore); inspect it now")
FLEET_NOT_CREATED = "not created (fresh bootstrap; Terraform creates the service only after the gate succeeds)"
FLEET_PRIOR_STOP = ("unchanged by this run: still MANUAL/0 under an earlier run's gate record (restart disabled; "
                    "actual instance zero is NOT re-verified)")
FLEET_TAKEN_OVER = ("MANUAL/0 under another run's gate record: a later run has taken over the service; this run no "
                    "longer changes it")

MIGRATION_NOT_RUN = "not run"
MIGRATION_FAILED = "FAILED"
MIGRATION_UNKNOWN = "UNKNOWN (it may have started, may still be running, or may have finished)"
MIGRATION_SUCCEEDED = "succeeded (verified)"


class GateError(Exception):
    """A fail-closed stop of the gate. Carries what is known about Fleet."""

    def __init__(self, message, fleet=FLEET_UNCHANGED, migration=MIGRATION_NOT_RUN):
        super().__init__(message)
        self.message = message
        self.fleet = fleet
        self.migration = migration


class TransportError(Exception):
    """The request may or may not have reached the server."""


class ApiError(Exception):
    """A non-2xx response or an unusable response body."""

    def __init__(self, method, label, status, rpc_status=None, definitive=False):
        detail = f"HTTP {status}" if status else "no usable response"
        if rpc_status:
            detail += f" {rpc_status}"
        super().__init__(f"{method} {label}: {detail}")
        self.status = status
        self.rpc_status = rpc_status
        self.definitive = definitive


class WriteOutcomeUnknown(Exception):
    """A write may or may not have been applied."""


# --------------------------------------------------------------------------
# Runtime dependencies (real implementations; tests inject fakes)
# --------------------------------------------------------------------------


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = {k.lower(): v for k, v in (headers or {}).items()}
        self.body = body


class UrllibTransport:
    def request(self, method, url, headers, body):
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                return Response(resp.status, dict(resp.headers.items()), resp.read())
        except urllib.error.HTTPError as err:
            try:
                data = err.read()
            except Exception:  # pragma: no cover - defensive
                data = b""
            return Response(err.code, dict(err.headers.items()) if err.headers else {}, data)
        except Exception as err:  # URLError, timeouts, connection resets
            raise TransportError(type(err).__name__) from None


class GcloudAdcTokenSource:
    """Mints ADC access tokens through the gcloud CLI at runtime."""

    def token(self):
        gcloud = shutil.which("gcloud")
        if not gcloud:
            raise GateError("gcloud CLI not found on PATH; it is required for Application Default Credentials")
        try:
            proc = subprocess.run(
                [gcloud, "auth", "application-default", "print-access-token"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as err:
            raise GateError(f"gcloud ADC token command failed to run ({type(err).__name__})") from None
        if proc.returncode != 0:
            raise GateError(f"gcloud ADC token command failed (exit {proc.returncode}); run `gcloud auth application-default login`")
        token = proc.stdout.decode("utf-8", "replace").strip()
        if not token or any(c.isspace() for c in token):
            raise GateError("gcloud ADC token command returned no usable token")
        return token


class SystemClock:
    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


def stderr_log(message):
    print(f"[fleet-migration-gate] {message}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------


def parse_rfc3339_ns(value):
    """RFC 3339 'Z' timestamp -> integer nanoseconds since the epoch."""
    if not isinstance(value, str):
        raise ValueError("timestamp is not a string")
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z", value)
    if not m:
        raise ValueError("timestamp is not RFC 3339 UTC")
    base = datetime.datetime(
        int(m.group(1)), int(m.group(2)), int(m.group(3)),
        int(m.group(4)), int(m.group(5)), int(m.group(6)),
        tzinfo=datetime.timezone.utc,
    )
    seconds = (base - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)) // datetime.timedelta(seconds=1)
    frac = (m.group(7) or "").ljust(9, "0")
    return seconds * NANOS + int(frac or "0")


def format_rfc3339_ns(ns):
    seconds, frac = divmod(ns, NANOS)
    base = datetime.datetime.fromtimestamp(seconds, tz=datetime.timezone.utc)
    return base.strftime("%Y-%m-%dT%H:%M:%S") + f".{frac:09d}Z"


def parse_http_date_ns(value):
    """HTTP Date header (second precision) -> nanoseconds; None if unusable."""
    if not value:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError, IndexError):
        return None
    if parsed is None or parsed.tzinfo is None or parsed.utcoffset() != datetime.timedelta(0):
        return None
    return int(parsed.timestamp()) * NANOS


def parse_duration_seconds(value):
    if not isinstance(value, str):
        raise ValueError("duration is not a string")
    m = re.fullmatch(r"(\d+)(?:\.(\d{1,9}))?s", value)
    if not m:
        raise ValueError("duration is not in protobuf JSON form")
    return int(m.group(1)) + (1 if m.group(2) and int(m.group(2)) else 0)


def proto_int(obj, key, default_zero=True):
    """Read a protobuf JSON integer (int64 may be a string).

    Proto3 omits fields that hold their default value, so a missing key means 0
    only where the field has no presence tracking (default_zero=True).
    Returns None when the key is missing and default_zero is False.
    """
    if not isinstance(obj, dict):
        raise ValueError("expected an object")
    if key not in obj:
        return 0 if default_zero else None
    value = obj[key]
    if isinstance(value, bool):
        raise ValueError(f"{key} is not an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?\d+", value):
        return int(value)
    raise ValueError(f"{key} is not an integer")


def short_name(full_name):
    return full_name.rsplit("/", 1)[-1] if isinstance(full_name, str) else None


def conditions_of(resource):
    conditions = resource.get("conditions", [])
    if not isinstance(conditions, list) or not all(isinstance(c, dict) for c in conditions):
        raise ValueError("conditions is malformed")
    return conditions


def has_condition(resource, ctype, state):
    return any(c.get("type") == ctype and c.get("state") == state for c in conditions_of(resource))


def any_failed_condition(resource):
    return any(c.get("state") == CONDITION_FAILED for c in conditions_of(resource))


def single_container(template, what):
    containers = template.get("containers") if isinstance(template, dict) else None
    if not isinstance(containers, list) or len(containers) != 1 or not isinstance(containers[0], dict):
        raise GateError(f"{what} must have exactly one container")
    return containers[0]


# --------------------------------------------------------------------------
# Image references: configured vs runtime
# --------------------------------------------------------------------------
#
# Configuration (the job template, the service template) is always compared
# with the configured FLEET_GATE_IMAGE string exactly. Runtime objects that
# Cloud Run creates from that configuration (the execution, its task, a
# revision) may instead report the image as Google resolved it, for example a
# Docker Hub tag reported as mirror.gcr.io/<namespace>/<repo>@sha256:<digest>.
# Runtime images are accepted only when they name the same canonical
# repository and either the configured tag or a sha256 digest (which must equal
# a configured digest, if any). The gate does not contact any registry: it
# trusts Google's tag -> digest resolution only for objects already tied to the
# exact configured, generation-pinned job (the owned :run operation, execution
# and task) or service template. The first digest reported in a run is pinned,
# and every later runtime digest (execution, task, serving revision) must
# equal it.

DOCKER_HUB = "docker.io"
# Exact registry hosts that name Docker Hub repositories. mirror.gcr.io is
# Google's Docker Hub pull-through cache, which Cloud Run reports for Docker
# Hub images it resolved. Only these exact host strings are aliases: there is
# no prefix or suffix matching, and gcr.io or any other host is a different
# registry.
DOCKER_HUB_HOSTS = frozenset({"docker.io", "index.docker.io", "registry-1.docker.io", "mirror.gcr.io"})

_REF_DOMAIN_COMPONENT = r"(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])"
_REF_DOMAIN = rf"{_REF_DOMAIN_COMPONENT}(?:\.{_REF_DOMAIN_COMPONENT})*(?::[0-9]+)?"
_REF_PATH_COMPONENT = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
_REF_TAG = r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}"
_REF_DIGEST = r"sha256:[0-9a-f]{64}"


class ImageRef:
    """A parsed, canonical container image reference."""

    __slots__ = ("host", "path", "tag", "digest")

    def __init__(self, host, path, tag, digest):
        self.host = host
        self.path = path
        self.tag = tag
        self.digest = digest

    @property
    def repository(self):
        return (self.host, self.path)


def parse_image_ref(value):
    """Parse a Docker/OCI image reference into its canonical form.

    Follows the distribution reference grammar: [host/]path[:tag][@digest].
    The first component is a host only if it contains '.' or ':' or is
    'localhost'; otherwise the image is on Docker Hub. The exact Docker Hub
    host aliases map to docker.io, where a single-component path gets the
    implicit 'library/' namespace. Every other host and path is kept exactly.
    A digest must be sha256 with 64 lowercase hex digits. With neither tag nor
    digest the tag is 'latest'. Raises ValueError for anything else.
    """
    if not isinstance(value, str) or not value or len(value) > 512 or any(c.isspace() for c in value):
        raise ValueError("not an image reference")
    name, sep, digest = value.partition("@")
    if sep:
        if not re.fullmatch(_REF_DIGEST, digest):
            raise ValueError("digest is not sha256 with 64 lowercase hex digits")
    else:
        digest = None
    tag = None
    colon = name.rfind(":")
    if colon > name.rfind("/"):
        name, tag = name[:colon], name[colon + 1:]
        if not re.fullmatch(_REF_TAG, tag):
            raise ValueError("tag is malformed")
    if not name or len(name) > 255:
        raise ValueError("repository name is malformed")
    parts = name.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        host, path = parts[0], parts[1:]
        if not re.fullmatch(_REF_DOMAIN, host):
            raise ValueError("registry host is malformed")
    else:
        host, path = DOCKER_HUB, parts
    if not all(re.fullmatch(_REF_PATH_COMPONENT, p) for p in path):
        raise ValueError("repository path is malformed")
    if host in DOCKER_HUB_HOSTS:
        host = DOCKER_HUB
        if len(path) == 1:
            path = ["library"] + path
    if tag is None and digest is None:
        tag = "latest"
    return ImageRef(host, "/".join(path), tag, digest)


def runtime_image_mismatch(configured, observed):
    """Why a runtime image is not the configured image; None if it is.

    `configured` and `observed` are ImageRefs. The observed image must name
    the same canonical repository. Without a digest it must carry the
    configured tag (and the configuration must not pin a digest). With a
    digest, that digest must equal the configured digest when one is
    configured; otherwise it is accepted as Google's resolution of the
    configured tag (the caller pins it). An observed tag that differs from a
    configured tag is a contradiction. Pure; never contacts a registry.
    """
    if observed.repository != configured.repository:
        return "a different registry or repository"
    if observed.digest is None:
        if configured.digest is not None:
            return "no digest to compare with the configured digest"
        if observed.tag != configured.tag:
            return "a different tag"
        return None
    if configured.digest is not None and observed.digest != configured.digest:
        return "a different digest than the configured digest"
    if observed.tag is not None and configured.tag is not None and observed.tag != configured.tag:
        return "a different tag"
    return None


def normalize_env(env):
    """Order-insensitive canonical form of a container env list.

    Each entry is a plain value ({name, value}; proto3 omits an empty value)
    or a Secret Manager reference ({name, valueSource: {secretKeyRef:
    {secret, version}}}). Anything else is unrecognised. Values are compared
    in memory only and never logged.
    """
    if env is None:
        env = []
    if not isinstance(env, list):
        raise ValueError("env is not a list")
    out = {}
    for entry in env:
        if not isinstance(entry, dict):
            raise ValueError("env entry is not an object")
        name = entry.get("name")
        if not isinstance(name, str) or not name or name in out:
            raise ValueError("env entry has no unique name")
        extra = set(entry) - {"name"}
        if extra <= {"value"}:
            value = entry.get("value", "")
            if not isinstance(value, str):
                raise ValueError("env value is not a string")
            out[name] = ("value", value)
        elif extra == {"valueSource"}:
            source = entry["valueSource"]
            ref = source.get("secretKeyRef") if isinstance(source, dict) else None
            if (not isinstance(ref, dict) or set(source) != {"secretKeyRef"} or set(ref) != {"secret", "version"}
                    or not all(isinstance(ref[k], str) and ref[k] for k in ("secret", "version"))):
                raise ValueError("env secret reference is not recognised")
            out[name] = ("secret", ref["secret"], ref["version"])
        else:
            raise ValueError("env entry has unrecognised fields")
    return out


class ServingConfig:
    """Fleet's desired serving configuration, taken from the migration job.

    The job and the service are built from the same Terraform locals
    (fleet_env_vars, fleet_secrets_env_vars, cmek_cloud_run_key_id), and
    Terraform updates the job before the gate runs, so the job carries the
    current desired env (MySQL/Redis addresses, secret references) and CMEK
    key. Only those fields and the image are copied to the service template;
    the job's command, args, timeout and retries are job-only and never
    copied, and service-only fields (ports, probes, resources, service
    account, VPC access) are preserved.
    """

    def __init__(self, image, env, encryption_key):
        self.image = image
        self.env = env  # raw list, copied into the service template
        self.env_norm = normalize_env(env)
        self.encryption_key = encryption_key

    def serving_container(self, obj):
        """The single container of a service template or revision when its env
        and CMEK key are this configuration's; None otherwise. The image is
        NOT compared here (see matches and verify_ready_revision)."""
        containers = obj.get("containers") if isinstance(obj, dict) else None
        if not isinstance(containers, list) or len(containers) != 1 or not isinstance(containers[0], dict):
            return None
        try:
            env = normalize_env(containers[0].get("env"))
        except ValueError:
            return None
        if env != self.env_norm or obj.get("encryptionKey") != self.encryption_key:
            return None
        return containers[0]

    def matches(self, obj):
        """True when a service TEMPLATE (configuration) is exactly this
        configuration, including the exact configured image string. A
        revision's runtime image is checked separately, because Cloud Run may
        report it resolved to a digest."""
        container = self.serving_container(obj)
        return container is not None and container.get("image") == self.image


# --------------------------------------------------------------------------
# Scaling snapshot
# --------------------------------------------------------------------------


def normalize_scaling(scaling):
    """Canonical form of a ServiceScaling object for capture and comparison."""
    if scaling is None:
        scaling = {}
    if not isinstance(scaling, dict):
        raise ValueError("scaling is malformed")
    known = {"scalingMode", "minInstanceCount", "maxInstanceCount", "manualInstanceCount"}
    unknown = set(scaling) - known
    if unknown:
        raise ValueError("scaling has unrecognised fields: " + ", ".join(sorted(unknown)))
    mode = scaling.get("scalingMode", "SCALING_MODE_UNSPECIFIED")
    if mode in ("SCALING_MODE_UNSPECIFIED", "AUTOMATIC"):
        mode = "AUTOMATIC"
    elif mode != "MANUAL":
        raise ValueError("scalingMode is not recognised")
    out = {
        "scalingMode": mode,
        "minInstanceCount": proto_int(scaling, "minInstanceCount"),
        "maxInstanceCount": proto_int(scaling, "maxInstanceCount"),
    }
    if mode == "MANUAL":
        manual = proto_int(scaling, "manualInstanceCount", default_zero=False)
        if manual is None:
            raise ValueError("MANUAL scaling without an explicit manualInstanceCount")
        out["manualInstanceCount"] = manual
    for value in out.values():
        if isinstance(value, int) and value < 0:
            raise ValueError("negative instance count")
    return out


def scaling_request_body(normalized):
    body = {"scalingMode": normalized["scalingMode"]}
    if normalized["minInstanceCount"]:
        body["minInstanceCount"] = normalized["minInstanceCount"]
    if normalized["maxInstanceCount"]:
        body["maxInstanceCount"] = normalized["maxInstanceCount"]
    if normalized["scalingMode"] == "MANUAL":
        body["manualInstanceCount"] = normalized["manualInstanceCount"]
    return body


def parse_checkpoint(resource):
    """None when absent, False when unrecognisable, else the checkpoint dict."""
    annotations = resource.get("annotations") or {}
    if not isinstance(annotations, dict):
        return False
    raw = annotations.get(CHECKPOINT_ANNOTATION)
    if raw is None:
        return None
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        return False
    if not isinstance(data, dict) or data.get("v") != CHECKPOINT_VERSION or not isinstance(data.get("phase"), str):
        return False
    return data


def has_tags(svc):
    """True when any traffic or trafficStatuses entry is tagged (or unreadable)."""
    entries = []
    for field in ("traffic", "trafficStatuses"):
        value = svc.get(field, [])
        if not isinstance(value, list):
            return True
        entries.extend(value)
    return any(not isinstance(e, dict) or e.get("tag") or e.get("uri") for e in entries)


def failed_reconciliation(svc):
    """True for Cloud Run's documented settled failed-reconciliation shape:
    reconciling is false, terminalCondition is CONDITION_FAILED, and
    observedGeneration still names an earlier (last serving) generation,
    which must be a positive integer not above generation."""
    if not isinstance(svc, dict) or svc.get("reconciling", False) is not False:
        return False
    if (svc.get("terminalCondition") or {}).get("state") != CONDITION_FAILED:
        return False
    try:
        generation = proto_int(svc, "generation", default_zero=False)
        observed = proto_int(svc, "observedGeneration", default_zero=False)
    except ValueError:
        return False
    return generation is not None and observed is not None and 0 < observed <= generation


def is_stopped_scaling(scaling):
    try:
        n = normalize_scaling(scaling)
    except ValueError:
        return False
    return n["scalingMode"] == "MANUAL" and n["manualInstanceCount"] == 0 and n["minInstanceCount"] == 0


# --------------------------------------------------------------------------
# Telemetry analysis (pure)
# --------------------------------------------------------------------------


class TelemetryResult:
    def __init__(self):
        self.fatal = []  # contradictions or schema anomalies: never retry
        self.zero_at = {}  # revision -> first coherent zero timestamp (ns)
        self.pending = []  # revisions without a coherent zero yet
        self.revisions = set()  # revisions present in the telemetry


def parse_series(series_list, config, result):
    """Validate raw series; return {revision: {series_key: (state, {ts: value})}}."""
    by_revision = {}
    for series in series_list:
        if not isinstance(series, dict):
            result.fatal.append("telemetry series is malformed")
            continue
        metric = series.get("metric") or {}
        resource = series.get("resource") or {}
        mlabels = metric.get("labels") or {}
        rlabels = resource.get("labels") or {}
        if metric.get("type") != INSTANCE_COUNT_METRIC or resource.get("type") != "cloud_run_revision":
            result.fatal.append("telemetry returned an unexpected metric or resource type")
            continue
        if series.get("metricKind") != "GAUGE" or series.get("valueType") != "INT64":
            result.fatal.append("telemetry series is not an INT64 GAUGE")
            continue
        if (rlabels.get("project_id") != config.project or rlabels.get("location") != config.region
                or rlabels.get("service_name") != config.service):
            result.fatal.append("telemetry returned a series for another project, location or service")
            continue
        revision = rlabels.get("revision_name")
        state = mlabels.get("state")
        if not isinstance(revision, str) or not revision:
            result.fatal.append("telemetry series has no revision_name")
            continue
        if state not in ("active", "idle"):
            result.fatal.append(f"telemetry series for {revision} has an unexpected state label")
            continue
        key = json.dumps([sorted(mlabels.items()), sorted(rlabels.items())], sort_keys=True)
        points = {}
        bucket = by_revision.setdefault(revision, {})
        if key in bucket:
            state_, points = bucket[key]
        ok = True
        for point in series.get("points") or []:
            try:
                interval = point["interval"]
                end_ns = parse_rfc3339_ns(interval["endTime"])
                start_ns = parse_rfc3339_ns(interval["startTime"]) if "startTime" in interval else end_ns
                value = point["value"]
                if set(value) != {"int64Value"}:
                    raise ValueError("value is not int64Value")
                count = proto_int(value, "int64Value", default_zero=False)
                if count is None or count < 0:
                    raise ValueError("bad count")
            except (KeyError, TypeError, ValueError):
                result.fatal.append(f"telemetry point for {revision} is malformed")
                ok = False
                break
            if start_ns > end_ns:
                result.fatal.append(f"telemetry point for {revision} has an inverted interval")
                ok = False
                break
            if end_ns in points and points[end_ns][1] != count:
                result.fatal.append(f"telemetry for {revision} has conflicting points")
                ok = False
                break
            points[end_ns] = (start_ns, count)
        if ok:
            bucket[key] = (state, points)
    return by_revision


def check_time_bounds(by_revision, observed_ns, result):
    """Fatal for any point dated at or after observed_ns + 1 s.

    observed_ns is the floored HTTP Date of the telemetry response, so the
    server's real time was below observed_ns + 1 s when it answered; nothing
    can have been measured at or after that instant.
    """
    for revision, bucket in by_revision.items():
        for _, points in bucket.values():
            for end_ns in points:
                if end_ns >= observed_ns + NANOS:
                    result.fatal.append(f"telemetry for {revision} is dated after the server's own response time "
                                        "(clock anomaly)")


def analyze_zero(series_list, config, fence_ns, bound_ns, observed_ns, required_revisions):
    """Decide whether every revision has a verified actual zero after the fence.

    Only points inside (fence_ns, bound_ns] are usable. fence_ns is the
    conservative stop fence (HTTP Date + 1 s of the stop confirmation, or the
    service updateTime if later). bound_ns is the query endTime, an HTTP Date
    floor already observed from Google, so a usable point is neither stale
    (before the stop) nor in the future. Points after bound_ns are ignored
    (a later query can use them); points at or after observed_ns + 1 s are
    fatal (see check_time_bounds).

    A revision is verified when some usable timestamp T has, for EVERY series
    of that revision (both states present), a raw point ending at T whose
    interval starts strictly after the fence and whose value is 0. Any usable
    non-zero point after the first verified zero is a contradiction (a new
    instance) and is fatal.
    """
    result = TelemetryResult()
    by_revision = parse_series(series_list, config, result)
    result.revisions = set(by_revision)
    check_time_bounds(by_revision, observed_ns, result)
    if result.fatal:
        return result
    for revision in sorted(set(required_revisions) | set(by_revision)):
        bucket = by_revision.get(revision, {})
        states = {state for state, _ in bucket.values()}
        after = {}
        for key, (state, points) in bucket.items():
            after[key] = {t: v for t, v in points.items() if fence_ns < t <= bound_ns}
        zero_at = None
        if states >= {"active", "idle"}:
            candidates = sorted({t for pts in after.values() for t in pts})
            for t in candidates:
                if all(t in pts and pts[t][0] > fence_ns and pts[t][1] == 0 for pts in after.values()):
                    zero_at = t
                    break
        if zero_at is None:
            result.pending.append(revision)
            continue
        for pts in after.values():
            for t, (_, count) in pts.items():
                if t > zero_at and count != 0:
                    result.fatal.append(f"revision {revision} reported instances after a verified zero")
        result.zero_at[revision] = zero_at
    return result


def analyze_coverage(series_list, config, bound_ns, observed_ns, revisions):
    """Read-only preflight: does telemetry cover every revision at all?

    This is NOT evidence of zero; it only predicts whether the post-stop proof
    can possibly succeed, so the gate can refuse before causing an outage.
    """
    result = TelemetryResult()
    by_revision = parse_series(series_list, config, result)
    result.revisions = set(by_revision)
    check_time_bounds(by_revision, observed_ns, result)
    for revision in sorted(set(revisions) | set(by_revision)):
        covered = {state for state, points in by_revision.get(revision, {}).values()
                   if any(t <= bound_ns for t in points)}
        if not covered >= {"active", "idle"}:
            result.pending.append(revision)
    return result


# --------------------------------------------------------------------------
# API client
# --------------------------------------------------------------------------


class Api:
    def __init__(self, transport, token_source, clock, log):
        self.transport = transport
        self.token_source = token_source
        self.clock = clock
        self.log = log
        self._token = None
        self._token_at = None
        self.server_now_ns = None
        self.last_list_first_date_ns = None

    def _auth_header(self, force=False):
        now = self.clock.monotonic()
        if force or self._token is None or now - self._token_at > TOKEN_MAX_AGE:
            self._token = self.token_source.token()
            self._token_at = now
        return {"Authorization": "Bearer " + self._token}

    def _send(self, method, url, body, force_token=False):
        headers = {"Accept": "application/json"}
        headers.update(self._auth_header(force=force_token))
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")
        resp = self.transport.request(method, url, headers, data)
        resp_headers = {str(k).lower(): v for k, v in (resp.headers or {}).items()}
        date_ns = parse_http_date_ns(resp_headers.get("date"))
        if date_ns is not None and (self.server_now_ns is None or date_ns > self.server_now_ns):
            self.server_now_ns = date_ns
        return resp, date_ns

    @staticmethod
    def _decode(resp):
        try:
            payload = json.loads(resp.body.decode("utf-8")) if resp.body else {}
        except (UnicodeDecodeError, ValueError):
            return None
        return payload if isinstance(payload, dict) else None

    @staticmethod
    def _rpc_status(payload):
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            status = payload["error"].get("status")
            return status if isinstance(status, str) and re.fullmatch(r"[A-Z_]{1,40}", status) else None
        return None

    def get(self, url, label, allow_404=False):
        """GET with bounded retries. Returns (payload|None, date_ns)."""
        refreshed = False
        attempt = 0
        while True:
            attempt += 1
            try:
                resp, date_ns = self._send("GET", url, None, force_token=False)
            except TransportError as err:
                if attempt >= GET_ATTEMPTS:
                    raise ApiError("GET", label, None, str(err)) from None
                self.clock.sleep(2 ** attempt)
                continue
            if resp.status == 401 and not refreshed:
                refreshed = True
                self._token = None
                continue
            payload = self._decode(resp)
            if resp.status == 404 and allow_404 and self._rpc_status(payload) == "NOT_FOUND":
                if date_ns is None:
                    raise ApiError("GET", label, resp.status, "NO_DATE_HEADER")
                return None, date_ns
            if resp.status in (429,) or resp.status >= 500:
                if attempt >= GET_ATTEMPTS:
                    raise ApiError("GET", label, resp.status, self._rpc_status(payload))
                self.clock.sleep(2 ** attempt)
                continue
            if resp.status != 200:
                raise ApiError("GET", label, resp.status, self._rpc_status(payload), definitive=True)
            if payload is None:
                raise ApiError("GET", label, resp.status, "UNPARSEABLE_BODY")
            if date_ns is None:
                raise ApiError("GET", label, resp.status, "NO_DATE_HEADER")
            return payload, date_ns

    def write(self, method, url, label, body):
        """Single-attempt write. Never retried.

        Raises ApiError(definitive=True) when the server rejected the request
        and WriteOutcomeUnknown when the outcome cannot be known.
        """
        try:
            resp, _ = self._send(method, url, body, force_token=True)
        except TransportError as err:
            raise WriteOutcomeUnknown(f"{method} {label}: {err}") from None
        payload = self._decode(resp)
        if 200 <= resp.status < 300:
            if payload is None:
                raise WriteOutcomeUnknown(f"{method} {label}: unparseable success response")
            return payload
        if resp.status in DEFINITIVE_REJECTIONS:
            raise ApiError(method, label, resp.status, self._rpc_status(payload), definitive=True)
        raise WriteOutcomeUnknown(f"{method} {label}: HTTP {resp.status} {self._rpc_status(payload) or ''}".rstrip())

    def list_all(self, url, label, field, params=None):
        """Collect every page. Any page failure fails the whole listing."""
        items = []
        token = None
        seen_tokens = set()
        self.last_list_first_date_ns = None
        while True:
            query = dict(params or {})
            if token:
                query["pageToken"] = token
            full = url + ("?" + urllib.parse.urlencode(query) if query else "")
            payload, date_ns = self.get(full, label)
            if self.last_list_first_date_ns is None:
                self.last_list_first_date_ns = date_ns
            page = payload.get(field, [])
            if not isinstance(page, list) or not all(isinstance(x, dict) for x in page):
                raise ApiError("GET", label, 200, "MALFORMED_PAGE")
            items.extend(page)
            if "executionErrors" in payload or "unreachable" in payload:
                raise ApiError("GET", label, 200, "PARTIAL_RESULT")
            token = payload.get("nextPageToken")
            if not token:
                return items
            if not isinstance(token, str) or token in seen_tokens:
                raise ApiError("GET", label, 200, "BAD_PAGE_TOKEN")
            seen_tokens.add(token)


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


class Config:
    ENV = {
        "project": "FLEET_GATE_PROJECT",
        "region": "FLEET_GATE_REGION",
        "service": "FLEET_GATE_SERVICE",
        "job": "FLEET_GATE_JOB",
        "image": "FLEET_GATE_IMAGE",
        "run_id": "FLEET_GATE_RUN_ID",
        "job_generation": "FLEET_GATE_JOB_GENERATION",
        "trigger": "FLEET_GATE_TRIGGER",
    }
    PATTERNS = {
        "project": r"(?:[a-z0-9.-]+:)?[a-z][a-z0-9-]{4,28}[a-z0-9]",
        "region": r"[a-z]+-[a-z]+[0-9]+",
        "service": r"[a-z](?:[-a-z0-9]{0,47}[a-z0-9])?",
        "job": r"[a-z](?:[-a-z0-9]{0,47}[a-z0-9])?",
        "image": r"[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,511}",
        "run_id": r"[A-Za-z0-9][A-Za-z0-9-]{0,63}",
        "job_generation": r"[1-9][0-9]{0,18}",
        "trigger": r"[0-9a-f]{64}",
    }

    def __init__(self, **values):
        for key, pattern in self.PATTERNS.items():
            value = values.get(key)
            if not isinstance(value, str) or not re.fullmatch(pattern, value):
                raise GateError(f"invalid or missing {self.ENV[key]}")
            setattr(self, key, value)
        try:
            self.image_ref = parse_image_ref(self.image)
        except ValueError as err:
            raise GateError(f"{self.ENV['image']} is not a valid image reference ({err})") from None
        self.location_name = f"projects/{self.project}/locations/{self.region}"
        self.service_name = f"{self.location_name}/services/{self.service}"
        self.job_name = f"{self.location_name}/jobs/{self.job}"

    @classmethod
    def from_env(cls, environ):
        return cls(**{key: environ.get(env) for key, env in cls.ENV.items()})


# --------------------------------------------------------------------------
# Controller
# --------------------------------------------------------------------------


class MigrationGate:
    def __init__(self, config, api, clock, log):
        self.cfg = config
        self.api = api
        self.clock = clock
        self.log = log
        # Fleet state for error reporting; updated as the protocol advances.
        self.fleet = FLEET_UNCHANGED
        self.migration = MIGRATION_NOT_RUN
        self.checkpoint = None
        self.stop_attempted = False
        self.expected_service = None  # (etag, generation) after our last verified write
        self.revisions = None  # revision inventory (short names)
        self.required_revisions = None  # inventory + revisions seen in pre-stop telemetry
        self.fence_ns = None
        self.zero_at = None
        self.zero_proof_current = False
        # Job ownership: this run's claimed job record (phase), and the etag
        # and generation read back right after the claim. :run is sent with
        # exactly that etag.
        self.job_phase = None
        self.job_etag = None
        self.job_generation = None
        self.executions_before = None
        self.execution_name = None
        self.migration_timeout = None
        # Narrow recovery exemption: set only while recovering a service that
        # an earlier run of this gate left stopped (valid unfinished record,
        # MANUAL/0). It tolerates a settled failed/unready latest revision
        # (an earlier failed rollout) until this run's own rollout write.
        self.rollout_exempt = False
        # First runtime image digest reported in this run (owned execution,
        # its task or the serving revision); every later one must equal it.
        self.image_digest = None

    # -- error helpers ---------------------------------------------------

    def fail(self, message, fleet=None, migration=None):
        raise GateError(message, fleet=fleet or self.fleet, migration=migration or self.migration)

    def check(self, condition, message):
        if not condition:
            self.fail(message)

    def deadline(self, seconds):
        return self.clock.monotonic() + seconds

    def expired(self, deadline):
        return self.clock.monotonic() >= deadline

    # -- API wrappers ----------------------------------------------------

    def run_url(self, name):
        return f"{RUN_API}/{name}"

    def get_service(self, allow_404=False):
        payload, date_ns = self.api.get(self.run_url(self.cfg.service_name), "service", allow_404=allow_404)
        return payload, date_ns

    def get_job(self):
        payload, _ = self.api.get(self.run_url(self.cfg.job_name), "job")
        return payload

    def list_revisions(self):
        return self.api.list_all(
            self.run_url(self.cfg.service_name) + "/revisions", "revisions", "revisions",
            {"showDeleted": "true", "pageSize": "100"},
        )

    def list_executions(self):
        return self.api.list_all(
            self.run_url(self.cfg.job_name) + "/executions", "executions", "executions",
            {"showDeleted": "true", "pageSize": "100"},
        )

    def list_services(self):
        return self.api.list_all(
            self.run_url(self.cfg.location_name) + "/services", "services", "services",
            {"showDeleted": "true", "pageSize": "100"},
        )

    def list_tasks(self, execution_name):
        return self.api.list_all(
            self.run_url(execution_name) + "/tasks", "tasks", "tasks",
            {"showDeleted": "true", "pageSize": "100"},
        )

    def query_instance_count(self, start_ns, end_ns):
        filt = (
            f'metric.type = "{INSTANCE_COUNT_METRIC}" AND resource.type = "cloud_run_revision"'
            f' AND resource.labels.project_id = "{self.cfg.project}"'
            f' AND resource.labels.location = "{self.cfg.region}"'
            f' AND resource.labels.service_name = "{self.cfg.service}"'
        )
        params = {
            "filter": filt,
            "interval.startTime": format_rfc3339_ns(start_ns),
            "interval.endTime": format_rfc3339_ns(end_ns),
            "view": "FULL",
            "pageSize": "1000",
        }
        url = f"{MONITORING_API}/projects/{self.cfg.project}/timeSeries"
        series = self.api.list_all(url, "monitoring timeSeries", "timeSeries", params)
        # Date of the first page: the earliest server time at which any of
        # these points was reported.
        return series, self.api.last_list_first_date_ns

    def wait_operation(self, operation, label, on_poll=None):
        """Poll a long-running operation to done. Raises WriteOutcomeUnknown.

        on_poll runs before every poll (e.g. re-verifying the job executions
        while a new revision deploys); its GateError fails the gate."""
        name = operation.get("name") if isinstance(operation, dict) else None
        if not isinstance(name, str) or not name.startswith(self.cfg.location_name + "/operations/"):
            raise WriteOutcomeUnknown(f"{label}: response is not a recognisable operation")
        deadline = self.deadline(OPERATION_TIMEOUT)
        op = operation
        while not op.get("done"):
            if on_poll is not None:
                on_poll()
            if self.expired(deadline):
                raise WriteOutcomeUnknown(f"{label}: operation did not finish within {OPERATION_TIMEOUT}s")
            self.clock.sleep(OPERATION_POLL)
            try:
                op, _ = self.api.get(self.run_url(name), "operation")
            except ApiError as err:
                raise WriteOutcomeUnknown(f"{label}: {err}") from None
        if "error" in op:
            raise WriteOutcomeUnknown(f"{label}: operation finished with an error")
        return op

    # -- checkpoint ------------------------------------------------------

    def make_checkpoint(self, phase, pre_scaling, **extra):
        data = {
            "v": CHECKPOINT_VERSION,
            "run": self.cfg.run_id,
            "phase": phase,
            "image": self.cfg.image,
            "trigger": self.cfg.trigger,
            "pre_scaling": pre_scaling,
        }
        data.update(extra)
        return data

    @staticmethod
    def with_annotation(resource, checkpoint):
        annotations = dict(resource.get("annotations") or {})
        annotations[CHECKPOINT_ANNOTATION] = json.dumps(checkpoint, sort_keys=True, separators=(",", ":"))
        resource["annotations"] = annotations
        return resource

    def owns(self, resource, phases):
        """True when resource's record is this run's, in one of phases."""
        data = parse_checkpoint(resource)
        return isinstance(data, dict) and data.get("run") == self.cfg.run_id and data.get("phase") in phases

    # -- service validation ----------------------------------------------

    def validate_service(self, svc, *, expect_stopped, expect_phase=None):
        """Structural checks shared by every service read."""
        self.check(svc.get("name") == self.cfg.service_name, "service response has an unexpected name")
        for field in ("uid", "etag", "generation"):
            self.check(isinstance(svc.get(field), str) and svc.get(field), f"service response has no {field}")
        try:
            generation = proto_int(svc, "generation", default_zero=False)
            observed = proto_int(svc, "observedGeneration", default_zero=False)
        except ValueError:
            self.fail("service generation fields are malformed")
        self.check(svc.get("reconciling", False) is False, "service is reconciling")
        terminal = (svc.get("terminalCondition") or {}).get("state")
        if self.rollout_exempt and failed_reconciliation(svc):
            # Documented Cloud Run shape of a settled failed reconciliation:
            # observedGeneration (with trafficStatuses and latestReadyRevision)
            # keeps the state of the last serving generation. Accepted only in
            # the stopped-recovery exemption, until this run's own rollout.
            pass
        else:
            self.check(observed is not None and observed == generation,
                       "service observedGeneration does not match generation (reconciling or changed)")
        if self.rollout_exempt:
            # Recovery of a service this gate left stopped: an earlier
            # rollout may have settled as failed. Still settled (checked
            # above); traffic, tag, identity and zero checks are unchanged.
            self.check(terminal in (CONDITION_SUCCEEDED, CONDITION_FAILED),
                       "service terminalCondition is neither CONDITION_SUCCEEDED nor a settled CONDITION_FAILED")
        else:
            self.check(terminal == CONDITION_SUCCEEDED, "service terminalCondition is not CONDITION_SUCCEEDED")
        self.check_no_tags(svc)
        template = svc.get("template")
        self.check(isinstance(template, dict), "service has no template")
        # template.revision may be present in a normal GET (a generated name)
        # and its presence does not prove a user pin. The module this gate
        # belongs to never sets it (revision = null). Metadata/scaling-only
        # writes resend the template exactly as read; the new-image write
        # omits it so Google generates a new, unused revision name, except
        # when an unchanged template must be redeployed after a failed
        # rollout (see roll_out_serving_config).
        self.check(isinstance(template.get("revision", ""), str), "service template revision is malformed")
        container = single_container(template, "service template")
        self.check(isinstance(container.get("image"), str) and container.get("image"), "service container has no image")
        for token in JOB_EXECUTION_TOKENS:
            self.check(token not in svc, "service has an unexpected execution token field")
        checkpoint = parse_checkpoint(svc)
        if expect_stopped:
            self.check(is_stopped_scaling(svc.get("scaling")), "service is no longer stopped (MANUAL, 0 instances)")
            self.check(isinstance(checkpoint, dict) and checkpoint.get("run") == self.cfg.run_id,
                       "service checkpoint is missing or owned by another run")
            if expect_phase is not None:
                self.check(checkpoint.get("phase") == expect_phase, "service checkpoint phase changed unexpectedly")
            self.check(checkpoint.get("pre_scaling") == self.checkpoint["pre_scaling"],
                       "service checkpoint pre-migration scaling changed unexpectedly")
        return checkpoint

    def check_no_tags(self, svc):
        self.check(not has_tags(svc),
                   "service has traffic tags (or unreadable traffic); tagged revisions can receive requests "
                   "outside the stop, refusing")

    def check_latest_traffic(self, svc, revision=None):
        """Exactly one traffic target: 100% to LATEST, untagged."""
        traffic = svc.get("traffic", [])
        self.check(len(traffic) == 1 and traffic[0].get("type") == TRAFFIC_LATEST
                   and proto_int(traffic[0], "percent") == 100 and not traffic[0].get("revision"),
                   "service traffic must be a single untagged 100% LATEST target")
        statuses = svc.get("trafficStatuses", [])
        live = [s for s in statuses if proto_int(s, "percent") != 0]
        self.check(len(live) == 1 and proto_int(live[0], "percent") == 100,
                   "service trafficStatuses do not show a single 100% target")
        if revision is not None:
            target = live[0].get("revision")
            self.check(live[0].get("type") == TRAFFIC_LATEST or target == short_name(revision),
                       "service traffic does not target the expected revision")
            if target:
                self.check(target == short_name(revision), "service traffic does not target the new revision")

    def recheck_service(self, *, phase):
        """Service must be exactly as left by our last verified write."""
        svc, _ = self.get_service()
        self.check(svc is not None, "service disappeared")
        self.validate_service(svc, expect_stopped=True, expect_phase=phase)
        etag, generation = self.expected_service
        self.check(svc["etag"] == etag and svc["generation"] == generation,
                   "service changed outside the gate (etag/generation); another writer is active")
        return svc

    def recheck_revisions(self):
        names = self.revision_names(self.list_revisions())
        self.check(names == self.revisions,
                   "the revision inventory changed while Fleet was stopped; a configuration change occurred")

    def revision_names(self, revisions):
        names = set()
        prefix = self.cfg.service_name + "/revisions/"
        for rev in revisions:
            name = rev.get("name")
            self.check(isinstance(name, str) and name.startswith(prefix) and len(name) > len(prefix),
                       "revision listing returned an entry without a valid name")
            names.add(short_name(name))
        return names

    def final_fleet_state(self):
        """Re-read the service when reporting a failure; never assume."""
        if not self.stop_attempted:
            return self.fleet
        try:
            svc, _ = self.get_service(allow_404=True)
        except (ApiError, GateError):
            return FLEET_STATE_UNKNOWN
        if svc is None:
            return FLEET_STATE_UNKNOWN
        cp = parse_checkpoint(svc)
        if (is_stopped_scaling(svc.get("scaling")) and isinstance(cp, dict) and cp.get("run") == self.cfg.run_id
                and self.checkpoint is not None and cp.get("pre_scaling") == self.checkpoint["pre_scaling"]
                and svc.get("reconciling", False) is False and not has_tags(svc)):
            unchanged = (self.expected_service is not None
                         and (svc.get("etag"), svc.get("generation")) == self.expected_service)
            if self.zero_proof_current and unchanged:
                return FLEET_MEASURED_ZERO
            return FLEET_RESTART_DISABLED
        if isinstance(cp, dict) and cp.get("run") == self.cfg.run_id and cp.get("phase") == PHASE_COMPLETED:
            return FLEET_NOT_STOPPED + " (the restore write was applied)"
        if isinstance(cp, dict) and cp.get("run") != self.cfg.run_id and is_stopped_scaling(svc.get("scaling")):
            return FLEET_TAKEN_OVER
        return FLEET_NOT_STOPPED

    # -- service writes --------------------------------------------------

    def patch_service(self, svc, label, on_poll=None):
        body = {k: v for k, v in svc.items() if k not in SERVICE_OUTPUT_ONLY}
        url = self.run_url(self.cfg.service_name)
        op = self.api.write("PATCH", url, label, body)
        return self.wait_operation(op, label, on_poll=on_poll)

    # -- job validation --------------------------------------------------

    def validate_job(self, job):
        cfg = self.cfg
        self.check(job.get("name") == cfg.job_name, "job response has an unexpected name")
        for field in ("uid", "etag", "generation"):
            self.check(isinstance(job.get(field), str) and job.get(field), f"job response has no {field}")
        try:
            generation = proto_int(job, "generation", default_zero=False)
            observed = proto_int(job, "observedGeneration", default_zero=False)
        except ValueError:
            self.fail("job generation fields are malformed")
        self.check(observed is not None and observed == generation, "job observedGeneration does not match generation")
        self.check(job.get("reconciling", False) is False, "job is reconciling")
        self.check((job.get("terminalCondition") or {}).get("state") == CONDITION_SUCCEEDED,
                   "job terminalCondition is not CONDITION_SUCCEEDED")
        for token in JOB_EXECUTION_TOKENS:
            self.check(token not in job, "job carries an execution token; another writer is starting executions")
        template = job.get("template")
        self.check(isinstance(template, dict), "job has no template")
        self.check_execution_template(template, "job")
        return generation

    def check_execution_template(self, template, what, runtime=False):
        """Single-task, single-attempt template on the target image.

        The job template (runtime=False) is configuration and must carry the
        exact configured image string. An execution (runtime=True) may report
        the image as Cloud Run resolved it (see check_runtime_image)."""
        try:
            task_count = proto_int(template, "taskCount", default_zero=False)
            parallelism = proto_int(template, "parallelism", default_zero=False)
            task_template = template.get("template")
            self.check(isinstance(task_template, dict), f"{what} has no task template")
            # max_retries is in a proto oneof, so an explicit 0 is serialised;
            # a missing value means the server default (3), not 0.
            max_retries = proto_int(task_template, "maxRetries", default_zero=False)
            timeout = parse_duration_seconds(task_template.get("timeout"))
        except ValueError:
            self.fail(f"{what} settings (taskCount, parallelism, maxRetries, timeout) are malformed")
        self.check(task_count == 1, f"{what} must run exactly one task (taskCount=1)")
        self.check(parallelism == 1, f"{what} must have parallelism=1")
        self.check(max_retries == 0, f"{what} must have an explicit maxRetries=0 (single attempt)")
        self.check(0 < timeout <= 86400, f"{what} task timeout is out of range")
        container = single_container(task_template, f"{what} task template")
        if runtime:
            self.check_runtime_image(container.get("image"), what)
        else:
            self.check(container.get("image") == self.cfg.image, f"{what} image does not match the target Fleet image")
        return timeout

    def check_runtime_image(self, image, what):
        """A runtime image (owned execution, its task, the serving revision)
        must be the configured image or Google's digest resolution of it, and
        every digest reported in this run must be the same.

        Callers verify the object's identity and provenance first: the owned
        execution of the exact configured, generation-pinned job, its task,
        or the Ready revision of a service template that matches the
        configured image exactly. No registry is contacted. The reported
        image text is never echoed (it is response data); a validated digest
        is logged for the audit trail."""
        try:
            observed = parse_image_ref(image)
        except ValueError as err:
            self.fail(f"{what} image is not a valid image reference ({err})")
        reason = runtime_image_mismatch(self.cfg.image_ref, observed)
        self.check(reason is None, f"{what} image does not match the target Fleet image ({reason})")
        if observed.digest is None:
            return
        if self.image_digest is None:
            self.image_digest = observed.digest
            self.log(f"{what} reports image digest {observed.digest} for the configured image; "
                     "every later execution, task and revision digest must match it")
        self.check(observed.digest == self.image_digest,
                   f"{what} image digest differs from the digest already reported in this run "
                   "(for example a mutable tag, or an image index vs platform manifest digest)")

    # -- job ownership and execution inventory ---------------------------
    #
    # Every run claims the job with one etag-guarded write of its own record
    # (bootstrap and upgrade alike), reads the job back, and from then on
    # requires its own record on every job read. The claimed etag is the one
    # :run is sent with, so a :run prepared by an earlier controller with an
    # older etag is rejected by the API's conditional check. Immediately
    # before :run the complete execution inventory is re-listed and
    # cross-checked with the job's latestCreatedExecution: an execution the
    # job reports but the listing does not show yet, or one that has not
    # settled, is never treated as absent. This is a detection layer built on
    # Google's documented etag and listing semantics; it is not a proof that
    # every request accepted before the claim is already visible.

    def execution_full_name(self, value):
        """Full resource name of an execution of this job, from a full or a
        short name (Job.latestCreatedExecution.name is observed short); None
        when the value cannot name an execution of this job."""
        if not isinstance(value, str):
            return None
        prefix = self.cfg.job_name + "/executions/"
        short = value[len(prefix):] if value.startswith(prefix) else value
        if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?", short):
            return None
        return prefix + short

    def latest_created_execution(self, job):
        """(full name, completed) from Job.latestCreatedExecution, or None."""
        pointer = job.get("latestCreatedExecution")
        if pointer is None:
            return None
        self.check(isinstance(pointer, dict), "job latestCreatedExecution is malformed")
        full = self.execution_full_name(pointer.get("name"))
        self.check(full is not None, "job latestCreatedExecution does not name an execution of this job")
        return full, bool(pointer.get("completionTime"))

    def execution_settled(self, ex):
        try:
            running = proto_int(ex, "runningCount")
        except ValueError:
            self.fail("execution listing returned malformed counts")
        return bool(ex.get("completionTime")) and running == 0 and ex.get("reconciling", False) is False

    def execution_inventory(self, job, executions):
        """(names, pending): the listed executions, and why the inventory
        cannot yet be trusted as complete and settled (empty when it can).

        Malformed entries fail the gate. Pending reasons are transient states
        a bounded wait may resolve: an unsettled execution, or a job that
        reports a latest execution the listing does not show (yet) or shows
        as not completed."""
        names = set()
        unsettled = []
        for ex in executions:
            name = ex.get("name")
            self.check(isinstance(name, str) and self.execution_full_name(name) == name,
                       "execution listing returned an invalid entry")
            self.check(name not in names, "execution listing returned a duplicate entry")
            names.add(name)
            if not self.execution_settled(ex):
                unsettled.append(short_name(name))
        pending = []
        if unsettled:
            pending.append("job execution(s) " + ", ".join(sorted(unsettled)) + " have not settled")
        try:
            count = proto_int(job, "executionCount")
        except ValueError:
            self.fail("job executionCount is malformed")
        latest = self.latest_created_execution(job)
        if latest is None:
            if names or count:
                pending.append("the job does not report its latest created execution")
        else:
            full, completed = latest
            if full not in names:
                pending.append(f"the job reports execution {short_name(full)} that the execution listing does "
                               "not show yet")
            elif not completed:
                pending.append(f"the job reports execution {short_name(full)} as not completed")
        return names, pending

    def wait_for_settled_inventory(self, when, read_job):
        """Bounded read-only wait until the job's execution inventory is
        complete and settled. Never starts or stops anything. If prior work
        is still running (or not consistently visible) at the deadline the
        gate fails without starting a migration; a later apply re-checks."""
        deadline = self.deadline(self.migration_timeout)
        while True:
            job = read_job()
            names, pending = self.execution_inventory(job, self.list_executions())
            if not pending:
                return job, names
            if self.expired(deadline):
                self.fail("; ".join(pending) + f" ({when}, after waiting {self.migration_timeout}s). A prior "
                          "migration may still be running or its state is not consistently visible, so this run "
                          "started none; a later terraform apply re-checks automatically")
            self.log("waiting before any migration: " + "; ".join(pending))
            self.clock.sleep(MIGRATION_POLL)

    def read_unclaimed_job(self):
        job = self.get_job()
        self.validate_job(job)
        self.check(job["generation"] == self.cfg.job_generation,
                   "job generation does not match the one Terraform just applied; another writer changed it")
        return job

    def read_owned_job(self, when, same_etag=False):
        """The job, still carrying this run's ownership record and the
        claimed generation (and, before :run, the claimed etag)."""
        job = self.get_job()
        self.validate_job(job)
        self.check(self.owns(job, (self.job_phase,)),
                   f"the migration job's ownership record is no longer this run's {when}; another run took over "
                   "or another writer changed it")
        self.check(job["generation"] == self.job_generation, f"the job changed {when}")
        if same_etag:
            self.check(job["etag"] == self.job_etag, f"the job changed {when} (etag)")
        return job

    def job_body(self, job):
        return {k: v for k, v in job.items() if k not in JOB_OUTPUT_ONLY and k not in JOB_EXECUTION_TOKENS}

    def claim_job(self, job, phase):
        """Etag-guarded write of this run's job ownership record.

        Any earlier record (finished or not, from any run) is replaced: it is
        internal metadata, never a lock. The read-back etag must differ from
        the pre-claim etag, so a :run prepared with an older etag cannot
        match the etag this run launches with."""
        pre_etag = job["etag"]
        body = self.job_body(job)
        self.with_annotation(body, self.make_checkpoint(phase, None))
        self.log(f"claiming the migration job for run {self.cfg.run_id} (etag-guarded)")
        try:
            op = self.api.write("PATCH", self.run_url(self.cfg.job_name), "job ownership claim", body)
            self.wait_operation(op, "job ownership claim")
        except ApiError as err:
            self.fail(f"the job ownership claim was rejected ({err}); another writer changed the job. No migration "
                      "was started")
        except WriteOutcomeUnknown as err:
            self.fail(f"the job ownership claim outcome is unknown ({err}); no migration was started")
        claimed = self.get_job()
        self.validate_job(claimed)
        cp = parse_checkpoint(claimed)
        self.check(isinstance(cp, dict) and cp.get("run") == self.cfg.run_id and cp.get("phase") == phase,
                   "job ownership record was not written as expected")
        self.check(claimed["etag"] != pre_etag,
                   "the job etag did not change with the ownership claim, so requests prepared before the claim "
                   "cannot be told apart; refusing")
        self.job_phase = phase
        self.job_etag = claimed["etag"]
        self.job_generation = claimed["generation"]
        return claimed

    def final_launch_check(self):
        """Immediately before :run: the job is exactly as claimed (record,
        generation, etag) and the complete execution inventory, cross-checked
        with latestCreatedExecution, is the settled baseline read after the
        claim."""
        job = self.read_owned_job("before the migration started", same_etag=True)
        names, pending = self.execution_inventory(job, self.list_executions())
        self.check(not pending and names == self.executions_before,
                   "job executions changed before the migration started; another execution may be active")
        return job

    def check_executions_settled(self, executions):
        names = set()
        prefix = self.cfg.job_name + "/executions/"
        for ex in executions:
            name = ex.get("name")
            self.check(isinstance(name, str) and name.startswith(prefix), "execution listing returned an invalid entry")
            self.check(self.execution_settled(ex),
                       f"job execution {short_name(name)} has not settled; a prior run may still be active")
            names.add(name)
        return names

    def complete_bootstrap_record(self):
        """Etag-guarded completion of this run's bootstrap job record. The
        same read whose etag is sent must still carry this run's record in
        the bootstrap-migrating phase and the verified generation, so a
        superseded controller can never overwrite its successor's record."""
        job = self.get_job()
        try:
            self.validate_job(job)
            self.check(self.owns(job, (PHASE_BOOTSTRAP_MIGRATING,)),
                       "the migration job's ownership record is no longer this run's before the bootstrap "
                       "completion write; another run took over")
            self.check(job["generation"] == self.job_generation,
                       "the job changed before the bootstrap completion write")
        except GateError:
            self.migration = MIGRATION_UNKNOWN
            raise
        body = self.job_body(job)
        self.with_annotation(body, self.make_checkpoint(PHASE_COMPLETED, None, execution=self.execution_name,
                                                        executions=sorted(self.executions_before
                                                                          | {self.execution_name})))
        op = self.api.write("PATCH", self.run_url(self.cfg.job_name), "job ownership record completion", body)
        self.wait_operation(op, "job ownership record completion")
        job = self.get_job()
        self.validate_job(job)
        self.check(self.owns(job, (PHASE_COMPLETED,)), "job ownership record was not completed as expected")
        self.job_phase = PHASE_COMPLETED
        self.job_etag = job["etag"]
        self.job_generation = job["generation"]
        return job

    # -- telemetry -------------------------------------------------------

    def coverage_preflight(self, allow_missing=False):
        """Read-only telemetry coverage check before any write.

        For a running service, missing coverage refuses before Fleet is
        stopped (the post-stop proof could not succeed). For a service an
        earlier run already left stopped (allow_missing), the query still
        discovers revisions and fatal anomalies, but missing coverage does
        not block: the bounded post-claim zero proof decides."""
        now = self.api.server_now_ns
        series, observed = self.query_instance_count(now - COVERAGE_LOOKBACK * NANOS, now)
        result = analyze_coverage(series, self.cfg, now, observed, self.revisions)
        if result.fatal:
            self.fail("telemetry preflight: " + "; ".join(sorted(set(result.fatal))))
        self.required_revisions = set(self.revisions) | result.revisions
        if result.pending and allow_missing:
            self.log("no recent active and idle instance_count telemetry for revision(s) "
                     + ", ".join(result.pending) + "; Fleet is already stopped, so this run goes on to the "
                     "bounded post-claim zero proof")
            return
        if result.pending:
            self.fail(
                "Cloud Monitoring has no recent active and idle instance_count telemetry for revision(s) "
                + ", ".join(result.pending)
                + f" (lookback {COVERAGE_LOOKBACK}s). The gate cannot prove they have no instances, so it refuses "
                "before stopping Fleet. See the README section on the migration gate."
            )

    def wait_for_verified_zero(self):
        deadline = self.deadline(ZERO_TIMEOUT)
        while True:
            self.recheck_service(phase=PHASE_STOPPED)
            self.recheck_revisions()
            now = self.api.server_now_ns
            if now > self.fence_ns:
                try:
                    series, observed = self.query_instance_count(self.fence_ns, now)
                except ApiError as err:
                    if err.definitive:
                        self.fail(f"telemetry query failed: {err}")
                    series = None
                if series is not None:
                    result = analyze_zero(series, self.cfg, self.fence_ns, now, observed, self.required_revisions)
                    # Monotonic: a revision seen once must get its own explicit
                    # zero, even if later responses omit it.
                    self.required_revisions |= result.revisions
                    if result.fatal:
                        self.fail("telemetry: " + "; ".join(sorted(set(result.fatal))))
                    if not result.pending:
                        self.zero_at = result.zero_at
                        # The proof is only "current" while the service stays
                        # exactly as verified (checked in final_fleet_state).
                        self.zero_proof_current = True
                        return
                    self.log("waiting for explicit zero telemetry for: " + ", ".join(result.pending))
            if self.expired(deadline):
                self.fail(f"no verified actual zero for every revision within {ZERO_TIMEOUT}s; the migration was not "
                          "run")
            self.clock.sleep(ZERO_POLL)

    def recheck_zero_after_migration(self):
        now = self.api.server_now_ns
        series, observed = self.query_instance_count(self.fence_ns, now)
        result = analyze_zero(series, self.cfg, self.fence_ns, now, observed, self.required_revisions)
        self.required_revisions |= result.revisions
        if result.fatal or result.pending or set(result.zero_at) != set(self.zero_at):
            self.zero_proof_current = False
            self.fail("telemetry after the migration no longer shows a verified zero for every revision; "
                      "an instance may have run during the migration")

    # -- migration -------------------------------------------------------

    def run_migration(self, recheck):
        """Start exactly one execution and poll it to a verified outcome."""
        url = self.run_url(self.cfg.job_name) + ":run"
        self.log("starting the migration job (single execution)")
        self.migration = MIGRATION_UNKNOWN
        try:
            op = self.api.write("POST", url, "job :run", {"etag": self.job_etag})
        except ApiError as err:
            self.ensure_no_new_execution_after_rejection()
            self.migration = MIGRATION_NOT_RUN
            self.fail(f"the migration job was not started: {err}")
        except WriteOutcomeUnknown as err:
            self.fail(f"the migration job start outcome is unknown ({err}); this run does not retry it. A later "
                      "terraform apply waits for any execution it may have started to settle before running one "
                      "fresh migration")
        metadata = op.get("metadata") if isinstance(op, dict) else None
        name = metadata.get("name") if isinstance(metadata, dict) else None
        op_name = op.get("name") if isinstance(op, dict) else None
        if (not isinstance(name, str) or not name.startswith(self.cfg.job_name + "/executions/")
                or not isinstance(op_name, str) or not op_name.startswith(self.cfg.location_name + "/operations/")):
            self.fail("the :run response does not identify the execution; outcome is ambiguous")
        self.execution_name = name
        self.check_embedded_execution_image(metadata, "the :run operation metadata")
        timeout = self.migration_timeout
        deadline = self.deadline(timeout)
        while True:
            self.clock.sleep(MIGRATION_POLL)
            recheck()
            self.read_owned_job("during the migration")
            executions = self.list_executions()
            new = {e.get("name") for e in executions} - self.executions_before
            self.check(new == {name}, "unexpected job executions appeared during the migration")
            execution = next(e for e in executions if e.get("name") == name)
            op, _ = self.api.get(self.run_url(op_name), "run operation")
            outcome = self.evaluate_execution(op, execution)
            if outcome == "succeeded":
                tasks = self.list_tasks(name)
                self.verify_tasks(tasks)
                self.migration = MIGRATION_SUCCEEDED
                self.verify_execution_inventory("after the migration")
                self.log(f"migration execution {short_name(name)} verified successful")
                return
            if outcome == "failed":
                self.migration = MIGRATION_FAILED
                self.fail(f"migration execution {short_name(name)} did not succeed")
            if self.expired(deadline):
                self.fail(f"migration execution {short_name(name)} did not reach a verified outcome within {timeout}s")

    def verify_execution_inventory(self, when):
        """The job is still this run's and unchanged, and its executions are
        exactly the settled baseline plus this run's verified-successful
        execution (whose template and runtime image are re-verified against
        the digest pinned in this run). A latestCreatedExecution naming any
        other execution fails too.

        Called after task verification and immediately before every write
        that lets Fleet start (new image, scaling restore, bootstrap
        completion). Anything else makes the database state uncertain.
        """
        try:
            job = self.read_owned_job(when)
            executions = self.list_executions()
            names = [e.get("name") for e in executions]
            known = self.executions_before | {self.execution_name}
            self.check(len(names) == len(set(names)) and set(names) == known,
                       f"unexpected job executions exist {when}")
            latest = self.latest_created_execution(job)
            self.check(latest is None or latest[0] in known, f"unexpected job executions exist {when}")
            self.check_executions_settled([e for e in executions if e.get("name") != self.execution_name])
            owned = next(e for e in executions if e.get("name") == self.execution_name)
            try:
                counts = [proto_int(owned, k) for k in
                          ("failedCount", "cancelledCount", "runningCount", "retriedCount")]
                succeeded = proto_int(owned, "succeededCount")
                failed_condition = any_failed_condition(owned)
            except ValueError:
                self.fail(f"the migration execution status is malformed {when}")
            self.check(owned.get("completionTime") and succeeded == 1 and not any(counts) and not failed_condition
                       and owned.get("reconciling", False) is False
                       and has_condition(owned, "Completed", CONDITION_SUCCEEDED),
                       f"the migration execution no longer reports success {when}")
            self.check_owned_execution_image(owned)
        except GateError:
            self.migration = MIGRATION_UNKNOWN
            raise
        except ApiError as err:
            self.migration = MIGRATION_UNKNOWN
            self.fail(f"job executions could not be re-verified {when} ({err})")

    def desired_serving(self, job):
        task_template = job["template"]["template"]
        container = single_container(task_template, "job task template")
        key = task_template.get("encryptionKey")
        self.check(key is None or (isinstance(key, str) and key), "job encryptionKey is malformed")
        try:
            return ServingConfig(self.cfg.image, json.loads(json.dumps(container.get("env", []))), key)
        except ValueError as err:
            self.fail(f"the job's serving configuration cannot be used ({err})")

    def ensure_no_new_execution_after_rejection(self):
        try:
            executions = self.list_executions()
            job = self.get_job()
            latest = self.latest_created_execution(job) if isinstance(job, dict) else None
        except (ApiError, GateError):
            self.fail("the :run request was rejected but executions could not be re-checked; outcome unknown")
        names = {e.get("name") for e in executions}
        if names != self.executions_before or (latest is not None and latest[0] not in self.executions_before):
            self.fail("the :run request was rejected but a new execution exists; outcome unknown")

    def evaluate_execution(self, op, execution):
        """Return 'succeeded', 'failed' or 'pending'. Unknown shapes fail."""
        try:
            failed = proto_int(execution, "failedCount")
            cancelled = proto_int(execution, "cancelledCount")
            running = proto_int(execution, "runningCount")
            retried = proto_int(execution, "retriedCount")
            succeeded = proto_int(execution, "succeededCount")
            conditions_of(execution)
        except ValueError:
            self.fail("execution status is malformed")
        if failed or cancelled or retried or any_failed_condition(execution):
            return "failed"
        if op.get("done") and "error" in op:
            return "failed"
        for field in ("metadata", "response"):
            self.check_embedded_execution_image(op.get(field), f"the run operation {field}")
        if not execution.get("completionTime") or not op.get("done"):
            self.check_pending_execution_image(execution)
            return "pending"
        response = op.get("response")
        self.check(isinstance(response, dict) and response.get("name") == self.execution_name,
                   "the run operation finished without the expected execution")
        self.check(execution.get("name") == self.execution_name and execution.get("uid"),
                   "execution identity is missing")
        self.check(execution.get("job") == self.cfg.job, "execution belongs to another job")
        self.check(execution.get("reconciling", False) is False, "execution is still reconciling")
        self.check_owned_execution_image(execution)
        self.check(succeeded == 1 and running == 0, "execution did not report exactly one succeeded task")
        self.check(has_condition(execution, "Completed", CONDITION_SUCCEEDED),
                   "execution has no Completed=CONDITION_SUCCEEDED condition")
        return "succeeded"

    def check_pending_execution_image(self, execution):
        """While the owned execution is still running, any image it already
        reports must be the target (and agree with any digest already seen),
        so a digest reported while pending cannot silently change by
        completion. An execution that reports no template yet is checked at
        completion, where the template is required."""
        if "template" not in execution:
            return
        self.check(execution.get("name") == self.execution_name and execution.get("uid")
                   and execution.get("job") == self.cfg.job,
                   "execution identity is missing or belongs to another job")
        # Execution.template is the TaskTemplate.
        container = single_container(execution.get("template"), "execution task template")
        self.check_runtime_image(container.get("image"), "execution")

    def check_embedded_execution_image(self, embedded, where):
        """The :run operation's metadata and response may embed the owned
        Execution, including its image. Any such image must pass the same
        runtime check (and agree with the pinned digest). A payload without a
        template (for example name-only metadata) has nothing to check. The
        operation is the one returned by this run's :run; an embedded
        execution must still name the owned execution (and this job, if it
        says), or it is not trusted."""
        if not isinstance(embedded, dict) or "template" not in embedded:
            return
        self.check(embedded.get("name") == self.execution_name
                   and embedded.get("job", self.cfg.job) == self.cfg.job,
                   f"{where} embeds an execution other than this run's")
        # Execution.template is the TaskTemplate.
        container = single_container(embedded.get("template"), "execution task template")
        self.check_runtime_image(container.get("image"), "execution")

    def check_owned_execution_image(self, execution):
        """Re-verify the owned execution's template, including its runtime
        image against the digest pinned in this run."""
        self.check_execution_template(
            {"taskCount": execution.get("taskCount"), "parallelism": execution.get("parallelism"),
             "template": execution.get("template")}, "execution", runtime=True)

    def verify_tasks(self, tasks):
        """The owned execution's single task completed one successful attempt.

        Identity: Cloud Run v2 may omit Task.uid (the field is documented
        but absent from observed tasks.list responses),
        so the task is bound by what the API does return: its full resource
        name, which must be exactly one task-id segment under this run's own
        execution (itself bound by the :run operation, its uid, the pinned
        job generation and the execution inventory), and its execution and
        job fields, which must name that execution and this job. The listing
        is the owned execution's own tasks collection and must hold exactly
        one task. A uid is neither required nor used.
        """
        self.check(len(tasks) == 1, "the execution must have exactly one task")
        task = tasks[0]
        try:
            # Task.index and Task.retried are plain proto3 int32 fields:
            # ProtoJSON omits them when they are 0.
            index = proto_int(task, "index")
            retried = proto_int(task, "retried")
            conditions_of(task)
        except ValueError:
            self.fail("task status is malformed")
        name = task.get("name")
        self.check(isinstance(name, str)
                   and re.fullmatch(re.escape(self.execution_name) + r"/tasks/[^/]+", name),
                   "task name is missing or is not a task of this run's execution")
        self.check(task.get("execution") == short_name(self.execution_name), "task belongs to another execution")
        self.check(task.get("job") == self.cfg.job, "task belongs to another job")
        self.check(index == 0 and retried == 0, "task was retried or is not the only task")
        self.check(task.get("completionTime") and task.get("reconciling", False) is False, "task has not completed")
        self.check(has_condition(task, "Completed", CONDITION_SUCCEEDED) and not any_failed_condition(task),
                   "task has no Completed=CONDITION_SUCCEEDED condition")
        result = task.get("lastAttemptResult")
        self.check(isinstance(result, dict), "task has no lastAttemptResult; the exit code cannot be verified")
        # TaskAttemptResult.exit_code and term_signal are ordinary proto3
        # int32 fields, NOT a oneof. ProtoJSON may omit their default zeros.
        # Accept those documented defaults only inside a present attempt
        # result, after the execution and task have independently succeeded.
        # Missing result/identity/completion evidence still fails closed.
        self.check(set(result) <= {"status", "exitCode", "termSignal"},
                   "task result contains unsupported fields")
        status = result.get("status", {})
        self.check(isinstance(status, dict) and set(status) <= {"code", "message", "details"},
                   "task attempt status is malformed or contains unsupported fields")
        self.check(isinstance(status.get("message", ""), str)
                   and isinstance(status.get("details", []), list),
                   "task attempt status information is malformed")
        try:
            exit_code = proto_int(result, "exitCode")
            signal = proto_int(result, "termSignal")
            code = proto_int(status, "code")
        except ValueError:
            self.fail("task lastAttemptResult is malformed")
        self.check(exit_code == 0 and signal == 0 and code == 0,
                   "task did not report a successful normal exit")
        container = single_container(task, "task")
        self.check_runtime_image(container.get("image"), "task")

    # -- protocol: entry point -------------------------------------------

    def run(self):
        cfg = self.cfg
        self.log(f"run {cfg.run_id}: service {cfg.service}, job {cfg.job}, region {cfg.region}")
        job = self.read_unclaimed_job()
        self.timeout_from_job(job)
        self.describe_job_record(job)
        # Read-only: never overlap a prior execution. Anything still running
        # (or not consistently visible) is waited for, bounded; it is never
        # taken to mean "nothing is running".
        job, _ = self.wait_for_settled_inventory("before any change", self.read_unclaimed_job)
        svc, _ = self.get_service(allow_404=True)
        if svc is None:
            return self.bootstrap(job)
        return self.upgrade(svc, job)

    def timeout_from_job(self, job):
        timeout = parse_duration_seconds(job["template"]["template"]["timeout"])
        self.migration_timeout = timeout + MIGRATION_MARGIN

    def describe_job_record(self, job):
        """Log an earlier run's job record. It is internal metadata: it is
        neither a lock nor evidence that a migration succeeded, and this run
        replaces it with its own claim."""
        cp = parse_checkpoint(job)
        if cp is False:
            self.log("the job carries an unrecognised migration-gate record; it confers nothing and this run "
                     "replaces it with its own claim")
        elif isinstance(cp, dict) and cp.get("phase") != PHASE_COMPLETED:
            self.log(f"the job carries an unfinished record from run {cp.get('run')!s:.64} "
                     f"(phase {cp.get('phase')!s:.32}); this run re-checks the current state and claims the job")

    # -- protocol: fresh bootstrap ---------------------------------------

    def bootstrap(self, job):
        """Fresh deployment: the service does not exist.

        Every bootstrap run proves absence afresh and runs one fresh
        migration under its own claim. An earlier record (unfinished, or
        completed with an inventory that no longer matches) neither blocks
        this nor substitutes for the migration."""
        self.fleet = FLEET_NOT_CREATED
        self.log("service not found; checking that this is a fresh deployment")
        self.check_fresh()
        self.claim_job(job, PHASE_BOOTSTRAP_MIGRATING)
        _, self.executions_before = self.wait_for_settled_inventory(
            "after claiming the job", lambda: self.read_owned_job("after the ownership claim", same_etag=True))
        # The service must still be absent right before :run.
        self.check_fresh()
        self.final_launch_check()

        def recheck():
            svc, _ = self.get_service(allow_404=True)
            self.check(svc is None, "a Fleet service appeared during the bootstrap migration")

        self.run_migration(recheck)
        recheck()
        self.verify_execution_inventory("before completing the bootstrap")
        try:
            self.complete_bootstrap_record()
        except (ApiError, WriteOutcomeUnknown) as err:
            self.fail(f"the migration succeeded but this run's job ownership record could not be completed ({err}); "
                      "Terraform does not create the service in this apply. A later terraform apply proves the "
                      "deployment is still fresh and runs one fresh migration")
        recheck()
        self.verify_execution_inventory("before Terraform creates the service")
        self.log("fresh bootstrap migration verified; Terraform may now create the service")
        return 0

    def check_fresh(self):
        svc, _ = self.get_service(allow_404=True)
        self.check(svc is None, "a Fleet service exists; refusing the fresh bootstrap path")
        self.check_no_fleet_in_listing(self.list_services())
        now = self.api.server_now_ns
        series, _ = self.query_instance_count(now - BOOTSTRAP_LOOKBACK * NANOS, now)
        self.check(not series, "Cloud Monitoring reports recent Fleet service instances; this is not a fresh deployment")

    def check_no_fleet_in_listing(self, entries):
        """Absence proof over services.list(showDeleted=true) for this project
        and region.

        Every entry must carry a structured identity; an unidentifiable entry
        could be the Fleet service, so it is UNKNOWN and refuses. The listing
        is scoped to this project, which the API may spell as the project ID
        or the project number; the number cannot be mapped to the ID here, so
        any numeric spelling is treated as this project (an alias can only make
        the gate refuse, never let a soft-deleted Fleet service through). Any
        other project spelling, or another location, is unexpected and refuses.
        A match is decided on the service name component alone.
        """
        for entry in entries:
            name = entry.get("name")
            m = re.fullmatch(r"projects/([^/]+)/locations/([^/]+)/services/([^/]+)", name) \
                if isinstance(name, str) else None
            self.check(m is not None,
                       "the service listing returned an entry without a valid name; Fleet's absence cannot be proven")
            project, location, service = m.groups()
            self.check(project == self.cfg.project or re.fullmatch(r"[1-9][0-9]{0,24}", project),
                       "the service listing returned an entry for an unexpected project; Fleet's absence cannot "
                       "be proven")
            self.check(location == self.cfg.region,
                       "the service listing returned an entry for an unexpected location; Fleet's absence cannot "
                       "be proven")
            self.check(service != self.cfg.service,
                       "a Fleet service with this name exists or is soft-deleted; its instances may not have "
                       "drained, so this cannot be proven a fresh deployment")

    # -- protocol: upgrade -----------------------------------------------

    def recovery_record(self, checkpoint):
        """The semantically valid unfinished service record of an earlier run
        of this gate, as {run, phase, pre_scaling (normalized)}; else None.

        Validity is semantic (v1, a known unfinished phase, a run id, and a
        usable recorded scaling that is not itself a stop); key order, extra
        keys and the recorded image/trigger do not matter, because each run
        re-derives its target from the current, generation-pinned job.
        Anything else is not trusted and confers no recovery authority."""
        if not isinstance(checkpoint, dict) or checkpoint.get("phase") not in SERVICE_UNFINISHED_PHASES:
            return None
        run = checkpoint.get("run")
        if not isinstance(run, str) or not re.fullmatch(Config.PATTERNS["run_id"], run):
            return None
        raw = checkpoint.get("pre_scaling")
        if not isinstance(raw, dict):
            return None
        try:
            pre_scaling = normalize_scaling(raw)
        except ValueError:
            return None
        if pre_scaling["scalingMode"] == "MANUAL" and pre_scaling["manualInstanceCount"] == 0:
            return None
        return {"run": run, "phase": checkpoint["phase"], "pre_scaling": pre_scaling}

    def wait_for_settled_service(self, svc):
        """Read-only, bounded: a service left stopped by an earlier run may
        still be reconciling (for example a late rollout). Wait for it to
        settle under the same record; never write meanwhile."""
        raw = (svc.get("annotations") or {}).get(CHECKPOINT_ANNOTATION)
        deadline = self.deadline(ROLLOUT_TIMEOUT)
        while True:
            try:
                settled = svc.get("reconciling", False) is False and (
                    proto_int(svc, "observedGeneration", default_zero=False)
                    == proto_int(svc, "generation", default_zero=False)
                    or failed_reconciliation(svc))
            except ValueError:
                self.fail("service generation fields are malformed")
            if settled:
                return svc
            if self.expired(deadline):
                self.fail(f"the stopped Fleet service is still reconciling after {ROLLOUT_TIMEOUT}s; nothing was "
                          "changed. A later terraform apply re-checks automatically")
            self.log("waiting for the stopped service to finish reconciling")
            self.clock.sleep(ROLLOUT_POLL)
            svc, _ = self.get_service()
            self.check(svc is not None, "service disappeared")
            self.check(is_stopped_scaling(svc.get("scaling"))
                       and (svc.get("annotations") or {}).get(CHECKPOINT_ANNOTATION) == raw,
                       "the stopped service changed while waiting for it to settle; another writer is active")

    def upgrade(self, svc, job):
        cp = parse_checkpoint(svc)
        record = self.recovery_record(cp)
        if record is not None and is_stopped_scaling(svc.get("scaling")):
            # Recovery of a service an earlier run left stopped.
            self.rollout_exempt = True
            self.fleet = FLEET_PRIOR_STOP
            svc = self.wait_for_settled_service(svc)
        self.validate_service(svc, expect_stopped=False)
        self.check_latest_traffic(svc)
        if record is not None:
            pre_scaling = record["pre_scaling"]
            self.log(f"continuing from run {record['run']}'s unfinished gate record (phase {record['phase']}): its "
                     f"pre-migration scaling {json.dumps(pre_scaling, sort_keys=True)} is kept; this run claims the "
                     "record, proves zero afresh and runs one fresh migration")
        else:
            try:
                pre_scaling = normalize_scaling(svc.get("scaling"))
            except ValueError as err:
                self.fail(f"service scaling cannot be captured ({err})")
            if pre_scaling["scalingMode"] == "MANUAL" and pre_scaling["manualInstanceCount"] == 0:
                self.fail("service is already MANUAL with 0 instances but carries no valid gate record holding its "
                          "pre-migration scaling (this state was not produced by the gate); the gate never guesses "
                          "scaling, refusing")
            if cp is False or (isinstance(cp, dict) and cp.get("phase") != PHASE_COMPLETED):
                self.log("the service carries a migration-gate record that is not a valid unfinished record; it "
                         "confers nothing, and this run records the current scaling instead")
        latest_ready = svc.get("latestReadyRevision")
        latest_created = svc.get("latestCreatedRevision")
        if self.rollout_exempt:
            self.check(isinstance(latest_created, str) and latest_created,
                       "the service reports no latest created revision")
        else:
            self.check(latest_ready and latest_ready == latest_created,
                       "the latest created revision is not ready; refusing")
        self.revisions = self.revision_names(self.list_revisions())
        for value in (latest_ready, latest_created):
            if value:
                self.check(short_name(value) in self.revisions, "revision listing is incomplete")
        # Validate the serving configuration the gate will deploy after the
        # migration now, so an unusable job fails before Fleet is stopped.
        self.desired_serving(job)
        self.coverage_preflight(allow_missing=self.rollout_exempt)

        # --- Claim the job: fences :run requests prepared with older etags ---
        self.claim_job(job, PHASE_CLAIMED)
        _, self.executions_before = self.wait_for_settled_inventory(
            "after claiming the job", lambda: self.read_owned_job("after the ownership claim", same_etag=True))

        # --- Claim/stop the service (atomic with the checkpoint) ---
        self.checkpoint = self.make_checkpoint(PHASE_STOPPED, pre_scaling)
        body = dict(svc)
        stop = {"scalingMode": "MANUAL", "manualInstanceCount": 0, "minInstanceCount": 0}
        if pre_scaling["maxInstanceCount"]:
            stop["maxInstanceCount"] = pre_scaling["maxInstanceCount"]
        body["scaling"] = stop
        self.with_annotation(body, self.checkpoint)
        self.log("stopping Fleet: service scaling -> MANUAL, 0 instances (pre-migration scaling recorded)")
        try:
            self.patch_service(body, "service stop")
        except ApiError as err:
            self.fail(f"the stop was rejected ({err}); Fleet was not changed by this run")
        except WriteOutcomeUnknown as err:
            self.stop_attempted = True
            self.fail(f"the stop outcome is unknown ({err})")
        self.stop_attempted = True
        self.fleet = FLEET_STATE_UNKNOWN
        stopped, date_ns = self.get_service()
        self.check(stopped is not None, "service disappeared after the stop")
        self.validate_service(stopped, expect_stopped=True, expect_phase=PHASE_STOPPED)
        self.check(stopped["uid"] == svc["uid"], "service was replaced during the stop")
        self.expected_service = (stopped["etag"], stopped["generation"])
        self.fleet = FLEET_RESTART_DISABLED
        try:
            update_ns = parse_rfc3339_ns(stopped.get("updateTime"))
        except ValueError:
            self.fail("service updateTime is missing after the stop")
        # HTTP Date has one-second precision: the confirmation happened at or
        # after Date and before Date + 1 s, so only points after Date + 1 s are
        # guaranteed to be later than the confirmed stop (or, for a service an
        # earlier run left stopped, than this run's takeover).
        self.fence_ns = max(date_ns + NANOS, update_ns)
        self.log(f"stop confirmed; telemetry fence {format_rfc3339_ns(self.fence_ns)}")
        self.recheck_revisions()

        # --- Verified actual zero (fresh, after this run's claim) ---
        self.wait_for_verified_zero()
        self.log("verified explicit zero active and idle instances for every revision")

        # --- Record intent to run, then run exactly once ---
        current = self.recheck_service(phase=PHASE_STOPPED)
        self.final_launch_check()
        self.write_service_phase(current, PHASE_MIGRATING, "service checkpoint (migrating)")
        self.recheck_revisions()
        self.final_launch_check()
        self.run_migration(lambda: self.recheck_service(phase=PHASE_MIGRATING))
        self.recheck_revisions()
        self.recheck_zero_after_migration()
        current = self.recheck_service(phase=PHASE_MIGRATING)
        self.write_service_phase(current, PHASE_MIGRATED, "service checkpoint (migrated)")

        # --- Resume: new serving config first (still MANUAL/0), then scaling ---
        self.roll_out_serving_config()
        self.restore_scaling()
        self.log("Fleet resumed on the new image with the pre-migration scaling restored")
        return 0

    def write_service_phase(self, svc, phase, label):
        body = dict(svc)
        self.with_annotation(body, dict(self.checkpoint, phase=phase))
        try:
            self.patch_service(body, label)
        except ApiError as err:
            self.fail(f"{label} write was rejected ({err}); another writer may be active")
        except WriteOutcomeUnknown as err:
            self.fail(f"{label} write outcome is unknown ({err})")
        updated, _ = self.get_service()
        self.check(updated is not None, "service disappeared")
        self.validate_service(updated, expect_stopped=True, expect_phase=phase)
        self.check(updated["uid"] == svc["uid"], "service was replaced")
        self.expected_service = (updated["etag"], updated["generation"])
        return updated

    def fresh_revision_name(self, svc):
        """A new, unused, run-derived revision name for redeploying an
        unchanged template whose latest revision failed. Cloud Run revision
        names are service-prefixed DNS labels (at most 63 characters) and
        immutable; the name is checked against the full revision inventory
        (including deleted revisions) and never reuses an existing one."""
        existing = self.revision_names(self.list_revisions())
        self.check(existing == self.revisions,
                   "the revision inventory changed while Fleet was stopped; a configuration change occurred")
        existing = existing | {svc["template"].get("revision")}
        for attempt in range(8):
            suffix = hashlib.sha256(f"{self.cfg.run_id}/{attempt}".encode("utf-8")).hexdigest()[:10]
            name = f"{self.cfg.service}-g{suffix}"
            if (len(name) <= 63 and re.fullmatch(r"[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?", name)
                    and name not in existing):
                return name
        self.fail("could not derive an unused revision name for this run")

    def roll_out_serving_config(self):
        """Deploy the target image and the job's serving env/CMEK key while the
        service is still MANUAL/0, and wait for a Ready revision that runs it.

        If the service template already runs exactly that configuration and
        its latest revision is Ready (for example first inclusion of the gate
        with an unchanged image, or an earlier run's rollout that finished),
        no template write is made and the current Ready revision is verified.
        If the template matches but its latest revision is not Ready (an
        earlier rollout failed), the same template is deployed again under a
        fresh explicit revision name, so a genuinely new revision is created.
        Otherwise the changed template is deployed and Google names the
        revision.
        """
        self.verify_execution_inventory("before deploying the new image and serving configuration")
        svc = self.recheck_service(phase=PHASE_MIGRATED)
        desired = self.desired_serving(self.get_job())
        # Any rollout step may start an instance of the new configuration
        # (allowed: the migration is verified). From here on the measured-zero
        # proof no longer describes the service.
        self.zero_proof_current = False
        matches = desired.matches(svc["template"])
        latest_ok = ((svc.get("terminalCondition") or {}).get("state") == CONDITION_SUCCEEDED
                     and svc.get("latestReadyRevision")
                     and svc.get("latestReadyRevision") == svc.get("latestCreatedRevision"))
        if matches and latest_ok:
            self.log("the service already has the target image and serving configuration; no new revision needed")
            self.rollout_exempt = False
            current = self.write_service_phase(svc, PHASE_ROLLING_OUT, "service checkpoint (rolling-out)")
            self.check(current.get("latestReadyRevision") == svc.get("latestReadyRevision")
                       and current.get("latestReadyRevision") == current.get("latestCreatedRevision"),
                       "the serving revision changed unexpectedly")
            self.check_latest_traffic(current, current["latestReadyRevision"])
            self.verify_ready_revision(current["latestReadyRevision"], desired)
            self.check(self.revision_names(self.list_revisions()) == self.revisions,
                       "unexpected revisions appeared during the rollout")
            self.verify_execution_inventory("during the rollout")
            return

        forced_name = self.fresh_revision_name(svc) if matches else None
        old_latest = svc.get("latestCreatedRevision")
        body = dict(svc)
        template = json.loads(json.dumps(svc["template"]))
        container = single_container(template, "service template")
        container["image"] = desired.image
        container["env"] = desired.env
        if desired.encryption_key is None:
            template.pop("encryptionKey", None)
        else:
            template["encryptionKey"] = desired.encryption_key
        if forced_name is None:
            # Revision names are immutable: never reuse the current (possibly
            # generated) name for the new template; Google names it.
            template.pop("revision", None)
            self.log("migration verified; deploying the new image and serving configuration while Fleet is still "
                     "MANUAL/0")
        else:
            template["revision"] = forced_name
            self.log(f"migration verified; the template already has the target configuration but its latest "
                     f"revision is not Ready, so it is deployed again as new revision {forced_name} while Fleet is "
                     "still MANUAL/0")
        body["template"] = template
        self.with_annotation(body, dict(self.checkpoint, phase=PHASE_ROLLING_OUT))
        # From this write on, an earlier failed rollout no longer excuses a
        # failed or unready service: only this run's new revision counts.
        self.rollout_exempt = False
        try:
            self.patch_service(body, "service new revision",
                               on_poll=lambda: self.verify_execution_inventory("during the rollout"))
        except ApiError as err:
            self.fail(f"deploying the new revision was rejected ({err}); Fleet remains stopped")
        except WriteOutcomeUnknown as err:
            # Either outcome keeps MANUAL/0 (the write does not touch scaling);
            # the failure report re-verifies the stop. The old revision is never
            # restarted.
            self.fail(f"deploying the new revision did not complete ({err}); Fleet remains stopped")
        first, _ = self.get_service()
        self.check(first is not None and first["uid"] == svc["uid"], "service disappeared or was replaced")
        self.check(self.owns(first, (PHASE_ROLLING_OUT,)), "the new revision write was not recorded as expected")
        generation = first["generation"]
        deadline = self.deadline(ROLLOUT_TIMEOUT)
        current = first
        while True:
            # Re-check the job and its executions on every poll: Fleet must not
            # start while another execution exists.
            self.verify_execution_inventory("during the rollout")
            if self.new_revision_ready(current, old_latest, desired, generation):
                break
            if self.expired(deadline):
                self.fail(f"no new Ready revision with the target configuration under MANUAL/0 within "
                          f"{ROLLOUT_TIMEOUT}s; Fleet remains stopped (the old revision is not restarted)")
            self.clock.sleep(ROLLOUT_POLL)
            current, _ = self.get_service()
            self.check(current is not None and current["uid"] == svc["uid"], "service disappeared or was replaced")
            self.check(current.get("generation") == generation, "the service changed during the rollout")
        self.validate_service(current, expect_stopped=True, expect_phase=PHASE_ROLLING_OUT)
        self.check(current["generation"] == generation, "the service changed during the rollout")
        self.check_latest_traffic(current, current["latestReadyRevision"])
        new_rev = short_name(current["latestReadyRevision"])
        self.check(new_rev not in self.revisions, "the ready revision is not a new revision")
        if forced_name is not None:
            self.check(new_rev == forced_name, "the ready revision is not the revision this run deployed")
        self.verify_ready_revision(current["latestReadyRevision"], desired)
        names = self.revision_names(self.list_revisions())
        self.check(names - self.revisions == {new_rev}, "unexpected revisions appeared during the rollout")
        self.verify_execution_inventory("during the rollout")
        self.expected_service = (current["etag"], current["generation"])

    def verify_ready_revision(self, name, desired):
        """The serving revision runs the desired env/CMEK key and the target
        image. Callers have already checked that the generation-pinned
        service template matches the configured image exactly and that this
        is its latest Ready revision. Cloud Run v2 may report the revision
        image as configured (a tag) or resolved (a digest); a digest must
        equal the one the migration execution reported."""
        revision, _ = self.api.get(self.run_url(name), "serving revision")
        self.check(revision.get("name") == name, "serving revision identity mismatch")
        container = desired.serving_container(revision)
        self.check(container is not None,
                   "the serving revision does not run the target image and serving configuration")
        self.check(revision.get("reconciling", False) is False and has_condition(revision, "Ready", CONDITION_SUCCEEDED),
                   "the serving revision is not Ready")
        self.check_runtime_image(container.get("image"), "serving revision")

    def new_revision_ready(self, svc, old_latest, desired, generation):
        """True once this run's rollout produced a new Ready latest revision.

        Status is only evaluated once the service has settled on this run's
        own generation: while it is still reconciling (or reports an older
        observedGeneration), a terminalCondition left by an earlier failed
        rollout is stale and is not this rollout's outcome."""
        if svc.get("reconciling", False) is not False:
            return False
        try:
            if (proto_int(svc, "observedGeneration", default_zero=False) != proto_int(svc, "generation", default_zero=False)
                    or svc.get("generation") != generation):
                return False
        except ValueError:
            return False
        terminal = (svc.get("terminalCondition") or {}).get("state")
        if terminal == CONDITION_FAILED:
            self.fail("the new revision failed to deploy; Fleet remains stopped (the old revision is not restarted)")
        latest_created = svc.get("latestCreatedRevision")
        if not latest_created or latest_created == old_latest or svc.get("latestReadyRevision") != latest_created:
            return False
        return desired.matches(svc.get("template") or {})

    def restore_scaling(self):
        self.verify_execution_inventory("before restoring scaling")
        svc = self.recheck_service(phase=PHASE_ROLLING_OUT)
        body = dict(svc)
        body["scaling"] = scaling_request_body(self.checkpoint["pre_scaling"])
        self.with_annotation(body, dict(self.checkpoint, phase=PHASE_COMPLETED))
        self.log("restoring the pre-migration scaling")
        try:
            self.patch_service(body, "service restore")
            restored, _ = self.get_service()
            self.check(restored is not None, "service disappeared")
            self.check(restored["uid"] == svc["uid"], "service was replaced")
            self.validate_service(restored, expect_stopped=False)
            self.check(normalize_scaling(restored.get("scaling")) == self.checkpoint["pre_scaling"],
                       "restored scaling does not match the recorded pre-migration scaling")
            self.check(self.owns(restored, (PHASE_COMPLETED,)), "completion record was not written")
            self.check(restored.get("latestReadyRevision") == svc.get("latestReadyRevision"),
                       "the serving revision changed during the restore")
            self.check_latest_traffic(restored, restored["latestReadyRevision"])
        except (ApiError, WriteOutcomeUnknown, GateError, ValueError, KeyError, TypeError) as err:
            message = getattr(err, "message", None) or str(err) or type(err).__name__
            self.log(f"restore failed ({message}); attempting a verified re-stop")
            self.restop(message)

    def restop(self, reason):
        """Best effort: return the service to MANUAL/0 keeping the recorded
        pre-migration scaling. The same read whose etag is sent must still
        carry this run's record (rolling-out, or completed if the restore was
        applied) with the same pre-migration scaling; otherwise another run
        owns the service and nothing is written. The failure report
        re-verifies the result and never claims a stop it cannot read back."""
        try:
            svc, _ = self.get_service()
            cp = parse_checkpoint(svc) if svc is not None else None
            if (isinstance(cp, dict) and cp.get("run") == self.cfg.run_id
                    and cp.get("phase") in (PHASE_ROLLING_OUT, PHASE_COMPLETED)
                    and cp.get("pre_scaling") == self.checkpoint["pre_scaling"]):
                body = dict(svc)
                scaling = {"scalingMode": "MANUAL", "manualInstanceCount": 0, "minInstanceCount": 0}
                if self.checkpoint["pre_scaling"]["maxInstanceCount"]:
                    scaling["maxInstanceCount"] = self.checkpoint["pre_scaling"]["maxInstanceCount"]
                body["scaling"] = scaling
                self.with_annotation(body, dict(self.checkpoint, phase=PHASE_FAILED, reason="restore-failed"))
                self.patch_service(body, "service re-stop")
            elif svc is not None:
                self.log("not re-stopping: the service record is no longer this run's")
        except (ApiError, WriteOutcomeUnknown, GateError, ValueError, KeyError, TypeError):
            pass
        self.fail(f"the migration succeeded, but restoring the pre-migration scaling could not be verified ({reason})")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

RETRY_GUIDANCE = (
    "Next step: fix the underlying cause reported above (for example the database, the configuration or a Google "
    "API problem) and run terraform apply again. The next apply re-checks the current state and continues "
    "automatically: it waits for (and never overlaps) a migration that may still be running, keeps the recorded "
    "pre-migration scaling, runs at most one fresh migration, and lets Fleet start only after that migration and "
    f"the target revision are verified. The {CHECKPOINT_ANNOTATION} annotation is internal state, not a lock; "
    "do not edit or remove it."
)


def report_failure(err, log):
    log("FAILED: " + err.message)
    log("Fleet service: " + err.fleet)
    log("Migration: " + err.migration)
    log(RETRY_GUIDANCE)


def main(argv=None, environ=None, transport=None, token_source=None, clock=None, log=None):
    argv = sys.argv[1:] if argv is None else argv
    environ = os.environ if environ is None else environ
    log = log or stderr_log
    if argv != ["run"]:
        log("usage: fleet_migration_gate.py run (configuration via FLEET_GATE_* environment variables)")
        return 2
    gate = None
    try:
        config = Config.from_env(environ)
        clock = clock or SystemClock()
        api = Api(transport or UrllibTransport(), token_source or GcloudAdcTokenSource(), clock, log)
        gate = MigrationGate(config, api, clock, log)
        return gate.run()
    except (GateError, ApiError, WriteOutcomeUnknown, ValueError, KeyError, TypeError, AttributeError) as err:
        if isinstance(err, GateError):
            failure = err
        elif isinstance(err, (ApiError, WriteOutcomeUnknown)):
            failure = GateError(str(err))
        else:
            # Never echo the exception text: it could contain response data.
            failure = GateError(f"unexpected response shape ({type(err).__name__})")
        if gate is not None:
            failure.migration = gate.migration
            failure.fleet = gate.final_fleet_state()
        report_failure(failure, log)
        return 1


if __name__ == "__main__":
    sys.exit(main())
