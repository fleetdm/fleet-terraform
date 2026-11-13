#!/usr/bin/env python3
"""TEST-ONLY integration runner for the provider-only lifecycle module.

Drives REAL terraform + REAL google-beta/terracurl/time providers against the
loopback fake (fake_cloud_run.py). Not part of any apply path.

Safety (asserted before any apply):
  * every GOOGLE_* / CLOUDSDK_* / GCLOUD* variable is removed from the child
    environment; the only credential is a literal token starting with "fake-";
  * the Cloud Run endpoint and the terracurl base URL are http://127.0.0.1:<port>;
  * HTTP(S)_PROXY point at a dead loopback port (127.0.0.1:9) with
    NO_PROXY=127.0.0.1, so any accidental non-loopback request fails.
  * terraform init runs separately (public registry download only).

Usage:
  python3 -I run_scenarios.py --provider-version 7.24.0 [--terraform terraform] [--only s1,s2]
  python3 -I run_scenarios.py --provider-version 7.24.0 \
      --upgrade-from-ref <git-ref> --upgrade-from-provider-version 6.50.0
The second form runs only the upgrade scenario (U1): the fixture and
fleet-lifecycle module from <git-ref> (read with `git show`, never checked out)
are applied with the older google-beta, then the current fixture and module are
initialised with --provider-version against the same state and fake API.
The previous module had no /tmp volume, so U1 expects exactly one in-place
service update (the default disk-backed /tmp volume and mount, plus the
settlement check every service update re-arms) and nothing else; with
tmp_volume_config.enable = false it expects no change at all.
Artifacts: lifecycle-tests/integration/artifacts/<run-id>/ (logs, events, results.json, SUMMARY.md)
"""
import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
FIXTURE_REL = "lifecycle-tests/integration/fixture/main.tf"
MODULE_REL = "gcp/byo-project/modules/fleet-lifecycle"
TOKEN = "fake-loopback-token-not-a-credential"
PARENT = "projects/fictional-proj/locations/us-central1"
SVC = PARENT + "/services/fleet-api"
MOD = "module.lifecycle"
SVC_ADDR = MOD + ".google_cloud_run_v2_service.fleet"
# replace_triggered_by the service (restore_settlement.tf): every service update
# re-arms the read-only settlement check (probe; the wait is skipped if settled).
SETTLE_ADDR = MOD + ".time_sleep.restore_settle[0]"
# Disk-backed /tmp as the real google-beta provider sends it (Run v2 JSON).
TMP_VOLUME_NAME = "tmp"
OPT_OUT = ("-var", "tmp_volume_config={enable=false}")
# The only service paths the default /tmp may change on an upgraded service.
TMP_PLAN_PATHS = {("template", 0, "volumes"), ("template", 0, "containers", 0, "volume_mounts")}


def root_neg_service_refs():
    """`cloud_run { service = ... }` of the root's global and regional NEGs,
    with the root's module name mapped to the fixture's."""
    root = os.path.normpath(os.path.join(HERE, "..", "..", "gcp", "byo-project"))
    refs = []
    for f, name in (("cloud_run.tf", "neg"), ("loadbalancer-regional.tf", "regional_neg")):
        m = re.search(r'"google_compute_region_network_endpoint_group"\s+"%s"\s*\{.*?cloud_run\s*\{\s*service\s*=\s*([^\n#]+)' % name,
                      open(os.path.join(root, f)).read(), re.S)
        assert m, "NEG %s not found in %s" % (name, f)
        refs.append(m.group(1).strip().replace("module.fleet_lifecycle.", "module.lifecycle."))
    return refs


def extract_from_git(ref, paths, dest):
    """Write the files under `paths` as of `ref` to dest (read-only git plumbing;
    the working tree, index and HEAD are not touched)."""
    names = subprocess.run(["git", "-C", REPO, "ls-tree", "-r", "--name-only", ref, "--"] + paths,
                           capture_output=True, text=True, check=True).stdout.split()
    for p in paths:
        assert any(n == p or n.startswith(p + "/") for n in names), "%s not found at %s" % (p, ref)
    for n in names:
        out = os.path.join(dest, n)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f:
            f.write(subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (ref, n)],
                                   capture_output=True, check=True).stdout)
    return dest


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Runner:
    def __init__(self, args):
        self.args = args
        self.tf_bin = args.terraform
        rid = time.strftime("%Y%m%d-%H%M%S") + "-tf" + self.tf_version().replace(".", "_") + "-gb" + args.provider_version.replace(".", "_")
        if args.upgrade_from_ref:
            rid += "-from-gb" + args.upgrade_from_provider_version.replace(".", "_")
        self.art = os.path.join(HERE, "artifacts", rid)
        self.work = os.path.join(self.art, "work")
        os.makedirs(self.work)
        # the fixture's NEG stand-in takes the root's actual NEG expressions
        self.neg_refs = root_neg_service_refs()
        if args.upgrade_from_ref:
            # U1 starts from the previous fixture and module (extracted from git)
            old = extract_from_git(args.upgrade_from_ref, [FIXTURE_REL, MODULE_REL], os.path.join(self.art, "from"))
            self.write_config(open(os.path.join(old, FIXTURE_REL)).read(), os.path.join(old, MODULE_REL),
                              args.upgrade_from_provider_version)
        else:
            self.write_current_config()
        self.port = free_port()
        self.step = 0
        self.results = []
        self.fake = None

    def write_config(self, fixture_src, mod_abs, provider_version):
        # the fixture's module source is relative to fixture/; rewrite for work/
        rel = '"../../../%s"' % MODULE_REL
        assert rel in fixture_src, "fixture module source missing"
        src = fixture_src.replace(rel, json.dumps(os.path.normpath(mod_abs)))
        ph = "[local.fleet_service_name, local.fleet_service_name] # ROOT_NEG_SERVICE_REFS"
        assert ph in src, "fixture NEG placeholder missing"
        src = src.replace(ph, "[%s]" % ", ".join(self.neg_refs))
        open(os.path.join(self.work, "main.tf"), "w").write(src)
        with open(os.path.join(self.work, "providers_pin.tf"), "w") as f:
            f.write('terraform {\n  required_providers {\n'
                    '    google-beta = { source = "hashicorp/google-beta", version = "%s" }\n'
                    '    terracurl   = { source = "devops-rob/terracurl", version = "1.2.2" }\n'
                    '    time        = { source = "hashicorp/time", version = "0.14.2" }\n'
                    '  }\n}\n' % provider_version)

    def write_current_config(self):
        self.write_config(open(os.path.join(REPO, FIXTURE_REL)).read(), os.path.join(REPO, MODULE_REL),
                          self.args.provider_version)

    def tf_version(self):
        out = subprocess.run([self.args.terraform, "version", "-json"], capture_output=True, text=True).stdout
        return json.loads(out)["terraform_version"]

    # ---------------------------------------------------------------- env
    def child_env(self, offline=True):
        env = {k: v for k, v in os.environ.items()
               if not (k.startswith("GOOGLE_") or k.startswith("CLOUDSDK_") or k.startswith("GCLOUD"))}
        # No shared plugin cache (see lifecycle-tests/terraformrc-nocache).
        env["TF_CLI_CONFIG_FILE"] = os.path.normpath(os.path.join(HERE, "..", "terraformrc-nocache"))
        env.pop("TF_PLUGIN_CACHE_DIR", None)
        env.update({"CHECKPOINT_DISABLE": "1", "TF_IN_AUTOMATION": "1", "TF_INPUT": "0",
                    "TF_VAR_fake_port": str(self.port), "TF_VAR_fake_token": TOKEN})
        env.pop("TF_LOG", None)
        if offline:
            env.update({"HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9",
                        "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9",
                        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"})
        return env

    def safety_assertions(self):
        env = self.child_env()
        bad = [k for k in env if k.startswith(("GOOGLE_", "CLOUDSDK_", "GCLOUD"))]
        assert not bad, bad
        assert TOKEN.startswith("fake-")
        src = open(os.path.join(self.work, "main.tf")).read()
        assert 'cloud_run_v2_custom_endpoint = "${local.endpoint}/"' in src
        assert 'endpoint = "http://127.0.0.1:${var.fake_port}/v2"' in src
        assert "credentials" not in src.replace("FAKE credentials", "")
        self.log("SAFETY OK: no GOOGLE_/CLOUDSDK_ vars, fake token, loopback endpoints, dead proxy for non-loopback")
        self.log("root NEG service refs (fixture edge): %s" % self.neg_refs)

    # ---------------------------------------------------------------- fake
    def start_fake(self):
        logf = open(os.path.join(self.art, "fake_server.log"), "w")
        self.fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_cloud_run.py"),
                                      "--port", str(self.port), "--token", TOKEN],
                                     stdout=logf, stderr=subprocess.STDOUT)
        for _ in range(50):
            try:
                self.get("/_events")
                return
            except Exception:
                time.sleep(0.1)
        raise RuntimeError("fake did not start")

    def stop_fake(self):
        if self.fake and self.fake.poll() is None:
            self.fake.terminate()
            self.fake.wait(5)

    def get(self, path):
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (self.port, path), timeout=5) as r:
            return json.loads(r.read())

    def post(self, path, body):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), data=json.dumps(body).encode(),
                                     method="POST", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def control(self, **kw):
        return self.post("/_control", kw)

    def inject(self, **kw):
        return self.post("/_inject", kw)

    def seq(self):
        ev = self.get("/_events")
        return ev[-1]["seq"] if ev else 0

    def events_since(self, s):
        return [e for e in self.get("/_events") if e["seq"] > s]

    # ---------------------------------------------------------------- tf
    def log(self, msg):
        print(msg, flush=True)
        with open(os.path.join(self.art, "runner.log"), "a") as f:
            f.write(msg + "\n")

    def tf(self, name, *args, offline=True, background=False):
        self.step += 1
        logp = os.path.join(self.art, "%02d-%s.log" % (self.step, name))
        cmd = [self.tf_bin] + list(args)
        self.log("$ terraform %s   (log: %s)" % (" ".join(args), os.path.basename(logp)))
        f = open(logp, "w")
        # own process group, so a simulated hard kill can also kill the
        # provider plugins (otherwise they are orphaned to PID 1)
        p = subprocess.Popen(cmd, cwd=self.work, env=self.child_env(offline), stdout=f, stderr=subprocess.STDOUT,
                             start_new_session=True)
        if background:
            return p, logp
        rc = p.wait()
        f.close()
        out = open(logp).read()
        self.log("  rc=%d" % rc)
        return rc, out

    def apply(self, name, *extra):
        return self.tf(name, "apply", "-auto-approve", "-no-color", *extra)

    def plan_exit(self, name, *extra):
        rc, out = self.tf(name, "plan", "-detailed-exitcode", "-no-color", *extra)
        return rc, out

    def state_show(self, addr):
        rc, out = self.tf("state-show", "state", "show", "-no-color", addr)
        return out if rc == 0 else ""

    def outputs(self):
        rc, out = self.tf("output", "output", "-json")
        try:
            return {k: v["value"] for k, v in json.loads(out).items()}
        except Exception:
            return {}

    # ---------------------------------------------------------------- checks
    def check(self, scenario, name, cond, detail=""):
        self.results.append({"scenario": scenario, "check": name, "pass": bool(cond), "detail": detail})
        self.log("  [%s] %s: %s %s" % ("PASS" if cond else "FAIL", scenario, name, detail if not cond else ""))
        return cond

    def save_events(self, name, evs):
        with open(os.path.join(self.art, "%02d-%s.events.json" % (self.step, name)), "w") as f:
            json.dump(evs, f, indent=1)


# -------------------------------------------------------------------- helpers
def writes(evs):
    return [e for e in evs if e["kind"] == "http" and e["details"]["method"] in ("POST", "PATCH", "DELETE")]


def idx(evs, pred):
    for i, e in enumerate(evs):
        if pred(e):
            return i
    return None


def k(kind, **match):
    def p(e):
        if e["kind"] != kind:
            return False
        return all(e["details"].get(a) == b for a, b in match.items())
    return p


def masked(mode):
    return lambda e: e["kind"] == "service_masked_patch" and e["details"]["scaling"].get("scalingMode") == mode


def ordered(evs, *preds):
    pos = [idx(evs, p) for p in preds]
    return all(x is not None for x in pos) and pos == sorted(pos), pos


def svc_at(e):
    return (e.get("services") or {}).get(SVC)


# -------------------------------------------------------------------- scenarios
def migration_flow_checks(r, sc, evs, image, existing=True):
    ok, pos = ordered(evs,
                      masked("MANUAL") if existing else (lambda e: e["kind"] == "http" and e["details"]["method"] == "PATCH" and parse_qs(e["details"]["query"]).get("updateMask") == ["scaling,traffic"]),
                      k("job_created"), k("execution_started"), k("execution_finished", outcome="success"),
                      lambda e: e["kind"] in ("service_full_patch", "service_created"),
                      k("revision_created", outcome="ready"), masked("AUTOMATIC"))
    r.check(sc, "order stop<job<exec ok<service deploy<ready revision<restore", ok, "positions=%s" % pos)
    ex = [e for e in evs if e["kind"] == "execution_started"]
    r.check(sc, "exactly one execution started", len(ex) == 1, "n=%d" % len(ex))
    if ex:
        s = svc_at(ex[0])
        if existing:
            r.check(sc, "service MANUAL/0 and untagged while migration ran",
                    s and s["scaling"].get("scalingMode") == "MANUAL" and not s["scaling"].get("manualInstanceCount")
                    and not s["scaling"].get("minInstanceCount") and not s["traffic_tags"], json.dumps(s))
        else:
            r.check(sc, "service absent while migration ran", s is None, json.dumps(s))
    dep = [e for e in evs if e["kind"] in ("service_full_patch", "service_created")]
    r.check(sc, "target template deployed while MANUAL (staged)", dep and dep[0]["details"]["scaling"].get("scalingMode") == "MANUAL"
            and dep[0]["details"]["image"] == image, json.dumps(dep[0]["details"] if dep else None))
    rs = [e for e in evs if masked("AUTOMATIC")(e)]
    r.check(sc, "restore wrote AUTOMATIC/min=1 + marker", rs and rs[-1]["details"]["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1}
            and "fleetdm.com/lifecycle-restored" in rs[-1]["details"]["annotations"], json.dumps(rs[-1]["details"] if rs else None))
    tc = [e for e in evs if e["kind"] == "http" and e["details"]["client"] == "terracurl"]
    r.check(sc, "all terracurl requests carry the provider token and a fields mask",
            all(e["details"]["auth_ok"] and "fields=" in e["details"]["query"] for e in tc), "n=%d" % len(tc))
    r.check(sc, "no lifecycle REST read asks for the container image (image contract)",
            not any("image" in parse_qs(e["details"]["query"]).get("fields", [""])[0] for e in tc)
            and not any(e["kind"] == "UNEXPECTED_image_in_fields_mask" for e in evs))
    ok_ex, pos_ex = ordered(evs, k("execution_finished", outcome="success"), job_outcome_read,
                            lambda e: e["kind"] in ("service_full_patch", "service_created"))
    r.check(sc, "execution outcome read (GET job, completionStatus) after the job and before the deploy", ok_ex, "pos=%s" % pos_ex)
    r.check(sc, "no unexpected job PATCH", not any(e["kind"] == "job_updated_UNEXPECTED" for e in evs))


def job_outcome_read(e):
    d = e["details"]
    return (e["kind"] == "http" and d["method"] == "GET" and d["client"] == "terracurl" and "/jobs/" in d["path"]
            and "completionStatus" in parse_qs(d["query"]).get("fields", [""])[0])


def stop_wait_checks(r, sc, evs):
    """operations.wait must target THE stop's operation, after the stop and before the job."""
    stops = [e for e in evs if masked("MANUAL")(e)]
    jc = idx(evs, k("job_created"))
    if not stops or jc is None:
        return r.check(sc, "stop operation waited on (bound to the stop LRO, before the job)", False, "no stop or no job")
    op = stops[-1]["details"]["operation"]
    si = evs.index(stops[-1])
    wi = idx(evs, lambda e: e["kind"] == "operation_wait" and e["details"]["operation"] == op)
    r.check(sc, "stop operation waited on (bound to the stop LRO, before the job)",
            wi is not None and si < wi < jc, "stop=%d wait=%s job=%d op=%s" % (si, wi, jc, op))


def planned_changes(r, label, *extra):
    """(plan rc, {address: actions} without no-op/read, resource_changes)."""
    rc, _ = r.tf("%s-plan" % label, "plan", "-no-color", "-out=%s.tfplan" % label, *extra)
    rcj, js = r.tf("%s-plan-show" % label, "show", "-json", "%s.tfplan" % label)
    try:
        changes = json.loads(js).get("resource_changes", [])
        acts = {c["address"]: c["change"]["actions"] for c in changes
                if c["change"]["actions"] not in (["no-op"], ["read"])}
    except Exception as e:
        changes, acts = [], {"error": str(e)}
    return rc, acts, changes


def planned_resource_actions(r, label, *extra):
    rc, acts, _ = planned_changes(r, label, *extra)
    return rc, acts


def changed_paths(before, after, unknown, path=()):
    """Paths whose planned value differs from the prior state. Values planned
    unknown (computed by the provider at apply) are not configuration and are
    skipped; everything else, nested blocks included, is compared exactly."""
    if unknown is True:
        return []
    if isinstance(before, dict) and isinstance(after, dict):
        u = unknown if isinstance(unknown, dict) else {}
        return [p for key in sorted(set(before) | set(after))
                for p in changed_paths(before.get(key), after.get(key), u.get(key), path + (key,))]
    if isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        u = unknown if isinstance(unknown, list) else []
        return [p for i, (b, a) in enumerate(zip(before, after))
                for p in changed_paths(b, a, u[i] if i < len(u) else None, path + (i,))]
    return [] if before == after else [path]


def service_plan_paths(changes):
    c = [x for x in changes if x["address"] == SVC_ADDR]
    if len(c) != 1:
        return None
    ch = c[0]["change"]
    return changed_paths(ch.get("before"), ch.get("after"), ch.get("after_unknown"))


def service_tmp(r):
    """(volumes, container mounts) of the Fleet service as stored by the fake,
    i.e. exactly what the real google-beta provider sent."""
    t = (r.get("/_state")["services"].get(SVC) or {}).get("template") or {}
    return t.get("volumes") or [], [m for c in t.get("containers", []) for m in (c.get("volumeMounts") or [])]


def tmp_checks(r, sc, enabled, size="10Gi"):
    vols, mounts = service_tmp(r)
    detail = json.dumps({"volumes": vols, "volumeMounts": mounts})
    if enabled:
        r.check(sc, "service sent one empty_dir volume, medium DISK, sizeLimit %s, mounted at /tmp" % size,
                vols == [{"name": TMP_VOLUME_NAME, "emptyDir": {"medium": "DISK", "sizeLimit": size}}]
                and mounts == [{"name": TMP_VOLUME_NAME, "mountPath": "/tmp"}], detail)
    else:
        r.check(sc, "service has no volume and no mount (in-memory /tmp)", not vols and not mounts, detail)
    st = r.get("/_state")
    svc = st["services"].get(SVC) or {}
    t = svc.get("template") or {}
    c0 = (t.get("containers") or [{}])[0]
    r.check(sc, "service keeps launchStage GA, GEN2 and the 4096Mi memory limit",
            svc.get("launchStage") == "GA" and t.get("executionEnvironment") == "EXECUTION_ENVIRONMENT_GEN2"
            and (c0.get("resources") or {}).get("limits", {}).get("memory") == "4096Mi",
            json.dumps({"launchStage": svc.get("launchStage"), "executionEnvironment": t.get("executionEnvironment"),
                        "limits": (c0.get("resources") or {}).get("limits")}))
    jobs = {n: j["template"]["template"] for n, j in st["jobs"].items()}
    bad = [n for n, jt in jobs.items()
           if jt.get("volumes") or any(c.get("volumeMounts") for c in jt.get("containers", []))]
    r.check(sc, "migration jobs carry no volume or mount", jobs and not bad, json.dumps(bad))


def no_migration_activity(evs):
    return not any(masked("MANUAL")(e) or e["kind"] in ("job_created", "execution_started", "job_deleted",
                                                           "job_updated_UNEXPECTED", "service_created",
                                                           "service_deleted") for e in evs)


def tmp_rollout_checks(r, sc, label, want_enabled, *extra):
    """On a running (AUTOMATIC, restored) service: the /tmp change plans as
    exactly one in-place update of the service whose only differences are the
    volume and its mount (plus the settlement wait that any service update
    re-arms), applies as one provider PATCH and a new Ready
    revision, with no stop, job or migration, and then settles (no-op)."""
    st0 = r.get("/_state")["services"][SVC]
    o0 = r.outputs()
    s0 = r.seq()
    rcp, acts, changes = planned_changes(r, "%s-change" % label, *extra)
    r.check(sc, "plan: only the Fleet service updated in place (+ its settlement check re-armed), nothing else",
            rcp == 0 and acts == {SVC_ADDR: ["update"], SETTLE_ADDR: ["delete", "create"]}, json.dumps(acts)[:600])
    paths = service_plan_paths(changes)
    r.check(sc, "plan: the service diff is only the /tmp volume and its container mount",
            paths is not None and set(paths) == TMP_PLAN_PATHS, json.dumps(paths))
    rc, _ = r.apply("%s-apply" % label, *extra)
    evs = r.events_since(s0)
    r.save_events(label, evs)
    r.check(sc, "apply succeeded", rc == 0)
    r.check(sc, "no stop, no job, no execution, no service create/delete (no migration re-run)", no_migration_activity(evs))
    w = writes(evs)
    r.check(sc, "the only Cloud Run write is one provider PATCH of the service (no updateMask)",
            len(w) == 1 and w[0]["details"]["method"] == "PATCH" and w[0]["details"]["client"] == "google-beta"
            and w[0]["details"]["path"] == "/v2/" + SVC and "updateMask" not in parse_qs(w[0]["details"]["query"]),
            json.dumps([x["details"] for x in w])[:600])
    fp = [e for e in evs if e["kind"] == "service_full_patch"]
    r.check(sc, "that PATCH changed the template and kept AUTOMATIC/min=1",
            len(fp) == 1 and fp[0]["details"]["template_changed"]
            and fp[0]["details"]["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1},
            json.dumps([e["details"] for e in fp]))
    r.check(sc, "a new revision became Ready", any(k("revision_created", outcome="ready")(e) for e in evs))
    st1 = r.get("/_state")["services"][SVC]
    marker = "fleetdm.com/lifecycle-restored"
    r.check(sc, "same service (name, uid), restore marker and attempt annotation kept",
            st1["uid"] == st0["uid"] and st1["name"] == st0["name"]
            and st0.get("annotations", {}).get(marker) is not None
            and st1.get("annotations", {}).get(marker) == st0.get("annotations", {}).get(marker)
            and st1["template"].get("annotations") == st0["template"].get("annotations"),
            json.dumps({"uid": [st0["uid"], st1["uid"]], "marker": st1.get("annotations", {}).get(marker)}))
    o1 = r.outputs()
    r.check(sc, "migration identity and job name unchanged",
            o1.get("identity") == o0.get("identity") and o1.get("job_name") == o0.get("job_name") and o1.get("identity"),
            json.dumps({"before": o0, "after": o1}))
    tmp_checks(r, sc, want_enabled)
    noop_checks(r, sc, label, *extra)


def noop_checks(r, sc, label, *extra):
    s0 = r.seq()
    rc, acts = planned_resource_actions(r, label, *extra)
    r.check(sc, "next plan has no resource changes (outputs may refresh)", rc == 0 and not acts, json.dumps(acts)[:600])
    rc2, _ = r.apply("%s-noop-apply" % label, *extra)
    evs = r.events_since(s0)
    r.save_events("%s-noop" % label, evs)
    w = writes(evs)
    r.check(sc, "no-op apply sends no writes", rc2 == 0 and not w, json.dumps([x["details"] for x in w])[:600])
    rc3, _ = r.plan_exit("%s-plan-after-noop" % label, *extra)
    r.check(sc, "plan after no-op apply: exit 0", rc3 == 0, "rc=%d" % rc3)


def scenario_fresh(r):
    sc = "S1 fresh deploy"
    s0 = r.seq()
    rc, out = r.apply("s1-fresh")
    evs = r.events_since(s0)
    r.save_events("s1-fresh", evs)
    r.check(sc, "apply succeeded", rc == 0)
    nf = [e for e in evs if e["kind"] == "service_patch_not_found"]
    r.check(sc, "stop PATCH (scaling,traffic) answered 404 because the service did not exist",
            len(nf) == 1 and nf[0]["details"]["status"] == 404 and nf[0]["details"]["mask"] == "scaling,traffic"
            and nf[0]["details"]["service_exists"] is False and svc_at(nf[0]) is None,
            json.dumps([e["details"] for e in nf]))
    migration_flow_checks(r, sc, evs, "fleetdm/fleet:v4.93.0", existing=False)
    o = r.outputs()
    r.check(sc, "outputs: AUTOMATIC not yet (plan-time view MANUAL)", o.get("declared_scaling_mode") == "MANUAL", json.dumps(o))
    tmp_checks(r, sc, enabled=True)
    noop_checks(r, sc, "s1")


def scenario_env_change(r):
    sc = "S2 ordinary env change"
    s0 = r.seq()
    rc, _ = r.apply("s2-env", "-var", 'extra_env={"FLEET_EXAMPLE"="1"}')
    evs = r.events_since(s0)
    r.save_events("s2-env", evs)
    r.check(sc, "apply succeeded", rc == 0)
    r.check(sc, "no job created / no execution", not any(e["kind"] in ("job_created", "execution_started") for e in evs))
    r.check(sc, "no stop (no MANUAL)", not any(masked("MANUAL")(e) for e in evs))
    fp = [e for e in evs if e["kind"] == "service_full_patch"]
    r.check(sc, "service rolled out as AUTOMATIC/min", fp and fp[0]["details"]["scaling"].get("scalingMode") == "AUTOMATIC", json.dumps(fp[0]["details"] if fp else None))
    noop_checks(r, sc, "s2", "-var", 'extra_env={"FLEET_EXAMPLE"="1"}')


def scenario_upgrade(r, image="fleetdm/fleet:v4.94.0", sc="S3 image upgrade", label="s3"):
    ann = dict(r.get("/_state")["services"][SVC].get("annotations", {}), **{"example.com/out-of-band": label})
    r.inject(action="set_annotations", service=SVC, annotations=ann)
    s0 = r.seq()
    rc, _ = r.apply("%s-upgrade" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-upgrade" % label, evs)
    r.check(sc, "apply succeeded", rc == 0)
    migration_flow_checks(r, sc, evs, image, existing=True)
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "out-of-band service annotation survives the provider update and the restore",
            st.get("annotations", {}).get("example.com/out-of-band") == label, json.dumps(st.get("annotations")))
    stop_wait_checks(r, sc, evs)
    noop_checks(r, sc, label, "-var", "image=" + image)


def scenario_job_fail(r, outcome, image, sc, label, expect_tainted):
    r.control(job_outcomes=[outcome])
    s0 = r.seq()
    rc, out = r.apply("%s-fail" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-fail" % label, evs)
    r.check(sc, "apply failed", rc != 0)
    st = r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD)
    tainted = "(tainted)" in st
    r.check(sc, "job tainted == %s" % expect_tainted, tainted == expect_tainted, "state show header: %s" % st.splitlines()[0] if st else "missing")
    r.check(sc, "no service rollout of the new image", not any(e["kind"] in ("service_full_patch",) and e["details"]["image"] == image for e in evs))
    if outcome == "exec_failed_job_ready":
        r.check(sc, "failure names the migration-success gate", "has not succeeded" in flat(out), flat(out)[-400:])
    r.check(sc, "no AUTOMATIC restore", not any(masked("AUTOMATIC")(e) for e in evs))
    st_now = r.get("/_state")["services"][SVC]
    r.check(sc, "service left MANUAL/0", st_now["scaling"].get("scalingMode") == "MANUAL", json.dumps(st_now["scaling"]))
    first_job = [e["details"]["job"] for e in evs if e["kind"] == "job_created"]
    # retry with a plain apply, no edits
    s1 = r.seq()
    rc2, _ = r.apply("%s-retry" % label, "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("%s-retry" % label, evs2)
    r.check(sc, "plain next apply succeeded", rc2 == 0)
    jobs2 = [e["details"]["job"] for e in evs2 if e["kind"] == "job_created"]
    r.check(sc, "exactly one fresh job/execution on retry", len(jobs2) == 1 and sum(e["kind"] == "execution_started" for e in evs2) == 1, json.dumps(jobs2))
    r.log("  first job %s retry job %s" % (first_job, jobs2))
    ok, pos = ordered(evs2, k("execution_finished", outcome="success"), lambda e: e["kind"] == "service_full_patch", masked("AUTOMATIC"))
    r.check(sc, "retry: success -> deploy -> restore", ok, "pos=%s" % pos)
    noop_checks(r, sc, label, "-var", "image=" + image)
    return first_job, jobs2


def scenario_rollout_fail(r, shape, image, sc, label):
    r.control(rollout_outcomes=[shape])
    s0 = r.seq()
    rc, _ = r.apply("%s-fail" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-fail" % label, evs)
    r.check(sc, "apply failed", rc != 0)
    r.check(sc, "migration ran once and succeeded", sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs) == 1)
    r.check(sc, "no AUTOMATIC restore after failed rollout", not any(masked("AUTOMATIC")(e) for e in evs))
    st_now = r.get("/_state")["services"][SVC]
    r.check(sc, "service stays MANUAL (old ready revision not restarted)", st_now["scaling"].get("scalingMode") == "MANUAL", json.dumps(st_now["scaling"]))
    s1 = r.seq()
    rc2, _ = r.apply("%s-retry" % label, "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("%s-retry" % label, evs2)
    r.check(sc, "plain next apply succeeded", rc2 == 0)
    r.check(sc, "no new migration on rollout retry", not any(e["kind"] == "execution_started" for e in evs2))
    ok, pos = ordered(evs2, lambda e: e["kind"] == "service_full_patch" and e["details"]["template_changed"], k("revision_created", outcome="ready"), masked("AUTOMATIC"))
    r.check(sc, "fresh revision deployed then restored", ok, "pos=%s" % pos)
    noop_checks(r, sc, label, "-var", "image=" + image)


def scenario_tag_removed(r):
    sc = "S8 out-of-band traffic tag removed by stop"
    r.inject(action="add_traffic_tag", service=SVC, tag="canary")
    s0 = r.seq()
    rc, _ = r.apply("s8-tag", "-var", "image=fleetdm/fleet:v4.99.1")
    evs = r.events_since(s0)
    r.save_events("s8-tag", evs)
    r.check(sc, "apply succeeded", rc == 0)
    ex = [e for e in evs if e["kind"] == "execution_started"]
    r.check(sc, "no tags while migration ran", ex and not svc_at(ex[0])["traffic_tags"], json.dumps(svc_at(ex[0]) if ex else None))
    noop_checks(r, sc, "s8", "-var", "image=fleetdm/fleet:v4.99.1")


def scenario_tag_blocks(r):
    sc = "S9 tag that survives the stop blocks the migration"
    r.control(ignore_traffic_in_masked_patch=True)
    r.inject(action="add_traffic_tag", service=SVC, tag="canary")
    s0 = r.seq()
    rc, out = r.apply("s9-tag-blocks", "-var", "image=fleetdm/fleet:v4.99.2")
    evs = r.events_since(s0)
    r.save_events("s9-tag-blocks", evs)
    r.check(sc, "apply failed before any job", rc != 0 and not any(e["kind"] == "job_created" for e in evs))
    r.check(sc, "failure names the verify gate", "not verifiably stopped" in out)
    r.control(ignore_traffic_in_masked_patch=False)
    s1 = r.seq()
    rc2, out2 = r.apply("s9-plain-retry", "-var", "image=fleetdm/fleet:v4.99.2")
    evs2 = r.events_since(s1)
    r.save_events("s9-plain-retry", evs2)
    r.check(sc, "KNOWN GAP: plain retry still blocked while the tag is live (stop not re-sent)", rc2 != 0 and not any(e["kind"] == "job_created" for e in evs2),
            "rc=%d" % rc2)
    # documented remedy: re-send the stop for the current attempt (the
    # PATCH normalises traffic and removes the tag), then the same apply runs
    s2 = r.seq()
    rc3, _ = r.tf("s9-replace-stop", "apply", "-auto-approve", "-no-color", "-var", "image=fleetdm/fleet:v4.99.2",
                  "-replace=%s.terracurl_request.stop[0]" % MOD)
    evs3 = r.events_since(s2)
    r.save_events("s9-replace-stop", evs3)
    r.check(sc, "documented remedy (-replace stop) re-sends the stop, removes the tag and completes", rc3 == 0 and any(e["kind"] == "execution_started" for e in evs3), "rc=%d" % rc3)
    noop_checks(r, sc, "s9", "-var", "image=fleetdm/fleet:v4.99.2")


def scenario_db_replace(r):
    sc = "S10 same-name DB replacement (unknown-on-replacement identity)"
    image = "fleetdm/fleet:v4.99.2"
    rc, out = r.tf("s10-plan-json", "plan", "-no-color", "-out=s10.tfplan", "-var", "image=" + image, "-replace=terraform_data.fake_sql")
    rcj, js = r.tf("s10-show", "show", "-json", "s10.tfplan")
    try:
        plan = json.loads(js)
        acts = {c["address"]: c["change"]["actions"] for c in plan["resource_changes"]}
    except Exception as e:
        acts = {"error": str(e)}
    with open(os.path.join(r.art, "s10-plan-actions.json"), "w") as f:
        json.dump(acts, f, indent=1)
    r.check(sc, "identity planned for replacement although connection string is unchanged",
            acts.get("%s.terraform_data.identity[0]" % MOD) in (["delete", "create"], ["create", "delete"]), json.dumps(acts.get("%s.terraform_data.identity[0]" % MOD)))
    r.check(sc, "job planned for replacement", acts.get("%s.google_cloud_run_v2_job.migration[0]" % MOD) in (["delete", "create"], ["create", "delete"]))
    s0 = r.seq()
    rc2, _ = r.tf("s10-apply", "apply", "-auto-approve", "-no-color", "s10.tfplan")
    evs = r.events_since(s0)
    r.save_events("s10-apply", evs)
    r.check(sc, "apply succeeded", rc2 == 0)
    migration_flow_checks(r, sc, evs, image, existing=True)
    noop_checks(r, sc, "s10", "-var", "image=" + image)


def scenario_proven_job_deleted(r):
    sc = "S11 proven identity, job deleted out of band"
    job = PARENT + "/jobs/" + r.outputs()["job_name"]  # the module's current job (not an injected one)
    r.inject(action="delete_job", job=job)
    s0 = r.seq()
    rc, _ = r.apply("s11-apply", "-var", "image=fleetdm/fleet:v4.99.2")
    evs = r.events_since(s0)
    r.save_events("s11", evs)
    r.check(sc, "apply succeeded", rc == 0)
    jc = [e for e in evs if e["kind"] == "job_created"]
    r.check(sc, "job re-created WITHOUT run_execution_token", len(jc) == 1 and not jc[0]["details"]["token"], json.dumps([e["details"] for e in jc]))
    r.check(sc, "no execution, no stop", not any(e["kind"] == "execution_started" for e in evs) and not any(masked("MANUAL")(e) for e in evs))
    noop_checks(r, sc, "s11", "-var", "image=fleetdm/fleet:v4.99.2")


def scenario_hard_kill(r):
    sc = "S12 hard kill (SIGKILL) during the migration job wait"
    image = "fleetdm/fleet:v5.0.0"
    r.control(exec_polls=1000)
    s0 = r.seq()
    p, logp = r.tf("s12-killed", "apply", "-auto-approve", "-no-color", "-var", "image=" + image, background=True)
    t0 = time.time()
    while time.time() - t0 < 300:
        if any(e["kind"] == "execution_started" for e in r.events_since(s0)):
            break
        time.sleep(0.5)
    time.sleep(2)
    os.killpg(p.pid, signal.SIGKILL)  # terraform AND its provider plugins
    p.wait()
    r.log("  terraform SIGKILLed during job wait")
    # time passes: the orphan execution finishes successfully on the server
    r.control(exec_polls=1)
    r.inject(action="finish_executions")
    st = r.get("/_state")
    r.check(sc, "orphan job exists on the server", any(image in json.dumps(j) for j in st["jobs"].values()))
    s1 = r.seq()
    rc, out = r.apply("s12-after-kill", "-var", "image=" + image)
    evs = r.events_since(s1)
    r.save_events("s12-after-kill", evs)
    lock = "state lock" in out.lower() or "lock" in out.lower() and "acquiring" in out.lower()
    r.log("  after-kill apply rc=%d lock_error=%s" % (rc, lock))
    rc2, out2 = (rc, out)
    if rc != 0 and lock:
        rc2, out2 = r.apply("s12-after-kill-nolock", "-var", "image=" + image, "-lock=false")
    evs2 = r.events_since(s1)
    r.save_events("s12-after-kill-all", evs2)
    conflict = "409" in out2 or "already exists" in out2.lower() or "Cannot classify" in out2
    r.check(sc, "RESIDUAL GAP reproduced: plain apply after hard kill does not complete (orphan job / 409 / lock)",
            rc2 != 0, "rc=%d conflict=%s lock_first=%s" % (rc2, conflict, lock))
    with open(os.path.join(r.art, "s12-after-kill-summary.txt"), "w") as f:
        f.write("first rc=%d lock=%s\nsecond rc=%d conflict=%s\n%s\n" % (rc, lock, rc2, conflict, out2[-3000:]))
    # Manual remedy: import the orphan job, then a
    # plain apply. The orphan's execution already succeeded, so no new
    # migration is expected.
    orphan = [n for n, j in r.get("/_state")["jobs"].items() if image in json.dumps(j)]
    if orphan:
        rci, _ = r.tf("s12-import", "import", "-no-color", "-var", "image=" + image,
                      "%s.google_cloud_run_v2_job.migration[0]" % MOD, orphan[0])
        s2 = r.seq()
        rc3, _ = r.apply("s12-after-import", "-var", "image=" + image)
        evs3 = r.events_since(s2)
        r.save_events("s12-after-import", evs3)
        r.check(sc, "after manual `terraform import` of the orphan, a plain apply completes without a new execution",
                rci == 0 and rc3 == 0 and not any(e["kind"] == "execution_started" for e in evs3)
                and any(masked("AUTOMATIC")(e) for e in evs3), "import rc=%d apply rc=%d" % (rci, rc3))
        noop_checks(r, sc, "s12", "-var", "image=" + image)


def scenario_restore_lro_error(r):
    sc = "S13 restore PATCH accepted (HTTP 200) but its LRO completes with an error"
    image = "fleetdm/fleet:v5.0.1"
    r.control(restore_patch_outcomes=["op_error"])
    s0 = r.seq()
    rc, out = r.apply("s13-fail", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s13-fail", evs)
    r.check(sc, "apply FAILS (not silent success)", rc != 0, "rc=%d" % rc)
    r.check(sc, "failure names the restore read-back", "Restore did not take effect" in out)
    r.check(sc, "failed restore diagnostic is static and sensitivity-safe (sensitive min input)", no_sensitive_diagnostic(out),
            flat(out)[-400:])
    r.check(sc, "the failed restore LRO was actually returned", any(e["kind"] == "service_masked_patch_failed_lro" for e in evs))
    r.check(sc, "migration ran exactly once and succeeded",
            sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs) == 1)
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "service still MANUAL after the failed restore", st["scaling"].get("scalingMode") == "MANUAL", json.dumps(st["scaling"]))
    s1 = r.seq()
    rc2, _ = r.apply("s13-retry", "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("s13-retry", evs2)
    r.check(sc, "plain next apply succeeds", rc2 == 0, "rc=%d" % rc2)
    r.check(sc, "retry re-sends the restore and does not migrate or redeploy",
            any(masked("AUTOMATIC")(e) for e in evs2) and not any(e["kind"] in ("execution_started", "job_created", "revision_created") for e in evs2)
            and not any(masked("MANUAL")(e) for e in evs2), json.dumps([e["kind"] for e in evs2 if e["kind"] != "http"]))
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "service restored AUTOMATIC/1 with marker and restore key",
            st["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1}
            and "fleetdm.com/lifecycle-restored" in st.get("annotations", {})
            and "fleetdm.com/lifecycle-restore-key" in st.get("annotations", {}), json.dumps([st["scaling"], st.get("annotations")]))
    noop_checks(r, sc, "s13", "-var", "image=" + image)


def flat(out):
    """Terraform wraps diagnostics; compare messages on collapsed whitespace."""
    return " ".join(out.split())


def no_sensitive_diagnostic(out):
    """Terraform refuses an error_message that interpolates sensitive values:
    it prints 'Error message refers to sensitive values' plus 'invalid error
    message' instead of the intended diagnostic. A static message must never
    produce either (the fixture passes a sensitive min_instance_count, like the
    real GCP root's sensitive fleet_config)."""
    low = flat(out).lower()
    return ("error message refers to sensitive values" not in low
            and "invalid error message" not in low
            and "sensitive values" not in low)


def tf_line(out, needle):
    for i, line in enumerate(out.splitlines()):
        if needle in line:
            return i
    return None


def no_migration_checks(r, sc, evs):
    r.check(sc, "no migration: no job created, no execution, no stop",
            not any(e["kind"] in ("job_created", "execution_started") for e in evs) and not any(masked("MANUAL")(e) for e in evs),
            json.dumps([e["kind"] for e in evs if e["kind"] != "http"])[:600])


def scenario_image_contract(r):
    sc = "S14 plain version tags; API reports a digest alias, then omits the image"
    r.control(image_report="alias")
    try:
        scenario_upgrade(r, "fleetdm/fleet:v5.0.2", sc + " / alias upgrade", "s14a")
        # restore LRO error under an alias-reporting API: the plain retry must
        # still re-send the restore (attempt UID + Ready suffice)
        sc2 = sc + " / alias restore retry"
        image = "fleetdm/fleet:v5.0.3"
        r.control(restore_patch_outcomes=["op_error"])
        s0 = r.seq()
        rc, out = r.apply("s14b-fail", "-var", "image=" + image)
        r.save_events("s14b-fail", r.events_since(s0))
        r.check(sc2, "restore LRO error fails the apply", rc != 0 and "Restore did not take effect" in out, "rc=%d" % rc)
        r.check(sc2, "failed restore diagnostic is static and sensitivity-safe (sensitive min input)", no_sensitive_diagnostic(out),
                flat(out)[-400:])
        s1 = r.seq()
        rc2, _ = r.apply("s14b-retry", "-var", "image=" + image)
        evs2 = r.events_since(s1)
        r.save_events("s14b-retry", evs2)
        r.check(sc2, "plain retry succeeds and re-sends the restore although the API reports another image",
                rc2 == 0 and any(masked("AUTOMATIC")(e) for e in evs2), "rc=%d" % rc2)
        no_migration_checks(r, sc2, evs2)
        noop_checks(r, sc2, "s14b", "-var", "image=" + image)
        r.control(image_report="absent")
        scenario_upgrade(r, "fleetdm/fleet:v5.0.4", sc + " / image omitted upgrade", "s14c")
    finally:
        r.control(image_report="as_sent")


def scenario_restore_settlement(r, mode, image, label, settle_before_retry):
    sc = "S15 restore desired fields visible but control plane %s" % mode
    r.control(restore_settle_outcomes=[mode])
    s0 = r.seq()
    rc, out = r.apply("%s-fail" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-fail" % label, evs)
    r.check(sc, "first apply FAILS (desired fields alone are not a restore)", rc != 0 and "has not settled" in flat(out), "rc=%d" % rc)
    r.check(sc, "failed restore diagnostic is static and sensitivity-safe (sensitive min input)", no_sensitive_diagnostic(out),
            flat(out)[-400:])
    r.check(sc, "migration ran exactly once and succeeded",
            sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs) == 1)
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "desired marker + AUTOMATIC were stored by the restore PATCH (unsettled observed side)",
            st["scaling"].get("scalingMode") == "AUTOMATIC" and "fleetdm.com/lifecycle-restored" in st.get("annotations", {})
            and st.get("_held") == mode, json.dumps([st["scaling"], st.get("generation"), st.get("observedGeneration"), st.get("_held")]))
    if settle_before_retry:
        r.inject(action="settle_service", service=SVC)
    s1 = r.seq()
    rc2, _ = r.apply("%s-retry" % label, "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("%s-retry" % label, evs2)
    r.check(sc, "plain retry succeeds", rc2 == 0, "rc=%d" % rc2)
    no_migration_checks(r, sc, evs2)
    if settle_before_retry:
        r.check(sc, "settled meanwhile: retry sends no writes at all", not writes(evs2), json.dumps([x["details"] for x in writes(evs2)])[:600])
    else:
        r.check(sc, "still unsettled: retry deploys a fresh revision of the same attempt (nonce), Fleet stays AUTOMATIC",
                any(e["kind"] == "service_full_patch" and e["details"]["template_changed"] for e in evs2)
                and any(e["kind"] == "revision_created" and e["details"]["outcome"] == "ready" for e in evs2),
                json.dumps([e["kind"] for e in evs2 if e["kind"] != "http"]))
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "service settled AUTOMATIC/1 with the marker",
            st["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1} and not st.get("_held")
            and st.get("observedGeneration") == st.get("generation") and st["terminalCondition"]["state"] == "CONDITION_SUCCEEDED",
            json.dumps([st["scaling"], st.get("generation"), st.get("observedGeneration"), st["terminalCondition"]]))
    noop_checks(r, sc, label, "-var", "image=" + image)


def scenario_transient_restore_settles(r):
    """A healthy restore must wait through the normal transient RECONCILING
    state inside ONE apply. The fake reports the desired marker + AUTOMATIC/min
    but an unsettled observed side for several successive reads, then settles
    by itself, with no new PATCH and no new revision."""
    sc = "S18 healthy transient restore settles within one apply"
    image = "fleetdm/fleet:v5.5.0"
    r.control(restore_settle_outcomes=["pending_then_settle"], restore_settle_reads=2)
    s0 = r.seq()
    rc, out = r.apply("s18-transient", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s18-transient", evs)
    r.check(sc, "apply succeeded (one apply, no manual retry)", rc == 0, "rc=%d" % rc)
    r.check(sc, "successful restore diagnostic path is sensitivity-safe (sensitive min input)", no_sensitive_diagnostic(out),
            flat(out)[-400:])
    r.check(sc, "migration ran exactly once",
            sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs) == 1)
    restores = [e for e in evs if masked("AUTOMATIC")(e)]
    r.check(sc, "exactly one restore PATCH", len(restores) == 1, "n=%d" % len(restores))
    if restores:
        after = evs[evs.index(restores[-1]) + 1:]
        # The restore's own best-effort operations.wait (a POST) is expected;
        # everything after it must be read-only.
        waits = [i for i, e in enumerate(after) if e["kind"] == "operation_wait"]
        after_wait = after[waits[-1] + 1:] if waits else after
        r.check(sc, "no further writes, revision or execution after the restore's operation wait",
                not writes(after_wait)
                and not any(e["kind"] in ("revision_created", "job_created", "execution_started") for e in after_wait),
                json.dumps([e["kind"] for e in after_wait if e["kind"] != "http"])[:600])
        pending = [e for e in after_wait if e["kind"] == "restore_settle_read"
                   and e["details"]["observedGeneration"] != e["details"]["generation"]]
        r.check(sc, "control plane was still pending on the first read after the restore",
                len(pending) >= 1,
                json.dumps([e["details"] for e in pending])[:600])
        r.check(sc, "the read that settled the service needed no new PATCH or revision",
                any(e["kind"] == "restore_settled_on_read" for e in after_wait),
                json.dumps([e["kind"] for e in after_wait if e["kind"] != "http"])[:600])
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "settled automatically: observed generation, Ready SUCCEEDED, marker, AUTOMATIC/min, nothing held",
            st["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1}
            and not st.get("_held") and st.get("observedGeneration") == st.get("generation")
            and st["terminalCondition"]["state"] == "CONDITION_SUCCEEDED"
            and "fleetdm.com/lifecycle-restored" in st.get("annotations", {}),
            json.dumps([st["scaling"], st.get("_held"), st.get("generation"), st.get("observedGeneration"), st["terminalCondition"]]))
    r.control(restore_settle_outcomes=[], restore_settle_reads=2)
    noop_checks(r, sc, "s18", "-var", "image=" + image)


def scenario_fresh_stop_fresh_drain(r):
    sc = "S16 tainted job with a running execution; re-sent stop (same attempt, Fleet restarted out of band) gets a NEW drain"
    image = "fleetdm/fleet:v5.2.0"
    drain = 2  # fixture default drain_seconds
    r.control(job_outcomes=["lro_error_active"])
    s0 = r.seq()
    rc, out = r.apply("s16-fail", "-var", "image=" + image)
    r.save_events("s16-fail", r.events_since(s0))
    r.check(sc, "first apply: drain completed, job create failed (tainted), its execution still running",
            rc != 0 and "time_sleep.drain[0]: Creation complete" in out
            and "(tainted)" in r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD)
            and any(j.get("latestCreatedExecution", {}).get("completionStatus") == "EXECUTION_RUNNING"
                    for j in r.get("/_state")["jobs"].values()), "rc=%d" % rc)
    s1 = r.seq()
    rc1, out1 = r.apply("s16-running", "-var", "image=" + image)
    evs1 = r.events_since(s1)
    r.save_events("s16-running", evs1)
    r.check(sc, "plain re-apply while it runs: blocked at PLAN, the tainted job is NOT deleted, nothing written",
            rc1 != 0 and "pending or running execution" in flat(out1) and not writes(evs1), "rc=%d" % rc1)
    r.inject(action="complete_running_executions")
    r.inject(action="set_scaling", service=SVC, scaling={"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
    s1 = r.seq()
    rc2, out2 = r.apply("s16-plain-retry", "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("s16-plain-retry", evs2)
    r.check(sc, "plain retry blocked by verify (no job replaced/deleted, nothing written)",
            rc2 != 0 and "not verifiably stopped" in flat(out2) and not writes(evs2), "rc=%d" % rc2)
    s2 = r.seq()
    rc3, out3 = r.tf("s16-replace-stop", "apply", "-auto-approve", "-no-color", "-var", "image=" + image,
                     "-replace=%s.terracurl_request.stop[0]" % MOD)
    evs3 = r.events_since(s2)
    r.save_events("s16-replace-stop", evs3)
    r.check(sc, "-replace stop completes with exactly one new execution", rc3 == 0 and sum(e["kind"] == "execution_started" for e in evs3) == 1, "rc=%d" % rc3)
    d0 = tf_line(out3, "time_sleep.drain[0]: Creating...")
    d1 = tf_line(out3, "time_sleep.drain[0]: Creation complete")
    j0 = tf_line(out3, "google_cloud_run_v2_job.migration[0]: Creating...")
    r.check(sc, "a NEW drain is created after the re-sent stop and completes before the job is (re)created",
            None not in (d0, d1, j0) and d0 < d1 < j0, "drain_create=%s drain_done=%s job_create=%s" % (d0, d1, j0))
    stops = [e for e in evs3 if masked("MANUAL")(e)]
    jc = [e for e in evs3 if e["kind"] == "job_created"]
    r.check(sc, "new job created >= drain_seconds after the new stop PATCH",
            stops and jc and jc[0]["t"] - stops[-1]["t"] >= drain, "gap=%s" % ((jc[0]["t"] - stops[-1]["t"]) if stops and jc else None))
    stop_wait_checks(r, sc, evs3)
    if jc:
        s = svc_at(jc[0])
        r.check(sc, "service MANUAL/0 when the new job started", s and s["scaling"].get("scalingMode") == "MANUAL", json.dumps(s))
    noop_checks(r, sc, "s16", "-var", "image=" + image)


def scenario_proven_job_recreated_unsettled_restore(r):
    sc = "S11b proven identity, job re-created out of band, re-sent restore does not settle"
    image = "fleetdm/fleet:v4.99.2"
    job = PARENT + "/jobs/" + r.outputs()["job_name"]
    r.inject(action="delete_job", job=job)
    r.control(restore_settle_outcomes=["lag_success"])
    s0 = r.seq()
    rc, out = r.apply("s11b-fail", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s11b-fail", evs)
    r.check(sc, "restore re-sent for the new job UID; unsettled read-back FAILS the apply (no pre-apply snapshot shortcut)",
            rc != 0 and "has not settled" in flat(out) and any(masked("AUTOMATIC")(e) for e in evs), "rc=%d" % rc)
    r.check(sc, "failed restore diagnostic is static and sensitivity-safe (sensitive min input)", no_sensitive_diagnostic(out),
            flat(out)[-400:])
    jc = [e for e in evs if e["kind"] == "job_created"]
    r.check(sc, "deleted job re-created WITHOUT run_execution_token; no execution, no stop",
            len(jc) == 1 and not jc[0]["details"]["token"] and not any(e["kind"] == "execution_started" for e in evs)
            and not any(masked("MANUAL")(e) for e in evs), json.dumps([e["details"] for e in jc]))
    s1 = r.seq()
    rc2, _ = r.apply("s11b-retry", "-var", "image=" + image)
    evs2 = r.events_since(s1)
    r.save_events("s11b-retry", evs2)
    r.check(sc, "plain retry converges via a fresh revision of the same attempt",
            rc2 == 0 and any(e["kind"] == "service_full_patch" and e["details"]["template_changed"] for e in evs2), "rc=%d" % rc2)
    no_migration_checks(r, sc, evs2)
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "service settled AUTOMATIC/1", st["scaling"] == {"scalingMode": "AUTOMATIC", "minInstanceCount": 1}
            and st.get("observedGeneration") == st.get("generation") and not st.get("_held"), json.dumps(st["scaling"]))
    noop_checks(r, sc, "s11b", "-var", "image=" + image)


def scenario_marker_repair(r):
    sc = "S19 restore marker stripped while Fleet serves the current attempt"
    image = "fleetdm/fleet:v5.5.0"
    ann = r.get("/_state")["services"][SVC].get("annotations", {})
    r.inject(action="set_annotations", service=SVC,
             annotations={k: v for k, v in ann.items() if k != "fleetdm.com/lifecycle-restored"})
    s0 = r.seq()
    rc, _ = r.apply("s19-repair", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s19-repair", evs)
    r.check(sc, "plain apply succeeds and only re-sends the restore", rc == 0 and any(masked("AUTOMATIC")(e) for e in evs), "rc=%d" % rc)
    no_migration_checks(r, sc, evs)
    r.check(sc, "Fleet never declared/written MANUAL (no outage to repair the marker)",
            not any(e["kind"] in ("service_full_patch", "service_masked_patch") and e["details"]["scaling"].get("scalingMode") == "MANUAL"
                    for e in evs), json.dumps([e["kind"] for e in evs if e["kind"] != "http"])[:600])
    st = r.get("/_state")["services"][SVC]
    r.check(sc, "marker restored", "fleetdm.com/lifecycle-restored" in st.get("annotations", {}), json.dumps(st.get("annotations")))
    noop_checks(r, sc, "s19", "-var", "image=" + image)


def scenario_cross_identity_running(r):
    sc = "S20 tainted job still running; a new identity (image or database) is blocked at plan"
    image_a, image_b = "fleetdm/fleet:v5.6.0", "fleetdm/fleet:v5.6.1"
    r.control(job_outcomes=["lro_error_active"])
    s0 = r.seq()
    rc, _ = r.apply("s20-fail", "-var", "image=" + image_a)
    r.save_events("s20-fail", r.events_since(s0))
    running = [n for n, j in r.get("/_state")["jobs"].items()
               if j.get("latestCreatedExecution", {}).get("completionStatus") == "EXECUTION_RUNNING"]
    r.check(sc, "setup: job A tainted, its execution still running",
            rc != 0 and "(tainted)" in r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD) and len(running) == 1, "rc=%d" % rc)
    job_a = running[0] if running else PARENT + "/jobs/missing"
    # Outside the guard's scope: other prefix, unlabelled, finished history.
    other = {PARENT + "/jobs/other-migrate-0123456789ab": ({"fleetdm-lifecycle-identity": "0123456789ab"}, "EXECUTION_RUNNING"),
             PARENT + "/jobs/fleet-migrate-0123456789ab": ({}, "EXECUTION_PENDING"),
             PARENT + "/jobs/fleet-migrate-ba9876543210": ({"fleetdm-lifecycle-identity": "ba9876543210"}, "EXECUTION_SUCCEEDED")}
    for name, (labels, status) in other.items():
        r.inject(action="put_job", job=name, labels=labels, status=status)
    for status, change, extra in (("EXECUTION_RUNNING", "image", ["-var", "image=" + image_b]),
                                  ("EXECUTION_PENDING", "image", ["-var", "image=" + image_b]),
                                  ("EXECUTION_RUNNING", "db", ["-var", "image=" + image_a, "-replace=terraform_data.fake_sql"]),
                                  ("EXECUTION_PENDING", "db", ["-var", "image=" + image_a, "-replace=terraform_data.fake_sql"])):
        r.inject(action="put_job", job=job_a, status=status)
        label = "s20-%s-%s" % (change, status.split("_")[1].lower())
        s1 = r.seq()
        rc1, out1 = r.apply(label, *extra)
        evs1 = r.events_since(s1)
        r.save_events(label, evs1)
        a = r.get("/_state")["jobs"].get(job_a, {})
        r.check(sc, "%s change while A is %s: fails at PLAN naming A; nothing written, A kept, no new execution" % (change, status),
                rc1 != 0 and not any(m in out1 for m in ("Destroying...", "Creating...", "Modifying...")) and "still pending or running: " + job_a.split("/")[-1] in flat(out1)
                and not writes(evs1) and a.get("latestCreatedExecution", {}).get("completionStatus") == status
                and no_sensitive_diagnostic(out1), "rc=%d %s" % (rc1, flat(out1)[-300:]))
    # A finished: the intended next attempt runs once; out-of-scope jobs never block.
    r.inject(action="put_job", job=job_a, status="EXECUTION_SUCCEEDED")
    s2 = r.seq()
    rc2, _ = r.apply("s20-finished", "-var", "image=" + image_b)
    evs2 = r.events_since(s2)
    r.save_events("s20-finished", evs2)
    r.check(sc, "A finished: apply succeeds; A deleted only after it finished", rc2 == 0
            and [e["details"]["execution_status"] for e in evs2 if k("job_deleted", job=job_a)(e)] == ["EXECUTION_SUCCEEDED"], "rc=%d" % rc2)
    migration_flow_checks(r, sc, evs2, image_b, existing=True)
    noop_checks(r, sc, "s20", "-var", "image=" + image_b)
    # Out-of-band execution of the identity the marker proves: no-op as before.
    job_b = PARENT + "/jobs/" + r.outputs()["job_name"]
    r.inject(action="put_job", job=job_b, status="EXECUTION_RUNNING")
    rc3, _ = r.plan_exit("s20-proven-running", "-var", "image=" + image_b)
    r.check(sc, "running execution of the proven identity: plan is still a no-op", rc3 == 0, "rc=%d" % rc3)
    r.inject(action="put_job", job=job_b, status="EXECUTION_SUCCEEDED")
    for name in other:
        r.inject(action="delete_job", job=name)


def job_cbd_in_state(r):
    """create_before_destroy as stored on the migration job instance(s)."""
    st = json.load(open(os.path.join(r.work, "terraform.tfstate")))
    return [i.get("create_before_destroy", False) for res in st["resources"]
            if res.get("module") == MOD and res["mode"] == "managed" and res["type"] == "google_cloud_run_v2_job"
            for i in res["instances"]]


def scenario_neg_cbd_tainted_completed(r):
    sc = "S21 NEG stand-in with a create_before_destroy dependent; tainted job whose execution then succeeds"
    image = "fleetdm/fleet:v5.7.0"
    jaddr = "%s.google_cloud_run_v2_job.migration[0]" % MOD
    r.check(sc, "fixture NEG edge = root NEG expressions, none via the lifecycle module",
            len(r.neg_refs) == 2 and not any("module." in x for x in r.neg_refs), json.dumps(r.neg_refs))
    r.control(job_outcomes=["lro_error_active"])
    s0 = r.seq()
    rc, _ = r.apply("s21-fail", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s21-fail", evs)
    jc = [e["details"]["job"] for e in evs if e["kind"] == "job_created"]
    job = jc[0] if jc else PARENT + "/jobs/missing"
    r.check(sc, "setup: job tainted, its execution still running",
            rc != 0 and len(jc) == 1 and "(tainted)" in r.state_show(jaddr)
            and r.get("/_state")["jobs"].get(job, {}).get("latestCreatedExecution", {}).get("completionStatus") == "EXECUTION_RUNNING", "rc=%d" % rc)
    r.check(sc, "create_before_destroy not stored on the job", job_cbd_in_state(r) == [False], json.dumps(job_cbd_in_state(r)))
    for status in ("EXECUTION_RUNNING", "EXECUTION_PENDING"):
        r.inject(action="put_job", job=job, status=status)
        s1 = r.seq()
        rc1, out1 = r.apply("s21-%s" % status.split("_")[1].lower(), "-var", "image=" + image)
        evs1 = r.events_since(s1)
        r.check(sc, "%s: blocked at plan, tainted job kept, nothing written" % status,
                rc1 != 0 and "pending or running" in flat(out1) and not writes(evs1) and job in r.get("/_state")["jobs"], "rc=%d" % rc1)
    r.inject(action="put_job", job=job, status="EXECUTION_SUCCEEDED", condition="CONDITION_SUCCEEDED")
    _, acts = planned_resource_actions(r, "s21-retry", "-var", "image=" + image)
    r.check(sc, "retry plans the tainted job delete-then-create", acts.get(jaddr) == ["delete", "create"], json.dumps(acts.get(jaddr)))
    s2 = r.seq()
    rc2, out2 = r.apply("s21-retry", "-var", "image=" + image)
    evs2 = r.events_since(s2)
    r.save_events("s21-retry", evs2)
    r.check(sc, "plain retry succeeds, no same-name conflict (409)",
            rc2 == 0 and "409" not in out2 and "already exists" not in out2.lower(), "rc=%d %s" % (rc2, flat(out2)[-400:]))
    ok, pos = ordered(evs2, k("job_deleted", job=job), k("job_created", job=job), k("execution_started"),
                      k("execution_finished", outcome="success"), lambda e: e["kind"] == "service_full_patch", masked("AUTOMATIC"))
    r.check(sc, "finished job deleted, same name re-created and run, then deploy and restore", ok, "pos=%s" % pos)
    ex = [e for e in evs2 if e["kind"] == "execution_started"]
    r.check(sc, "exactly one extra execution, Fleet still MANUAL; no new stop or drain (same attempt)",
            len(ex) == 1 and (svc_at(ex[0]) or {}).get("scaling", {}).get("scalingMode") == "MANUAL"
            and not any(masked("MANUAL")(e) for e in evs2) and "time_sleep.drain[0]: Creating" not in out2, "n=%d" % len(ex))
    noop_checks(r, sc, "s21", "-var", "image=" + image)


def scenario_neg_cbd_failed_then_rollout(r):
    sc = "S21b failed migration, retry migrates but its rollout fails, plain retry reuses the migration"
    image = "fleetdm/fleet:v5.7.1"
    r.control(job_outcomes=["lro_error_reconciling"])
    s0 = r.seq()
    rc, _ = r.apply("s21b-fail", "-var", "image=" + image)
    r.save_events("s21b-fail", r.events_since(s0))
    r.check(sc, "setup: migration failed, job tainted", rc != 0 and "(tainted)" in r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD), "rc=%d" % rc)
    r.control(rollout_outcomes=["lro_error"])
    s1 = r.seq()
    rc1, _ = r.apply("s21b-rollout-fail", "-var", "image=" + image)
    evs1 = r.events_since(s1)
    r.save_events("s21b-rollout-fail", evs1)
    new = [e["details"]["job"] for e in evs1 if e["kind"] == "job_created"]
    label = r.get("/_state")["jobs"].get(new[0] if new else "", {}).get("labels", {}).get("fleetdm-lifecycle-identity")
    same = [n for n, j in r.get("/_state")["jobs"].items() if label and j.get("labels", {}).get("fleetdm-lifecycle-identity") == label]
    r.check(sc, "retry: failed job deleted before its successor, one successful migration, rollout fails, no restore",
            rc1 != 0 and ordered(evs1, k("job_deleted"), k("job_created"))[0] and same == new
            and sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs1) == 1
            and not any(masked("AUTOMATIC")(e) for e in evs1), "rc=%d jobs of identity=%s" % (rc1, same))
    s2 = r.seq()
    rc2, out2 = r.apply("s21b-retry", "-var", "image=" + image)
    evs2 = r.events_since(s2)
    r.save_events("s21b-retry", evs2)
    r.check(sc, "plain retry succeeds without a new migration or classification error",
            rc2 == 0 and not any(e["kind"] in ("job_created", "execution_started") for e in evs2) and "Cannot classify" not in flat(out2),
            "rc=%d %s" % (rc2, flat(out2)[-400:]))
    ok, pos = ordered(evs2, lambda e: e["kind"] == "service_full_patch", k("revision_created", outcome="ready"), masked("AUTOMATIC"))
    r.check(sc, "fresh revision deployed then restored", ok, "pos=%s" % pos)
    noop_checks(r, sc, "s21b", "-var", "image=" + image)


def scenario_provider_upgrade(r):
    """U1: state written by the previous fixture/module with the older
    google-beta is taken over by the current module and --provider-version.
    With /tmp opted out: no resource changes and no Cloud Run writes. With the
    default /tmp: one in-place service update (volume + mount only), no
    migration, then a settled no-op. Then a normal migration, and turning /tmp
    off again (the reverse in-place update)."""
    a = r.args
    sc = "U1 upgrade from %s (google-beta %s) to the current module (google-beta %s)" % (
        a.upgrade_from_ref, a.upgrade_from_provider_version, a.provider_version)
    s0 = r.seq()
    rc, _ = r.apply("u1-old-fresh")
    evs = r.events_since(s0)
    r.save_events("u1-old-fresh", evs)
    r.check(sc, "previous module: fresh apply succeeded (google-beta %s)" % a.upgrade_from_provider_version, rc == 0)
    migration_flow_checks(r, sc, evs, "fleetdm/fleet:v4.93.0", existing=False)
    rcp, acts = planned_resource_actions(r, "u1-old")
    r.check(sc, "previous module: next plan has no resource changes (outputs may refresh)", rcp == 0 and not acts,
            json.dumps(acts)[:600])
    vols, mounts = service_tmp(r)
    r.check(sc, "previous module: service has no volume and no mount (in-memory /tmp)", not vols and not mounts,
            json.dumps({"volumes": vols, "volumeMounts": mounts}))

    r.write_current_config()
    r.safety_assertions()
    rci, _ = r.tf("u1-init-upgrade", "init", "-upgrade", "-backend=false", "-input=false", "-no-color", offline=False)
    r.check(sc, "current module: init -upgrade succeeded", rci == 0, "rc=%d" % rci)
    _, out = r.tf("u1-version", "version", "-json")
    try:
        got = json.loads(out)["provider_selections"].get("registry.terraform.io/hashicorp/google-beta")
    except Exception:
        got = None
    r.check(sc, "current module: google-beta %s selected" % a.provider_version, got == a.provider_version, "selected=%r" % got)
    # Opted out, the current module must take over the old service unchanged.
    sco = sc + ": tmp_volume_config.enable = false"
    noop_checks(r, sco, "u1-optout", *OPT_OUT)
    tmp_checks(r, sco, enabled=False)

    # Default: the intended, controlled difference (one in-place update).
    tmp_rollout_checks(r, sc + ": default 10 GiB DISK /tmp added", "u1-tmp", True)

    # A normal migration still works on the upgraded service and keeps /tmp.
    image = "fleetdm/fleet:v4.94.0"
    sci = sc + ": first image upgrade"
    scenario_upgrade(r, image=image, sc=sci, label="u1-image")
    tmp_checks(r, sci, enabled=True)

    # Opting out later removes both blocks again, also in place, no migration.
    tmp_rollout_checks(r, sc + ": /tmp turned off again", "u1-tmp-off", False, "-var", "image=" + image, *OPT_OUT)


SCENARIOS = [
    ("s1", scenario_fresh),
    ("s2", scenario_env_change),
    ("s3", scenario_upgrade),
    ("s4", lambda r: scenario_job_fail(r, "lro_error", "fleetdm/fleet:v4.95.0", "S4 job failure shape 1 (LRO done.error)", "s4", True)),
    ("s5", lambda r: scenario_job_fail(r, "terminal_failed", "fleetdm/fleet:v4.96.0", "S5 job failure shape 2 (LRO done.response, terminal FAILED)", "s5", False)),
    ("s5b", lambda r: scenario_job_fail(r, "exec_failed_job_ready", "fleetdm/fleet:v4.96.1", "S5b execution FAILED while the Job reports Ready", "s5b", False)),
    ("s6", lambda r: scenario_job_fail(r, "lro_error_reconciling", "fleetdm/fleet:v4.97.0", "S6 shape 1 with job not marked FAILED (failed execution => new job)", "s6", True)),
    ("s7a", lambda r: scenario_rollout_fail(r, "lro_error", "fleetdm/fleet:v4.98.0", "S7a rollout failure (service LRO error)", "s7a")),
    ("s7b", lambda r: scenario_rollout_fail(r, "response_failed", "fleetdm/fleet:v4.99.0", "S7b rollout failure (LRO ok, revision not Ready)", "s7b")),
    ("s8", scenario_tag_removed),
    ("s9", scenario_tag_blocks),
    ("s10", scenario_db_replace),
    ("s11", scenario_proven_job_deleted),
    ("s11b", scenario_proven_job_recreated_unsettled_restore),
    ("s13", scenario_restore_lro_error),
    ("s14", scenario_image_contract),
    ("s15a", lambda r: scenario_restore_settlement(r, "lag_success", "fleetdm/fleet:v5.1.0", "s15a", True)),
    ("s15b", lambda r: scenario_restore_settlement(r, "pending", "fleetdm/fleet:v5.1.1", "s15b", False)),
    ("s15c", lambda r: scenario_restore_settlement(r, "cp_failed", "fleetdm/fleet:v5.1.2", "s15c", False)),
    ("s16", scenario_fresh_stop_fresh_drain),
    ("s18", scenario_transient_restore_settles),
    ("s19", scenario_marker_repair),
    ("s20", scenario_cross_identity_running),
    ("s21", scenario_neg_cbd_tainted_completed),
    ("s21b", scenario_neg_cbd_failed_then_rollout),
    ("s12", scenario_hard_kill),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider-version", default="7.24.0")
    ap.add_argument("--terraform", default="terraform")
    ap.add_argument("--only", default="")
    ap.add_argument("--upgrade-from-ref", default="",
                    help="git ref of the previous fixture and fleet-lifecycle module; runs only U1")
    ap.add_argument("--upgrade-from-provider-version", default="",
                    help="google-beta version used with --upgrade-from-ref")
    args = ap.parse_args()
    if bool(args.upgrade_from_ref) != bool(args.upgrade_from_provider_version):
        ap.error("--upgrade-from-ref and --upgrade-from-provider-version go together")
    if args.upgrade_from_ref and args.only:
        ap.error("--only does not apply to the upgrade scenario")
    r = Runner(args)
    r.log("artifacts: " + r.art)
    rc, _ = r.tf("init", "init", "-backend=false", "-input=false", "-no-color", offline=False)
    if rc != 0:
        sys.exit("init failed")
    r.safety_assertions()
    r.start_fake()
    try:
        only = set(filter(None, args.only.split(",")))
        unknown = only - {k for k, _ in SCENARIOS}
        if unknown:
            r.check("runner", "unknown scenario selection %s" % sorted(unknown), False)
        scenarios = [("u1", scenario_provider_upgrade)] if args.upgrade_from_ref else SCENARIOS
        for key, fn in scenarios:
            if only and key not in only:
                continue
            r.log("=== %s" % key)
            try:
                fn(r)
            except Exception as e:  # keep going; record
                import traceback
                r.check(key, "scenario raised", False, traceback.format_exc()[-800:])
    finally:
        with open(os.path.join(r.art, "all_events.json"), "w") as f:
            json.dump(r.get("/_events"), f, indent=1)
        r.stop_fake()
        with open(os.path.join(r.art, "results.json"), "w") as f:
            json.dump(r.results, f, indent=1)
        npass = sum(x["pass"] for x in r.results)
        lines = ["# Integration results (%s)" % os.path.basename(r.art), "",
                 "terraform %s, google-beta %s%s, terracurl 1.2.2, time 0.14.2; loopback fake API, fake token." % (
                     r.tf_version(), args.provider_version,
                     " (state first written by %s with google-beta %s)" % (args.upgrade_from_ref, args.upgrade_from_provider_version)
                     if args.upgrade_from_ref else ""),
                 "", "%d/%d checks passed" % (npass, len(r.results)), ""]
        cur = None
        for x in r.results:
            if x["scenario"] != cur:
                cur = x["scenario"]
                lines += ["", "## " + cur]
            lines.append("- [%s] %s %s" % ("PASS" if x["pass"] else "FAIL", x["check"], ("— " + x["detail"]) if not x["pass"] and x["detail"] else ""))
        open(os.path.join(r.art, "SUMMARY.md"), "w").write("\n".join(lines) + "\n")
        r.log("%d/%d checks passed; summary: %s" % (npass, len(r.results), os.path.join(r.art, "SUMMARY.md")))
        failed = len(r.results) - npass
        # remove the fixture's terraform working data except state/logs (keep artifacts small)
        shutil.rmtree(os.path.join(r.work, ".terraform"), ignore_errors=True)
    if not r.results:
        sys.exit("no checks were executed (empty or invalid --only selection)")
    if failed:
        sys.exit("%d check(s) failed" % failed)


if __name__ == "__main__":
    main()
