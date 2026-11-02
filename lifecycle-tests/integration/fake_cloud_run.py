#!/usr/bin/env python3
"""TEST-ONLY loopback fake of a small Cloud Run Admin API v2 subset.

NOT part of any Terraform apply path. The lifecycle module never invokes Python; this
file only exists so the REAL google-beta and terracurl providers can be driven
against 127.0.0.1 with FAKE credentials and fictional data in
lifecycle-tests/integration/run_scenarios.py.

Fidelity is deliberately limited and every simplification is an assumption,
not knowledge of Google behaviour:
  * services: create/get/full PATCH (provider) and masked PATCH (updateMask,
    terracurl); a template change creates a revision that becomes Ready or
    fails per control; scaling/traffic/annotations stored as sent;
    proto3-style omission of zero ints in scaling.
  * jobs: create with runExecutionToken starts one execution whose outcome is
    set by control: success, LRO error ("shape 1") or LRO done.response with a
    FAILED terminal condition ("shape 2"), or an LRO error while the execution
    keeps running ("lro_error_active"); delete removes executions.
  * executions: GET .../jobs/-/executions (all jobs of the region) and
    .../jobs/<job>/executions; settled = completionTime set and runningCount 0.
    Extra executions (legacy fleet-migration, orphan prior identities,
    unrelated jobs) are injected via /_inject. Control "executions_list_mode"
    can return a truncated page, a malformed 200 body or a 403.
  * desired vs observed control plane: a restore PATCH (masked, touches
    annotations) always stores the desired fields and bumps generation; per
    control "restore_settle_outcomes" the observed side may lag
    (observedGeneration held back, reconciling, or Ready FAILED) until
    /_inject settle_service or the next provider PATCH.
  * image reporting: control "image_report" (as_sent | alias | absent)
    rewrites/omits template.containers[].image in masked (`fields`) service
    GETs, i.e. what the lifecycle module's own REST reads would see if they
    asked for it. The provider's own reads are unaffected.
  * operations: get, :wait; `fields` partial responses (subset grammar
    a,b(c,d),e/f).
  * Authorization must be exactly "Bearer <FAKE_TOKEN>"; anything else 401.

Control endpoints (test harness only): POST /_control (merge JSON),
GET /_events, GET /_state, POST /_inject {"action": ...}.
"""
import argparse
import copy
import json
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOCK = threading.RLock()
STATE = {
    "services": {},
    "jobs": {},
    "executions": {},
    "operations": {},
    "revisions": {},
    "seq": 0,
}
EVENTS = []
CONTROL = {
    # job outcomes consumed in order, then default
    "job_outcomes": [],
    "job_default": "success",          # success | lro_error | terminal_failed | lro_error_reconciling
    "exec_polls": 1,                   # operation polls before a job execution finishes
    "rollout_outcomes": [],            # per new revision: ready | lro_error | response_failed
    "rollout_default": "ready",
    "ignore_traffic_in_masked_patch": False,
    "fail_next_masked_patch_status": 0,
    # per masked PATCH that touches annotations (= restore): "ok" | "op_error"
    # ("op_error": HTTP 200 with an LRO already done=true + error, nothing applied)
    "restore_patch_outcomes": [],
    # per APPLIED restore PATCH: "settled" | "lag_success" (desired stored,
    # Ready SUCCEEDED, observedGeneration held back) | "pending" (also
    # reconciling, Ready RECONCILING, LRO not done) | "cp_failed" (observed,
    # Ready FAILED)
    "restore_settle_outcomes": [],
    "executions_list_mode": "ok",      # ok | truncated | malformed | forbidden
    "image_report": "as_sent",         # as_sent | alias | absent (masked service GETs only)
}
IMAGE_ALIAS = "docker.io/fleetdm/fleet@sha256:" + "ab" * 32
FAKE_TOKEN = None


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())


def next_seq():
    STATE["seq"] += 1
    return STATE["seq"]


def svc_snapshot(name):
    s = STATE["services"].get(name)
    if not s:
        return None
    return {
        "scaling": copy.deepcopy(s.get("scaling", {})),
        "traffic_tags": [t.get("tag") for t in s.get("traffic", []) if t.get("tag")],
        "latestReadyRevision": s.get("latestReadyRevision"),
        "image": s.get("template", {}).get("containers", [{}])[0].get("image"),
        "annotations": copy.deepcopy(s.get("annotations", {})),
        "generation": s.get("generation"),
        "observedGeneration": s.get("observedGeneration"),
        "reconciling": s.get("reconciling"),
        "ready": (s.get("terminalCondition") or {}).get("state"),
    }


def event(kind, **details):
    svc_names = list(STATE["services"].keys())
    snap = {n: svc_snapshot(n) for n in svc_names}
    EVENTS.append({"seq": next_seq(), "t": time.time(), "kind": kind, "details": details, "services": snap})


# ---------------------------------------------------------------- fields mask
def parse_fields(spec):
    """Parse a Google partial-response mask into a tree {key: subtree|True}."""
    pos = 0

    def parse_list():
        nonlocal pos
        tree = {}
        while pos < len(spec):
            m = re.match(r"[A-Za-z0-9_*/]+", spec[pos:])
            if not m:
                raise ValueError("bad fields mask at %d: %r" % (pos, spec))
            path = m.group(0).split("/")
            pos += len(m.group(0))
            sub = True
            if pos < len(spec) and spec[pos] == "(":
                pos += 1
                sub = parse_list()
                if pos >= len(spec) or spec[pos] != ")":
                    raise ValueError("unbalanced fields mask")
                pos += 1
            node = tree
            for p in path[:-1]:
                node = node.setdefault(p, {})
                if node is True:
                    break
            if node is not True:
                node[path[-1]] = sub
            if pos < len(spec) and spec[pos] == ",":
                pos += 1
                continue
            break
        return tree

    tree = parse_list()
    if pos != len(spec):
        raise ValueError("trailing characters in fields mask: %r" % spec[pos:])
    return tree


def apply_fields(obj, tree):
    if tree is True:
        return obj
    if isinstance(obj, list):
        return [apply_fields(o, tree) for o in obj]
    if not isinstance(obj, dict):
        return obj
    out = {}
    for k, sub in tree.items():
        if k == "*":
            for kk, vv in obj.items():
                out[kk] = apply_fields(vv, sub)
        elif k in obj:
            out[k] = apply_fields(obj[k], sub)
    return out


# ---------------------------------------------------------------- helpers
def proto3_scaling(sc):
    sc = {k: v for k, v in (sc or {}).items() if v not in (0, "0", None)}
    for k in ("minInstanceCount", "manualInstanceCount"):
        if k in sc:
            sc[k] = int(sc[k])
    return sc


def new_operation(parent, kind, target, done, response=None, error=None, pending=None):
    op_id = str(uuid.uuid4())
    name = "%s/operations/%s" % (parent, op_id)
    op = {"name": name, "metadata": {"@type": "type.googleapis.com/google.cloud.run.v2.%s" % kind, "name": target},
          "done": done}
    if done:
        if error:
            op["error"] = error
        else:
            op["response"] = response
    STATE["operations"][name] = {"op": op, "pending": pending}
    return op


def finish_pending(entry):
    """Advance a pending job-execution operation; returns the op."""
    p = entry["pending"]
    op = entry["op"]
    if op["done"] or not p:
        return op
    p["polls"] -= 1
    if p["polls"] > 0:
        return op
    job = STATE["jobs"].get(p["job"])
    ex = STATE["executions"].get(p["execution"])
    outcome = p["outcome"]
    t = now()
    if ex and outcome != "lro_error_active":
        complete_execution(ex, outcome == "success")
    if job:
        state = {"success": "CONDITION_SUCCEEDED", "lro_error": "CONDITION_FAILED",
                 "terminal_failed": "CONDITION_FAILED", "lro_error_reconciling": "CONDITION_RECONCILING",
                 "lro_error_active": "CONDITION_RECONCILING"}[outcome]
        job["terminalCondition"] = {"type": "Ready", "state": state,
                                    "reason": "" if outcome == "success" else "fake-prepare-db-exit-1",
                                    "message": "" if outcome == "success" else "fake: fleet prepare db exited 1",
                                    "lastTransitionTime": t}
        job["reconciling"] = False
        if outcome != "lro_error_active":
            job["latestCreatedExecution"]["completionTime"] = t
    if outcome == "lro_error_active":
        event("execution_lro_error_still_running", job=p["job"], execution=p["execution"])
    else:
        event("execution_finished", job=p["job"], execution=p["execution"], outcome=outcome)
    op["done"] = True
    if outcome in ("lro_error", "lro_error_reconciling", "lro_error_active"):
        op["error"] = {"code": 9, "message": "fake: execution %s failed" % p["execution"]}
    else:
        op["response"] = copy.deepcopy(job)
    return op


def new_execution(job_full, exec_short, job_field="short", active=True, running_count=None):
    """Execution object as listed by the API (subset). job_field: short | full | absent."""
    name = "%s/executions/%s" % (job_full, exec_short)
    ex = {"name": name, "createTime": now(), "startTime": now(), "reconciling": active,
          "conditions": [{"type": "Completed", "state": "CONDITION_RECONCILING" if active else "CONDITION_SUCCEEDED"}],
          "_job_full": job_full}
    if job_field == "short":
        ex["job"] = job_full.split("/")[-1]
    elif job_field == "full":
        ex["job"] = job_full
    if active:
        ex["runningCount"] = 1 if running_count is None else running_count
    else:
        ex["completionTime"] = now()
        if running_count:
            ex["runningCount"] = running_count
    STATE["executions"][name] = ex
    return ex


def complete_execution(ex, ok=True):
    ex["completionTime"] = now()
    ex.pop("runningCount", None)  # proto3: zero omitted
    ex["reconciling"] = False
    ex["succeededCount"] = 1 if ok else 0
    ex["failedCount"] = 0 if ok else 1
    ex["conditions"] = [{"type": "Completed", "state": "CONDITION_SUCCEEDED" if ok else "CONDITION_FAILED"}]


def settle_service(svc):
    """Observed side catches up with the desired spec."""
    held = svc.pop("_held", None)
    svc["observedGeneration"] = svc["generation"]
    svc["reconciling"] = False
    if held in ("lag_success", "pending"):
        svc["terminalCondition"] = {"type": "Ready", "state": "CONDITION_SUCCEEDED", "lastTransitionTime": now()}
    return held


def deploy_revision(svc):
    """Create a revision for the current template; returns (ok, shape)."""
    outcome = CONTROL["rollout_outcomes"].pop(0) if CONTROL["rollout_outcomes"] else CONTROL["rollout_default"]
    n = len([r for r in STATE["revisions"] if r.startswith(svc["_short"] + "-")]) + 1
    rev = "%s-%05d-fak" % (svc["_short"], n)
    STATE["revisions"][rev] = {"image": svc["template"]["containers"][0].get("image"), "ready": outcome == "ready",
                               "annotations": copy.deepcopy(svc["template"].get("annotations", {}))}
    svc["latestCreatedRevision"] = svc["_parent"] + "/revisions/" + rev
    if outcome == "ready":
        svc["latestReadyRevision"] = svc["latestCreatedRevision"]
        svc["terminalCondition"] = {"type": "Ready", "state": "CONDITION_SUCCEEDED", "lastTransitionTime": now()}
    else:
        svc["terminalCondition"] = {"type": "Ready", "state": "CONDITION_FAILED", "reason": "fake-revision-failed",
                                    "message": "fake: revision %s failed startup probe" % rev,
                                    "lastTransitionTime": now()}
    event("revision_created", service=svc["name"], revision=rev, outcome=outcome,
          image=STATE["revisions"][rev]["image"],
          scaling=copy.deepcopy(svc.get("scaling")))
    return outcome


def recompute_traffic_status(svc):
    svc["trafficStatuses"] = [dict({"percent": t.get("percent", 0), "type": t.get("type")},
                                   **({"tag": t["tag"], "uri": "https://%s---fake.invalid" % t["tag"]} if t.get("tag") else {}),
                                   **({"revision": t["revision"]} if t.get("revision") else {}))
                              for t in svc.get("traffic", [])]


SPEC_FIELDS = ("labels", "annotations", "client", "clientVersion", "ingress", "launchStage", "description",
               "binaryAuthorization", "template", "traffic", "scaling", "customAudiences", "defaultUriDisabled",
               "invokerIamDisabled", "buildConfig", "iapEnabled")


def public(obj):
    return {k: v for k, v in obj.items() if not k.startswith("_")}


# ---------------------------------------------------------------- handler
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[fake] %s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _err(self, code, status, msg):
        self._send(code, {"error": {"code": code, "status": status, "message": msg}})

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else {}

    def _respond(self, code, obj, qs):
        if "fields" in qs:
            try:
                obj = apply_fields(obj, parse_fields(qs["fields"][0]))
            except ValueError as e:
                return self._err(400, "INVALID_ARGUMENT", str(e))
        self._send(code, obj)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        u = urlsplit(self.path)
        qs = parse_qs(u.query)
        path = u.path
        with LOCK:
            if path.startswith("/_"):
                return self.control(method, path)
            auth = self.headers.get("Authorization", "")
            ua = self.headers.get("User-Agent", "")
            client = "terracurl" if "Go-http-client" in ua and "Terraform" not in ua else "google-beta"
            EVENTS.append({"seq": next_seq(), "t": time.time(), "kind": "http", "details": {
                "method": method, "path": path, "query": u.query, "client": client,
                "auth_ok": auth == "Bearer " + FAKE_TOKEN}})
            if auth != "Bearer " + FAKE_TOKEN:
                return self._err(401, "UNAUTHENTICATED", "fake: bad or missing bearer token")
            if not path.startswith("/v2/"):
                return self._err(404, "NOT_FOUND", "fake: unknown path")
            rest = path[len("/v2/"):]
            mx = re.fullmatch(r"(projects/[^/]+/locations/[^/]+)/jobs/([^/]+)/executions", rest)
            if mx:
                return self.list_executions(method, mx.group(1), mx.group(2), qs)
            m = re.fullmatch(r"(projects/[^/]+/locations/[^/]+)/(services|jobs|operations)(?:/([^/:]+))?(:wait)?", rest)
            if not m:
                return self._err(404, "NOT_FOUND", "fake: unsupported path " + rest)
            parent, coll, name, wait = m.groups()
            try:
                if coll == "services":
                    return self.services(method, parent, name, qs)
                if coll == "jobs":
                    return self.jobs(method, parent, name, qs)
                return self.operations(method, parent, name, wait, qs)
            except Exception as e:  # pragma: no cover - surfaced to the test log
                import traceback
                traceback.print_exc()
                return self._err(500, "INTERNAL", "fake: %r" % e)

    # ------------------------------------------------------------ services
    def services(self, method, parent, short, qs):
        full = "%s/services/%s" % (parent, short) if short else None
        svcs = STATE["services"]
        if method == "POST" and not short:
            sid = qs.get("serviceId", [""])[0]
            full = "%s/services/%s" % (parent, sid)
            if full in svcs:
                return self._err(409, "ALREADY_EXISTS", "fake: service exists")
            body = self._body()
            svc = {k: body[k] for k in SPEC_FIELDS if k in body}
            svc.update({"name": full, "uid": str(uuid.uuid4()), "generation": "1", "createTime": now(),
                        "_short": sid, "_parent": parent, "launchStage": body.get("launchStage", "GA"),
                        "uri": "https://%s-fake.a.run.app.invalid" % sid, "reconciling": False})
            svc["scaling"] = proto3_scaling(svc.get("scaling"))
            if not svc.get("traffic"):
                svc["traffic"] = [{"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", "percent": 100}]
            svcs[full] = svc
            event("service_created", service=full, scaling=copy.deepcopy(svc["scaling"]),
                  image=svc["template"]["containers"][0].get("image"))
            outcome = deploy_revision(svc)
            svc["observedGeneration"] = svc["generation"]
            recompute_traffic_status(svc)
            svc["etag"] = '"%s"' % uuid.uuid4()
            return self._service_op(parent, svc, outcome, qs)
        if not short:
            return self._err(400, "INVALID_ARGUMENT", "fake: list not supported")
        svc = svcs.get(full)
        if method == "GET":
            if not svc:
                return self._err(404, "NOT_FOUND", "fake: service not found")
            obj = public(svc)
            if "fields" in qs:
                if "image" in qs["fields"][0]:
                    event("UNEXPECTED_image_in_fields_mask", fields=qs["fields"][0])
                mode = CONTROL["image_report"]
                if mode != "as_sent":
                    obj = copy.deepcopy(obj)
                    for c in obj.get("template", {}).get("containers", []):
                        if mode == "alias":
                            c["image"] = IMAGE_ALIAS
                        else:
                            c.pop("image", None)
            return self._respond(200, obj, qs)
        if method == "DELETE":
            if not svc:
                return self._err(404, "NOT_FOUND", "fake: service not found")
            del svcs[full]
            event("service_deleted", service=full)
            op = new_operation(parent, "Service", full, True, response=public(svc))
            return self._respond(200, op, qs)
        if method == "PATCH":
            body = self._body()
            if not svc:
                event("service_patch_not_found", service=full, status=404, service_exists=False,
                      mask=qs.get("updateMask", [""])[0])
                return self._err(404, "NOT_FOUND", "fake: service not found")
            mask = qs.get("updateMask", [None])[0]
            gen = int(svc["generation"]) + 1
            if mask:
                if CONTROL["fail_next_masked_patch_status"]:
                    code = CONTROL["fail_next_masked_patch_status"]
                    CONTROL["fail_next_masked_patch_status"] = 0
                    return self._err(code, "PERMISSION_DENIED" if code == 403 else "UNAVAILABLE", "fake: injected")
                fields = [f.strip() for f in mask.split(",") if f.strip()]
                if "annotations" in fields and CONTROL["restore_patch_outcomes"]:
                    if CONTROL["restore_patch_outcomes"].pop(0) == "op_error":
                        event("service_masked_patch_failed_lro", service=full, mask=fields)
                        op = new_operation(parent, "Service", full, True,
                                           error={"code": 13, "message": "fake: restore operation failed"})
                        return self._respond(200, op, qs)
                for f in fields:
                    if f not in ("scaling", "traffic", "annotations"):
                        return self._err(400, "INVALID_ARGUMENT", "fake: mask field %s unsupported" % f)
                    if f == "traffic" and CONTROL["ignore_traffic_in_masked_patch"]:
                        continue
                    if f == "scaling":
                        svc["scaling"] = proto3_scaling(body.get("scaling"))
                    else:
                        svc[f] = copy.deepcopy(body.get(f, [] if f == "traffic" else {}))
                svc["generation"] = str(gen)
                settle = "settled"
                if "annotations" in fields and CONTROL["restore_settle_outcomes"]:
                    settle = CONTROL["restore_settle_outcomes"].pop(0)
                if settle == "settled":
                    svc["observedGeneration"] = str(gen)
                    svc["reconciling"] = False
                    svc.pop("_held", None)
                elif settle == "lag_success":
                    svc["_held"] = settle  # observedGeneration stays at the previous value
                elif settle == "pending":
                    svc["_held"] = settle
                    svc["reconciling"] = True
                    svc["terminalCondition"] = {"type": "Ready", "state": "CONDITION_RECONCILING",
                                                "lastTransitionTime": now()}
                elif settle == "cp_failed":
                    svc["_held"] = settle
                    svc["observedGeneration"] = str(gen)
                    svc["reconciling"] = False
                    svc["terminalCondition"] = {"type": "Ready", "state": "CONDITION_FAILED",
                                                "reason": "fake-scale-up-failed",
                                                "message": "fake: instances could not be started",
                                                "lastTransitionTime": now()}
                else:
                    return self._err(500, "INTERNAL", "fake: bad restore_settle_outcome %r" % settle)
                recompute_traffic_status(svc)
                op = new_operation(parent, "Service", full, False)
                event("service_masked_patch", service=full, mask=fields, scaling=copy.deepcopy(svc["scaling"]),
                      annotations=copy.deepcopy(svc.get("annotations", {})), operation=op["name"], settle=settle,
                      generation=svc["generation"], observedGeneration=svc.get("observedGeneration"))
                # completes on first poll/wait (a "pending" restore only once settled)
                STATE["operations"][op["name"]]["pending"] = {"service_done": public(svc), "service": full}
                return self._respond(200, op, qs)
            # full PATCH from the provider
            old_template = json.dumps(svc.get("template"), sort_keys=True)
            for k in SPEC_FIELDS:
                if k in body:
                    svc[k] = copy.deepcopy(body[k])
                elif k in ("annotations", "labels"):
                    svc[k] = {}
                elif k == "scaling":
                    svc[k] = {}
            svc["scaling"] = proto3_scaling(svc.get("scaling"))
            if not svc.get("traffic"):
                svc["traffic"] = [{"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", "percent": 100}]
            svc["generation"] = str(gen)
            held = settle_service(svc)
            changed = json.dumps(svc.get("template"), sort_keys=True) != old_template
            event("service_full_patch", service=full, template_changed=changed, settled_held=held,
                  scaling=copy.deepcopy(svc["scaling"]), image=svc["template"]["containers"][0].get("image"))
            outcome = deploy_revision(svc) if changed else "ready"
            svc["observedGeneration"] = svc["generation"]
            recompute_traffic_status(svc)
            svc["etag"] = '"%s"' % uuid.uuid4()
            return self._service_op(parent, svc, outcome, qs)
        return self._err(405, "METHOD_NOT_ALLOWED", "fake")

    def _service_op(self, parent, svc, outcome, qs):
        if outcome == "lro_error":
            op = new_operation(parent, "Service", svc["name"], True,
                               error={"code": 9, "message": svc["terminalCondition"].get("message", "fake failure")})
        else:
            op = new_operation(parent, "Service", svc["name"], True, response=public(svc))
        return self._respond(200, op, qs)

    # ------------------------------------------------------------ jobs
    def jobs(self, method, parent, short, qs):
        jobs = STATE["jobs"]
        if method == "POST" and not short:
            jid = qs.get("jobId", [""])[0]
            full = "%s/jobs/%s" % (parent, jid)
            if full in jobs:
                return self._err(409, "ALREADY_EXISTS", "fake: job %s already exists" % jid)
            body = self._body()
            token = body.get("runExecutionToken") or body.get("startExecutionToken")
            exec_name = None
            if token:
                exec_name = "%s/executions/%s-%s" % (full, jid, token)
                if len(jid) + len(token) >= 63:
                    return self._err(400, "INVALID_ARGUMENT", "fake: name+token too long")
                if exec_name in STATE["executions"]:
                    return self._err(409, "ALREADY_EXISTS", "fake: execution exists")
            job = {k: body[k] for k in ("labels", "annotations", "client", "clientVersion", "launchStage",
                                        "binaryAuthorization", "template") if k in body}
            job.update({"name": full, "uid": str(uuid.uuid4()), "generation": "1", "observedGeneration": "1",
                        "createTime": now(), "reconciling": bool(token), "executionCount": 1 if token else 0,
                        "launchStage": body.get("launchStage", "GA"),
                        "terminalCondition": {"type": "Ready", "state": "CONDITION_SUCCEEDED" if not token else "CONDITION_RECONCILING"},
                        "etag": '"%s"' % uuid.uuid4()})
            jobs[full] = job
            event("job_created", job=full, token=token,
                  image=job["template"]["template"]["containers"][0].get("image"))
            if not token:
                op = new_operation(parent, "Job", full, True, response=copy.deepcopy(job))
                return self._respond(200, op, qs)
            outcome = CONTROL["job_outcomes"].pop(0) if CONTROL["job_outcomes"] else CONTROL["job_default"]
            new_execution(full, exec_name.split("/")[-1], job_field="short", active=True)
            job["latestCreatedExecution"] = {"name": exec_name, "createTime": now()}
            event("execution_started", job=full, execution=exec_name, planned_outcome=outcome)
            op = new_operation(parent, "Job", full, False,
                               pending={"job": full, "execution": exec_name, "outcome": outcome,
                                        "polls": CONTROL["exec_polls"]})
            return self._respond(200, op, qs)
        if method == "GET" and not short:
            items = [public(j) for j in sorted(jobs.values(), key=lambda j: j["name"]) if j["name"].startswith(parent + "/")]
            return self._respond(200, {"jobs": items} if items else {}, qs)
        full = "%s/jobs/%s" % (parent, short)
        job = jobs.get(full)
        if not job:
            return self._err(404, "NOT_FOUND", "fake: job not found")
        if method == "GET":
            return self._respond(200, public(job), qs)
        if method == "DELETE":
            del jobs[full]
            running = [e for e in STATE["executions"] if e.startswith(full + "/")]
            for e in running:
                del STATE["executions"][e]
            event("job_deleted", job=full, executions_removed=running)
            op = new_operation(parent, "Job", full, True, response=public(job))
            return self._respond(200, op, qs)
        if method == "PATCH":
            body = self._body()
            event("job_updated_UNEXPECTED", job=full, token=body.get("runExecutionToken"))
            op = new_operation(parent, "Job", full, True, response=public(job))
            return self._respond(200, op, qs)
        return self._err(405, "METHOD_NOT_ALLOWED", "fake")

    # ------------------------------------------------------------ executions
    def list_executions(self, method, parent, job, qs):
        if method != "GET":
            return self._err(405, "METHOD_NOT_ALLOWED", "fake")
        if "-" in parent.split("/"):
            return self._err(400, "INVALID_ARGUMENT", "fake: region wildcard not allowed")
        mode = CONTROL["executions_list_mode"]
        if mode == "forbidden":
            return self._err(403, "PERMISSION_DENIED", "fake: run.executions.list denied")
        if mode == "malformed":
            data = b"<html>fake: not json</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return None
        prefix = parent + "/jobs/" + ("" if job == "-" else job + "/")
        items = [public(e) for e in sorted(STATE["executions"].values(), key=lambda e: e["name"])
                 if e["_job_full"].startswith(parent + "/jobs/") and (job == "-" or e["_job_full"] == parent + "/jobs/" + job)
                 and e["name"].startswith(prefix)]
        body = {"executions": items} if items else {}
        if mode == "truncated":
            body["nextPageToken"] = "fake-next-page"
        event("executions_listed", job=job, n=len(items), mode=mode)
        return self._respond(200, body, qs)

    # ------------------------------------------------------------ operations
    def operations(self, method, parent, op_id, wait, qs):
        name = "%s/operations/%s" % (parent, op_id)
        entry = STATE["operations"].get(name)
        if not entry:
            return self._err(404, "NOT_FOUND", "fake: operation not found")
        p = entry["pending"]
        if p and "service_done" in p and not entry["op"]["done"]:
            held = STATE["services"].get(p.get("service"), {}).get("_held")
            if held != "pending":
                entry["op"]["done"] = True
                entry["op"]["response"] = p["service_done"]
        elif p and "job" in p:
            if wait:
                p["polls"] = 1
            finish_pending(entry)
        if wait:
            event("operation_wait", operation=name, done=entry["op"]["done"])
        return self._respond(200, entry["op"], qs)

    # ------------------------------------------------------------ control
    def control(self, method, path):
        if path == "/_events" and method == "GET":
            return self._send(200, EVENTS)
        if path == "/_state" and method == "GET":
            return self._send(200, {"services": STATE["services"], "jobs": STATE["jobs"],
                                    "executions": STATE["executions"], "revisions": STATE["revisions"],
                                    "control": CONTROL})
        if path == "/_control" and method == "POST":
            CONTROL.update(self._body())
            event("control", control=copy.deepcopy(CONTROL))
            return self._send(200, CONTROL)
        if path == "/_inject" and method == "POST":
            b = self._body()
            act = b.get("action")
            if act == "add_traffic_tag":
                svc = STATE["services"][b["service"]]
                rev = svc["latestReadyRevision"].split("/")[-1]
                svc["traffic"].append({"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": rev,
                                       "tag": b.get("tag", "canary"), "percent": 0})
                recompute_traffic_status(svc)
            elif act == "delete_job":
                STATE["jobs"].pop(b["job"], None)
            elif act == "finish_executions":
                for entry in STATE["operations"].values():
                    if entry["pending"] and "job" in entry["pending"] and not entry["op"]["done"]:
                        entry["pending"]["polls"] = 1
                        finish_pending(entry)
            elif act == "set_scaling":
                STATE["services"][b["service"]]["scaling"] = proto3_scaling(b["scaling"])
            elif act == "add_execution":
                # b: parent, job, execution, active, job_field, running_count, create_job
                job_full = "%s/jobs/%s" % (b["parent"], b["job"])
                if b.get("create_job") and job_full not in STATE["jobs"]:
                    STATE["jobs"][job_full] = {"name": job_full, "uid": str(uuid.uuid4()), "generation": "1",
                                               "labels": b.get("labels", {}), "reconciling": False,
                                               "terminalCondition": {"type": "Ready", "state": "CONDITION_SUCCEEDED"}}
                new_execution(job_full, b["execution"], job_field=b.get("job_field", "short"),
                              active=b.get("active", True), running_count=b.get("running_count"))
            elif act == "complete_execution":
                for n, ex in STATE["executions"].items():
                    active = "completionTime" not in ex or ex.get("runningCount")
                    if (b.get("all") and active) or n.endswith("/executions/" + b.get("execution", "\0")):
                        complete_execution(ex, True)
            elif act == "settle_service":
                settle_service(STATE["services"][b["service"]])
            else:
                return self._send(400, {"error": "unknown action"})
            event("inject", **b)
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "unknown control path"})


def main():
    global FAKE_TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token", required=True)
    a = ap.parse_args()
    if not a.token.startswith("fake-"):
        sys.exit("refusing: token must start with 'fake-'")
    FAKE_TOKEN = a.token
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    sys.stderr.write("[fake] listening on 127.0.0.1:%d\n" % a.port)
    srv.serve_forever()


if __name__ == "__main__":
    main()
