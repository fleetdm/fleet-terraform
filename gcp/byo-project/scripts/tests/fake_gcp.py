"""Offline fake of the Cloud Run Admin API v2 and Cloud Monitoring v3 subset
used by fleet_migration_gate.py. Test fixture only: nothing here talks to a
network, reads credentials or runs a subprocess.

The fake is deliberately simple and models only the documented contracts the
gate relies on. It is not evidence of how Google behaves; it lets the tests
drive every branch of the gate deterministically.
"""

import copy
import email.utils
import json
import math
import re
import urllib.parse

PROJECT = "fleet-test-project"
REGION = "us-central1"
SERVICE = "fleet-api"
JOB = "fleet-migration"
OLD_IMAGE = "fleetdm/fleet:v4.92.0"
NEW_IMAGE = "fleetdm/fleet:v4.93.0"
# What Cloud Run reports at runtime for NEW_IMAGE (observed shape: the job
# keeps the configured tag; the execution, its task and revisions report the
# Docker Hub tag resolved through Google's mirror to a digest).
NEW_DIGEST = "sha256:fc2e73a94563fe64325ceaffba04e6ca4e0557e2dfb606100d3a8d77e0a2a80f"
OTHER_DIGEST = "sha256:" + "0123456789abcdef" * 4
MIRROR_NEW_IMAGE = "mirror.gcr.io/fleetdm/fleet@" + NEW_DIGEST
TOKEN = "ya29.FAKE-TOKEN-SENTINEL"
SECRET_ENV_VALUE = "FAKE-LICENSE-SECRET-SENTINEL"
RUN_ID = "0b6c7c55-1d5e-4c1c-9a4e-3c8f00000001"
TRIGGER = "a" * 64
JOB_GENERATION = "3"
START = 1_760_000_017.25  # deliberately not aligned to a minute

OLD_DB_ADDRESS = "10.20.0.5:3306"
NEW_DB_ADDRESS = "10.20.0.9:3306"
LOC = f"projects/{PROJECT}/locations/{REGION}"
SVC_NAME = f"{LOC}/services/{SERVICE}"
JOB_NAME = f"{LOC}/jobs/{JOB}"
LATEST = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
OK = "CONDITION_SUCCEEDED"
FAILED = "CONDITION_FAILED"
METRIC = "run.googleapis.com/container/instance_count"
CHECKPOINT = "fleetdm.com/migration-gate"
SERVICE_OUTPUT_ONLY = (
    "uid", "generation", "createTime", "updateTime", "observedGeneration",
    "terminalCondition", "conditions", "latestReadyRevision",
    "latestCreatedRevision", "trafficStatuses", "uri", "reconciling",
)


def env(**overrides):
    values = {
        "FLEET_GATE_PROJECT": PROJECT,
        "FLEET_GATE_REGION": REGION,
        "FLEET_GATE_SERVICE": SERVICE,
        "FLEET_GATE_JOB": JOB,
        "FLEET_GATE_IMAGE": NEW_IMAGE,
        "FLEET_GATE_RUN_ID": RUN_ID,
        "FLEET_GATE_JOB_GENERATION": JOB_GENERATION,
        "FLEET_GATE_TRIGGER": TRIGGER,
    }
    values.update(overrides)
    return {k: v for k, v in values.items() if v is not None}


def fleet_env(db_address=OLD_DB_ADDRESS):
    """Env shared by the Fleet service and job (same Terraform locals)."""
    return [
        {"name": "FLEET_LICENSE_KEY", "value": SECRET_ENV_VALUE},
        {"name": "FLEET_MYSQL_ADDRESS", "value": db_address},
        {"name": "FLEET_REDIS_ADDRESS", "value": "10.30.0.3:6379"},
        {"name": "FLEET_MYSQL_PASSWORD",
         "valueSource": {"secretKeyRef": {"secret": "fleet-db-password", "version": "latest"}}},
    ]


def ts(seconds):
    """RFC 3339 with nanoseconds."""
    whole = math.floor(seconds)
    nanos = int(round((seconds - whole) * 1e9))
    import datetime
    base = datetime.datetime.fromtimestamp(whole, tz=datetime.timezone.utc)
    return base.strftime("%Y-%m-%dT%H:%M:%S") + f".{nanos:09d}Z"


def parse_ts(value):
    m = re.fullmatch(r"(.*T\d\d:\d\d:\d\d)(?:\.(\d+))?Z", value)
    import datetime
    base = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    frac = float("0." + m.group(2)) if m.group(2) else 0.0
    return base.timestamp() + frac


class FakeResponse:
    def __init__(self, status, payload=None, headers=None, raw=None):
        self.status = status
        self.headers = headers or {}
        self.body = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else b"")


class FakeClock:
    def __init__(self, start=START):
        self.t = start
        self.sleeps = []

    def monotonic(self):
        return self.t

    def sleep(self, seconds):
        assert 0 < seconds <= 3600
        self.sleeps.append(seconds)
        self.t += seconds


class FakeToken:
    def __init__(self):
        self.calls = 0

    def token(self):
        self.calls += 1
        return TOKEN


def error(status, rpc):
    return FakeResponse(status, {"error": {"code": status, "status": rpc, "message": "fake " + SECRET_ENV_VALUE}})


class FakeCloud:
    """Stateful fake. Tests mutate attributes/faults to build scenarios."""

    page_size = 2
    latency = 0.05
    visibility_delay = 120

    def __init__(self, service=True):
        self.clock = FakeClock()
        self.skew = 0.0
        self.log = []  # (method, kind, path, query)
        self.bodies = []  # (method, kind, body) for writes
        self.faults = []  # callables (method, kind, path, query, body) -> FakeResponse|None
        self.op_seq = 0
        self.ops = {}
        self.executions = []
        self.deleted_services = []
        self.stop_time = None
        self.restore_time = None
        self.drain = 0
        self.no_metrics_for = set()  # revisions that never emit
        self.no_metrics_after_stop_for = set()
        self.metric_override = None  # callable(rev, state, t, default) -> int|None
        self.series_hook = None  # callable(list_of_series) -> list
        self.monitoring_extra = None  # dict merged into every monitoring page
        self.extra_series = []
        self.bootstrap_series = []
        self.migration_duration = 300
        self.outcome = "success"
        self.execution_hook = None  # callable(execution, tasks, op) mutates
        self.new_revision_ready = True
        self.new_revision_image = None  # image a created revision reports (default: its template's)
        # Images the owned execution's template and its task report. None
        # keeps the old fixture shape (the job's configured image string).
        self.execution_image = None
        self.task_image = None  # default: the execution's image
        self.reflect_revision_name = True
        self.new_revision_hook = None  # callable(revision) mutates a created revision
        self.revision_seq = 2
        self.etag_seq = 0
        self.job = self._make_job()
        self.revisions = [
            self._revision("fleet-api-00001-aaa", OLD_IMAGE, deleted=False),
            self._revision("fleet-api-00002-bbb", OLD_IMAGE, deleted=False),
        ]
        self.service = self._make_service() if service else None
        self.serving = "fleet-api-00002-bbb"

    # -- builders --------------------------------------------------------

    def now(self):
        return self.clock.t + self.skew

    def etag(self, prefix):
        self.etag_seq += 1
        return f'"{prefix}-{self.etag_seq}"'

    def _revision(self, short, image, deleted, template=None):
        """A revision snapshot of a service template (default: the original)."""
        containers = copy.deepcopy((template or {}).get("containers")) or [{"env": fleet_env()}]
        containers[0]["image"] = image
        rev = {
            "name": f"{SVC_NAME}/revisions/{short}",
            "uid": "rev-uid-" + short,
            "generation": "1",
            "containers": containers,
            "conditions": [{"type": "Ready", "state": OK}],
        }
        if template and template.get("encryptionKey"):
            rev["encryptionKey"] = template["encryptionKey"]
        if deleted:
            rev["deleteTime"] = ts(self.now())
        return rev

    def _make_service(self):
        return {
            "name": SVC_NAME,
            "uid": "svc-uid-1",
            "etag": self.etag("svc"),
            "generation": "7",
            "observedGeneration": "7",
            "createTime": ts(START - 86400),
            "updateTime": ts(START - 3600),
            "annotations": {"example.com/owner": "platform-team"},
            "ingress": "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
            "scaling": {"minInstanceCount": 1},
            "template": {
                # A normal GET can reflect the generated revision name; the
                # gate must neither treat it as a user pin nor reuse it.
                "revision": "fleet-api-00002-bbb",
                "scaling": {"maxInstanceCount": 5},
                "containers": [{
                    "image": OLD_IMAGE,
                    "env": fleet_env(),
                    "ports": [{"name": "http1", "containerPort": 8080}],
                    "startupProbe": {"tcpSocket": {"port": 8080}, "initialDelaySeconds": 30},
                }],
            },
            "traffic": [{"type": LATEST, "percent": 100}],
            "trafficStatuses": [{"type": LATEST, "percent": 100}],
            "terminalCondition": {"type": "Ready", "state": OK},
            "latestReadyRevision": f"{SVC_NAME}/revisions/fleet-api-00002-bbb",
            "latestCreatedRevision": f"{SVC_NAME}/revisions/fleet-api-00002-bbb",
            "uri": "https://fleet-api-example.a.run.app",
        }

    def _make_job(self):
        return {
            "name": JOB_NAME,
            "uid": "job-uid-1",
            "etag": self.etag("job"),
            "generation": JOB_GENERATION,
            "observedGeneration": JOB_GENERATION,
            "terminalCondition": {"type": "Ready", "state": OK},
            "template": {
                "taskCount": 1,
                "parallelism": 1,
                "template": {
                    "maxRetries": 0,
                    "timeout": "3600s",
                    "containers": [{
                        "image": NEW_IMAGE,
                        "command": ["fleet"],
                        "args": ["prepare", "db", "--no-prompt=true"],
                        "env": fleet_env(),
                    }],
                },
            },
        }

    def resolve_images(self, image=MIRROR_NEW_IMAGE):
        """Report runtime images the way Cloud Run does for a Docker Hub tag:
        the execution, its task and newly created revisions show the
        mirror.gcr.io digest; the job and service templates keep the
        configured string."""
        self.execution_image = image
        self.new_revision_image = image

    # -- helpers for assertions -------------------------------------------

    def writes(self):
        return [(m, k) for (m, k, _, _) in self.log if m != "GET"]

    def count(self, method, kind):
        return sum(1 for (m, k, _, _) in self.log if m == method and k == kind)

    def run_calls(self):
        return self.count("POST", "run")

    def service_patches(self):
        return [b for (m, k, b) in self.bodies if m == "PATCH" and k == "service"]

    def checkpoint(self):
        if not self.service:
            return None
        raw = (self.service.get("annotations") or {}).get(CHECKPOINT)
        return json.loads(raw) if raw else None

    def index(self, method, kind, nth=0):
        hits = [i for i, (m, k, _, _) in enumerate(self.log) if m == method and k == kind]
        return hits[nth] if len(hits) > nth else None

    # -- transport --------------------------------------------------------

    def request(self, method, url, headers, body):
        self.clock.t += self.latency
        assert headers.get("Authorization") == "Bearer " + TOKEN, "missing or wrong fake auth header"
        parts = urllib.parse.urlsplit(url)
        assert parts.scheme == "https"
        query = dict(urllib.parse.parse_qsl(parts.query, keep_blank_values=True))
        data = json.loads(body.decode()) if body else None
        kind, match = self._route(parts.netloc, parts.path, method)
        self.log.append((method, kind, parts.path, query))
        if method != "GET":
            self.bodies.append((method, kind, copy.deepcopy(data)))
        for fault in list(self.faults):
            resp = fault(method, kind, parts.path, query, data)
            if resp is not None:
                return self._finish(resp)
        handler = getattr(self, "_h_" + kind.replace("-", "_"))
        return self._finish(handler(method, match, query, data))

    def _finish(self, resp):
        if "date" not in {k.lower() for k in resp.headers} and not getattr(resp, "no_date", False):
            resp.headers["Date"] = email.utils.formatdate(math.floor(self.now()), usegmt=True)
        return resp

    ROUTES = [
        ("run.googleapis.com", r"/v2/" + LOC + r"/services", "service-list"),
        ("run.googleapis.com", r"/v2/" + SVC_NAME, "service"),
        ("run.googleapis.com", r"/v2/" + SVC_NAME + r"/revisions", "revisions"),
        ("run.googleapis.com", r"/v2/" + SVC_NAME + r"/revisions/([a-z0-9-]+)", "revision"),
        ("run.googleapis.com", r"/v2/" + JOB_NAME, "job"),
        ("run.googleapis.com", r"/v2/" + JOB_NAME + r":run", "run"),
        ("run.googleapis.com", r"/v2/" + JOB_NAME + r"/executions", "executions"),
        ("run.googleapis.com", r"/v2/" + JOB_NAME + r"/executions/([a-z0-9-]+)/tasks", "tasks"),
        ("run.googleapis.com", r"/v2/" + LOC + r"/operations/([a-z0-9-]+)", "operation"),
        ("monitoring.googleapis.com", r"/v3/projects/" + PROJECT + r"/timeSeries", "monitoring"),
    ]

    def _route(self, host, path, method):
        for rhost, pattern, kind in self.ROUTES:
            m = re.fullmatch(pattern, path)
            if host == rhost and m:
                return kind, m
        raise AssertionError(f"unmatched fake request {method} {host}{path}")

    def _page(self, items, field, query, extra=None):
        assert query.get("showDeleted") == "true", "listings must include deleted resources"
        offset = int(query.get("pageToken", "o0")[1:])
        page = items[offset:offset + self.page_size]
        out = {field: page} if page else {}
        if offset + self.page_size < len(items):
            out["nextPageToken"] = f"o{offset + self.page_size}"
        if extra:
            out.update(extra)
        return FakeResponse(200, out)

    def _new_op(self, response, done_after=1, error=None, pending=None):
        self.op_seq += 1
        name = f"{LOC}/operations/op-{self.op_seq}"
        self.ops[name] = {"polls": 0, "done_after": done_after, "response": response, "error": error, "pending": pending}
        return {"name": name, "done": False, "metadata": {"@type": "type.googleapis.com/google.cloud.run.v2.Service"}}

    # -- handlers ---------------------------------------------------------

    def _h_service_list(self, method, match, query, data):
        assert method == "GET"
        items = list(self.deleted_services)
        if self.service:
            items.append(self._service_view())
        return self._page(items, "services", query)

    def _service_view(self):
        return copy.deepcopy(self.service)

    def _h_service(self, method, match, query, data):
        if self.service is None:
            return error(404, "NOT_FOUND")
        if method == "GET":
            return FakeResponse(200, self._service_view())
        assert method == "PATCH"
        assert not query, "service PATCH must not use query parameters"
        for field in SERVICE_OUTPUT_ONLY:
            assert field not in data, f"output-only field {field} sent in PATCH"
        if data.get("etag") != self.service["etag"]:
            return error(409, "ABORTED")
        old = self.service
        template_changed = self._template_sans_revision(data.get("template")) != \
            self._template_sans_revision(old.get("template"))
        requested = (data.get("template") or {}).get("revision")
        existing = {r["name"].rsplit("/", 1)[-1] for r in self.revisions}
        if template_changed and requested in existing:
            # Revision names are immutable and cannot be reused.
            return error(409, "ALREADY_EXISTS")
        if not template_changed and requested not in (None, (old.get("template") or {}).get("revision")):
            return error(400, "INVALID_ARGUMENT")
        new = copy.deepcopy(data)
        for field in ("uid", "createTime", "uri"):
            new[field] = old[field]
        new["generation"] = str(int(old["generation"]) + 1)
        new["observedGeneration"] = new["generation"]
        new["etag"] = self.etag("svc")
        new["updateTime"] = ts(self.now())
        new["terminalCondition"] = copy.deepcopy(old["terminalCondition"])
        new["latestReadyRevision"] = old["latestReadyRevision"]
        new["latestCreatedRevision"] = old["latestCreatedRevision"]
        new["trafficStatuses"] = copy.deepcopy(old["trafficStatuses"])
        stopped = self._stopped(new.get("scaling"))
        if stopped and not self._stopped(old.get("scaling")):
            self.stop_time = self.now()
        if not stopped and self._stopped(old.get("scaling")):
            self.restore_time = self.now()
        if template_changed:
            self.revision_seq += 1
            short = requested or f"fleet-api-{self.revision_seq:05d}-new"
            if self.reflect_revision_name:
                new["template"]["revision"] = short
            image = self.new_revision_image or new["template"]["containers"][0]["image"]
            rev = self._revision(short, image, deleted=False, template=new["template"])
            if self.new_revision_hook:
                self.new_revision_hook(rev)
            full = rev["name"]
            new["latestCreatedRevision"] = full
            if self.new_revision_ready:
                self.revisions.append(rev)
                new["latestReadyRevision"] = full
                new["trafficStatuses"] = [{"type": LATEST, "percent": 100, "revision": short}]
                self.serving = short
            else:
                rev["conditions"] = [{"type": "Ready", "state": "CONDITION_PENDING"}]
                self.revisions.append(rev)
                new["reconciling"] = True
        self.service = new
        pending = None if self.new_revision_ready or not template_changed else True
        return FakeResponse(200, self._new_op({"name": SVC_NAME}, pending=pending))

    @staticmethod
    def _template_sans_revision(template):
        template = copy.deepcopy(template or {})
        template.pop("revision", None)
        return template

    @staticmethod
    def _stopped(scaling):
        scaling = scaling or {}
        return scaling.get("scalingMode") == "MANUAL" and scaling.get("manualInstanceCount", None) == 0

    def _h_revisions(self, method, match, query, data):
        return self._page(copy.deepcopy(self.revisions), "revisions", query)

    def _h_revision(self, method, match, query, data):
        for rev in self.revisions:
            if rev["name"].endswith("/" + match.group(1)):
                return FakeResponse(200, copy.deepcopy(rev))
        return error(404, "NOT_FOUND")

    def _h_job(self, method, match, query, data):
        if method == "GET":
            return FakeResponse(200, copy.deepcopy(self.job))
        assert method == "PATCH"
        for field in ("uid", "generation", "observedGeneration", "terminalCondition", "startExecutionToken", "runExecutionToken"):
            assert field not in data, f"field {field} must not be sent in a job PATCH"
        if data.get("etag") != self.job["etag"]:
            return error(409, "ABORTED")
        new = copy.deepcopy(data)
        new["uid"] = self.job["uid"]
        new["generation"] = str(int(self.job["generation"]) + 1)
        new["observedGeneration"] = new["generation"]
        new["etag"] = self.etag("job")
        new["terminalCondition"] = copy.deepcopy(self.job["terminalCondition"])
        self.job = new
        return FakeResponse(200, self._new_op({"name": JOB_NAME}))

    def _h_run(self, method, match, query, data):
        assert method == "POST"
        if data.get("etag") != self.job["etag"]:
            return error(409, "ABORTED")
        short = f"fleet-migration-x{len(self.executions) + 1:03d}"
        ex = {
            "name": f"{JOB_NAME}/executions/{short}",
            "uid": "ex-uid-" + short,
            "job": JOB,
            "createTime": ts(self.now()),
            "_start": self.now(),
        }
        self.executions.append(ex)
        self.op_seq += 1
        op_name = f"{LOC}/operations/run-{self.op_seq}"
        self.ops[op_name] = {"execution": ex}
        ex["_op"] = op_name
        return FakeResponse(200, {
            "name": op_name,
            "metadata": {"@type": "type.googleapis.com/google.cloud.run.v2.Execution", "name": ex["name"]},
        })

    def add_prior_execution(self, settled=True):
        short = f"fleet-migration-p{len(self.executions) + 1:03d}"
        ex = {"name": f"{JOB_NAME}/executions/{short}", "uid": "ex-uid-" + short, "job": JOB,
              "_prior": True, "_settled": settled}
        self.executions.append(ex)
        return ex

    def render_execution(self, ex):
        """Public view of an execution and its tasks at the current time."""
        if ex.get("_prior"):
            view = {k: v for k, v in ex.items() if not k.startswith("_")}
            if ex["_settled"]:
                view.update({"completionTime": ts(START - 7200), "succeededCount": 1, "taskCount": 1})
            else:
                view.update({"runningCount": 1, "taskCount": 1})
            return view, [], None
        view = {k: v for k, v in ex.items() if not k.startswith("_")}
        view.update({
            "taskCount": 1,
            "parallelism": 1,
            "template": copy.deepcopy(self.job["template"]["template"]),
            "generation": "1",
            "observedGeneration": "1",
        })
        if self.execution_image is not None:
            view["template"]["containers"][0]["image"] = self.execution_image
        task_short = view["name"].rsplit("/", 1)[-1] + "-0"
        task = {
            "name": f"{view['name']}/tasks/{task_short}",
            "uid": "task-uid",
            "job": JOB,
            "execution": view["name"].rsplit("/", 1)[-1],
            "containers": copy.deepcopy(view["template"]["containers"]),
            "maxRetries": 0,
        }
        if self.task_image is not None:
            task["containers"][0]["image"] = self.task_image
        op = {"name": ex["_op"], "metadata": {"name": view["name"]}}
        finished = self.now() >= ex["_start"] + self.migration_duration and self.outcome != "never"
        if not finished:
            view["runningCount"] = 1
            task["conditions"] = [{"type": "Completed", "state": "CONDITION_PENDING"}]
        elif self.outcome in ("success",):
            view.update({"completionTime": ts(self.now()), "succeededCount": 1,
                         "conditions": [{"type": "Completed", "state": OK}, {"type": "ResourcesAvailable", "state": OK}]})
            # Standard ProtoJSON omits default int32 zeros from a successful result.
            task.update({"completionTime": ts(self.now()), "lastAttemptResult": {"status": {}},
                         "conditions": [{"type": "Completed", "state": OK}]})
            op.update({"done": True, "response": copy.deepcopy(view)})
        elif self.outcome == "fail":
            view.update({"completionTime": ts(self.now()), "failedCount": 1,
                         "conditions": [{"type": "Completed", "state": FAILED}]})
            task.update({"completionTime": ts(self.now()), "lastAttemptResult": {"exitCode": 1},
                         "conditions": [{"type": "Completed", "state": FAILED}]})
            op.update({"done": True, "error": {"code": 2}})
        elif self.outcome == "cancel":
            view.update({"completionTime": ts(self.now()), "cancelledCount": 1})
            task.update({"completionTime": ts(self.now())})
            op.update({"done": True, "error": {"code": 1}})
        else:
            raise AssertionError("unknown outcome")
        tasks = [task]
        if self.execution_hook:
            self.execution_hook(view, tasks, op)
        return view, tasks, op

    def _h_executions(self, method, match, query, data):
        return self._page([self.render_execution(ex)[0] for ex in self.executions], "executions", query)

    def _h_tasks(self, method, match, query, data):
        for ex in self.executions:
            if ex["name"].endswith("/" + match.group(1)):
                return self._page(self.render_execution(ex)[1], "tasks", query)
        return error(404, "NOT_FOUND")

    def _h_operation(self, method, match, query, data):
        name = f"{LOC}/operations/{match.group(1)}"
        op = self.ops.get(name)
        if op is None:
            return error(404, "NOT_FOUND")
        if "execution" in op:
            return FakeResponse(200, self.render_execution(op["execution"])[2])
        op["polls"] += 1
        if op.get("pending") or op["polls"] < op["done_after"]:
            return FakeResponse(200, {"name": name, "done": False})
        out = {"name": name, "done": True}
        if op["error"]:
            out["error"] = op["error"]
        else:
            out["response"] = op["response"]
        return FakeResponse(200, out)

    # -- monitoring -------------------------------------------------------

    def metric_value(self, rev, state, t):
        if rev in self.no_metrics_for:
            return None
        after_stop = self.stop_time is not None and t > self.stop_time
        if after_stop and rev in self.no_metrics_after_stop_for:
            return None
        if self.stop_time is not None and t > self.stop_time + self.drain:
            value = 0
        elif rev == self.serving:
            value = 1 if state == "active" else 0
        else:
            value = 0
        if self.metric_override:
            value = self.metric_override(rev, state, t, value)
        return value

    def _h_monitoring(self, method, match, query, data):
        assert method == "GET"
        expected = {"filter", "interval.startTime", "interval.endTime", "view", "pageSize", "pageToken"}
        assert set(query) <= expected, f"unexpected monitoring parameters {set(query) - expected}"
        assert not any(k.startswith("aggregation") or k.startswith("secondaryAggregation") for k in query)
        assert query["view"] == "FULL"
        f = query["filter"]
        for clause in (f'metric.type = "{METRIC}"', 'resource.type = "cloud_run_revision"',
                       f'resource.labels.project_id = "{PROJECT}"', f'resource.labels.location = "{REGION}"',
                       f'resource.labels.service_name = "{SERVICE}"'):
            assert clause in f, "monitoring filter is missing " + clause
        start = parse_ts(query["interval.startTime"])
        end = parse_ts(query["interval.endTime"])
        assert start <= end
        if self.service is None and self.stop_time is None:
            series = copy.deepcopy(self.bootstrap_series)
        else:
            series = self._series(start, end)
        series.extend(copy.deepcopy(self.extra_series))
        self.current_query = query  # lets hooks act on one whole logical query
        if self.series_hook:
            series = self.series_hook(series)
        offset = int(query.get("pageToken", "o0")[1:])
        page = series[offset:offset + self.page_size]
        out = {"timeSeries": page} if page else {}
        if offset + self.page_size < len(series):
            out["nextPageToken"] = f"o{offset + self.page_size}"
        if self.monitoring_extra:
            out.update(self.monitoring_extra)
        return FakeResponse(200, out)

    def _series(self, start, end):
        visible_until = self.now() - self.visibility_delay
        series = []
        revisions = [r["name"].rsplit("/", 1)[-1] for r in self.revisions]
        for rev in revisions:
            for state in ("active", "idle"):
                points = []
                t = math.floor(start / 60) * 60
                while t <= min(end, visible_until):
                    if t > start:
                        value = self.metric_value(rev, state, t)
                        if value is not None:
                            points.append({"interval": {"startTime": ts(t), "endTime": ts(t)},
                                           "value": {"int64Value": str(value)}})
                    t += 60
                if points:
                    points.reverse()  # Monitoring returns newest first
                    series.append(make_series(rev, state, points))
        return series


def make_series(rev, state, points, **label_overrides):
    resource_labels = {"project_id": PROJECT, "location": REGION, "service_name": SERVICE,
                       "configuration_name": SERVICE, "revision_name": rev}
    resource_labels.update(label_overrides)
    return {
        "metric": {"type": METRIC, "labels": {"state": state}},
        "resource": {"type": "cloud_run_revision", "labels": resource_labels},
        "metricKind": "GAUGE",
        "valueType": "INT64",
        "points": points,
    }


def point(t, value):
    return {"interval": {"startTime": ts(t), "endTime": ts(t)}, "value": {"int64Value": str(value)}}
