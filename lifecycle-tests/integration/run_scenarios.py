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
  python3 -I run_scenarios.py --provider-version 6.50.0 [--terraform terraform] [--only s1,s2]
Artifacts: lifecycle-tests/integration/artifacts/<run-id>/ (logs, events, results.json, SUMMARY.md)
"""
import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "fake-loopback-token-not-a-credential"
PARENT = "projects/fictional-proj/locations/us-central1"
SVC = PARENT + "/services/fleet-api"
MOD = "module.lifecycle"


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
        self.art = os.path.join(HERE, "artifacts", rid)
        self.work = os.path.join(self.art, "work")
        os.makedirs(self.work)
        shutil.copy(os.path.join(HERE, "fixture", "main.tf"), self.work)
        # the fixture's module source is relative to fixture/; rewrite for work/
        mod_abs = os.path.normpath(os.path.join(HERE, "..", "..", "gcp", "byo-project", "modules", "fleet-lifecycle"))
        p = os.path.join(self.work, "main.tf")
        src = open(p).read().replace('"../../../gcp/byo-project/modules/fleet-lifecycle"', json.dumps(mod_abs))
        open(p, "w").write(src)
        with open(os.path.join(self.work, "providers_pin.tf"), "w") as f:
            f.write('terraform {\n  required_providers {\n'
                    '    google-beta = { source = "hashicorp/google-beta", version = "%s" }\n'
                    '    terracurl   = { source = "devops-rob/terracurl", version = "1.2.2" }\n'
                    '    time        = { source = "hashicorp/time", version = "0.14.2" }\n'
                    '  }\n}\n' % args.provider_version)
        self.port = free_port()
        self.step = 0
        self.results = []
        self.fake = None

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
    ok_inv, pos_inv = ordered(evs, k("executions_listed", job="-"), k("job_created"))
    r.check(sc, "execution inventory (jobs/-/executions) read before the job", ok_inv, "pos=%s" % pos_inv)
    r.check(sc, "no unexpected job PATCH", not any(e["kind"] == "job_updated_UNEXPECTED" for e in evs))


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


def planned_resource_actions(r, label, *extra):
    rc, _ = r.tf("%s-plan" % label, "plan", "-no-color", "-out=%s.tfplan" % label, *extra)
    rcj, js = r.tf("%s-plan-show" % label, "show", "-json", "%s.tfplan" % label)
    try:
        plan = json.loads(js)
        acts = {c["address"]: c["change"]["actions"] for c in plan.get("resource_changes", [])
                if c["change"]["actions"] not in (["no-op"], ["read"])}
    except Exception as e:
        acts = {"error": str(e)}
    return rc, acts


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
    s0 = r.seq()
    rc, _ = r.apply("%s-upgrade" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-upgrade" % label, evs)
    r.check(sc, "apply succeeded", rc == 0)
    migration_flow_checks(r, sc, evs, image, existing=True)
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
    r.control(restore_settle_outcomes=["pending_then_settle"], restore_settle_reads=3)
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
        r.check(sc, "control plane was pending on several successive reads before it settled",
                len(pending) >= 3 and pending[0]["details"]["observedGeneration"] != pending[0]["details"]["generation"],
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
    r.control(restore_settle_outcomes=[], restore_settle_reads=3)
    noop_checks(r, sc, "s18", "-var", "image=" + image)


def scenario_fresh_stop_fresh_drain(r):
    sc = "S16 re-sent stop (same attempt, tainted same-name job, Fleet restarted out of band) gets a NEW drain"
    image = "fleetdm/fleet:v5.2.0"
    drain = 2  # fixture default drain_seconds
    r.control(job_outcomes=["lro_error_reconciling"])
    s0 = r.seq()
    rc, out = r.apply("s16-fail", "-var", "image=" + image)
    r.save_events("s16-fail", r.events_since(s0))
    r.check(sc, "first apply: drain completed, job failed and is tainted",
            rc != 0 and "time_sleep.drain[0]: Creation complete" in out
            and "(tainted)" in r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD), "rc=%d" % rc)
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


def guard_block_then_retry(r, sc, label, image, setup, release, expect_text, earlier_job):
    setup()
    s0 = r.seq()
    rc, out = r.apply("%s-blocked" % label, "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("%s-blocked" % label, evs)
    r.check(sc, "apply blocked with a clear message before any stop/job",
            rc != 0 and "Refusing to start a new Fleet migration" in flat(out) and expect_text in flat(out)
            and not any(masked("MANUAL")(e) for e in evs) and not any(e["kind"] in ("job_created", "execution_started") for e in evs),
            "rc=%d" % rc)
    # A new identity's guard is read during apply; Terraform may already have
    # deleted the PREVIOUS identity's (completed, managed) job as the first
    # half of the job replacement. The earlier active job is never touched.
    deleted = [e["details"]["job"] for e in evs if e["kind"] == "job_deleted"]
    r.check(sc, "the earlier active job is not deleted or modified by the guard",
            not any(d.endswith("/jobs/" + earlier_job) for d in deleted)
            and "/jobs/" + earlier_job in json.dumps(list(r.get("/_state")["jobs"].keys())), json.dumps(deleted))
    s1 = r.seq()
    rc1, out1 = r.apply("%s-still-blocked" % label, "-var", "image=" + image)
    evs1 = r.events_since(s1)
    r.save_events("%s-still-blocked" % label, evs1)
    r.check(sc, "plain re-apply while still active: blocked at PLAN, no writes",
            rc1 != 0 and "Refusing to start a new Fleet migration" in flat(out1) and not writes(evs1), "rc=%d" % rc1)
    release()
    s2 = r.seq()
    rc2, _ = r.apply("%s-retry" % label, "-var", "image=" + image)
    evs2 = r.events_since(s2)
    r.save_events("%s-retry" % label, evs2)
    r.check(sc, "plain re-apply after the earlier execution finished: exactly one migration, restored",
            rc2 == 0 and sum(e["kind"] == "execution_started" for e in evs2) == 1 and any(masked("AUTOMATIC")(e) for e in evs2), "rc=%d" % rc2)
    noop_checks(r, sc, label, "-var", "image=" + image)


def scenario_earlier_executions(r):
    base = "S17 earlier migration executions guard"
    # an unrelated job keeps running throughout: never blocks
    r.inject(action="add_execution", parent=PARENT, job="nightly-report", execution="nightly-report-1", active=True, create_job=True)
    r.inject(action="add_execution", parent=PARENT, job="fleet-migrations-report", execution="fmr-1", active=True, create_job=True)

    guard_block_then_retry(
        r, base + " / legacy fleet-migration execution active", "s17a", "fleetdm/fleet:v5.3.0",
        lambda: r.inject(action="add_execution", parent=PARENT, job="fleet-migration", execution="fleet-migration-legacy1",
                         active=True, create_job=True, job_field="short"),
        lambda: r.inject(action="complete_execution", execution="fleet-migration-legacy1"),
        "fleet-migration-legacy1", "fleet-migration")
    guard_block_then_retry(
        r, base + " / prior-identity orphan job active (full Execution.job)", "s17b", "fleetdm/fleet:v5.3.1",
        lambda: r.inject(action="add_execution", parent=PARENT, job="fleet-migrate-0123456789ab", execution="fleet-migrate-0123456789ab-r1",
                         active=True, create_job=True, job_field="full",
                         labels={"fleetdm-lifecycle-identity": "0123456789ab"}),
        lambda: r.inject(action="complete_execution", execution="fleet-migrate-0123456789ab-r1"),
        "fleet-migrate-0123456789ab-r1", "fleet-migrate-0123456789ab")

    def older_active():
        r.inject(action="add_execution", parent=PARENT, job="fleet-migrate-fedcba987654", execution="fleet-migrate-fedcba987654-a-old",
                 active=True, create_job=True, job_field="absent")
        r.inject(action="add_execution", parent=PARENT, job="fleet-migrate-fedcba987654", execution="fleet-migrate-fedcba987654-b-new",
                 active=False, job_field="absent")
    guard_block_then_retry(
        r, base + " / older execution active, newer completed (Execution.job omitted)", "s17c", "fleetdm/fleet:v5.3.2",
        older_active, lambda: r.inject(action="complete_execution", execution="fleet-migrate-fedcba987654-a-old"),
        "fleet-migrate-fedcba987654-a-old", "fleet-migrate-fedcba987654")

    # current job: LRO error while its execution keeps running (tainted job)
    sc = base + " / current tainted job with a still-active execution"
    image = "fleetdm/fleet:v5.3.3"
    r.control(job_outcomes=["lro_error_active"])
    s0 = r.seq()
    rc, out = r.apply("s17d-fail", "-var", "image=" + image)
    r.save_events("s17d-fail", r.events_since(s0))
    r.check(sc, "job create fails, job tainted, its execution still active",
            rc != 0 and "(tainted)" in r.state_show("%s.google_cloud_run_v2_job.migration[0]" % MOD)
            and any("completionTime" not in e for e in r.get("/_state")["executions"].values()), "rc=%d" % rc)
    s1 = r.seq()
    rc1, out1 = r.apply("s17d-blocked", "-var", "image=" + image)
    evs1 = r.events_since(s1)
    r.save_events("s17d-blocked", evs1)
    r.check(sc, "plain re-apply blocked at PLAN: the tainted job is NOT deleted, nothing written",
            rc1 != 0 and "Refusing to start a new Fleet migration" in flat(out1) and not writes(evs1)
            and not any(e["kind"] == "job_deleted" for e in evs1), "rc=%d" % rc1)
    r.inject(action="complete_execution", all=True)
    # the unrelated executions were completed too; restart one so it stays active
    r.inject(action="add_execution", parent=PARENT, job="nightly-report", execution="nightly-report-2", active=True)
    s2 = r.seq()
    rc2, _ = r.apply("s17d-retry", "-var", "image=" + image)
    evs2 = r.events_since(s2)
    r.save_events("s17d-retry", evs2)
    ok, pos = ordered(evs2, k("job_deleted"), k("job_created"), k("execution_finished", outcome="success"), masked("AUTOMATIC"))
    r.check(sc, "after it finished: tainted job replaced, exactly one new execution, restored",
            rc2 == 0 and ok and sum(e["kind"] == "execution_started" for e in evs2) == 1, "rc=%d pos=%s" % (rc2, pos))
    noop_checks(r, sc, "s17d", "-var", "image=" + image)

    # inventory that cannot be trusted
    for mode, text, image in (("truncated", "more than one page", "fleetdm/fleet:v5.3.4"),
                              ("malformed", "not a parsable 200 list", "fleetdm/fleet:v5.3.4"),
                              ("forbidden", "403", "fleetdm/fleet:v5.3.4")):
        sc = base + " / inventory %s" % mode
        r.control(executions_list_mode=mode)
        s0 = r.seq()
        rc, out = r.apply("s17e-%s" % mode, "-var", "image=" + image)
        evs = r.events_since(s0)
        r.save_events("s17e-%s" % mode, evs)
        r.check(sc, "never treated as an empty inventory: blocked before any stop/job",
                rc != 0 and text in flat(out) and not any(masked("MANUAL")(e) for e in evs)
                and not any(e["kind"] in ("job_created", "execution_started") for e in evs), "rc=%d" % rc)
    r.control(executions_list_mode="ok")
    sc = base + " / inventory valid again"
    s0 = r.seq()
    rc, _ = r.apply("s17e-ok", "-var", "image=fleetdm/fleet:v5.3.4")
    evs = r.events_since(s0)
    r.save_events("s17e-ok", evs)
    r.check(sc, "one migration, restored (unrelated active jobs never block)",
            rc == 0 and sum(e["kind"] == "execution_started" for e in evs) == 1 and any(masked("AUTOMATIC")(e) for e in evs), "rc=%d" % rc)
    noop_checks(r, sc, "s17e", "-var", "image=fleetdm/fleet:v5.3.4")


def scenario_replace_succeeded_unproven_job(r):
    sc = "S7c same-name replacement of a SUCCEEDED job of an unproven identity is guarded"
    image = "fleetdm/fleet:v5.4.0"
    r.control(rollout_outcomes=["response_failed"])
    s0 = r.seq()
    rc, _ = r.apply("s7c-rollout-fail", "-var", "image=" + image)
    evs = r.events_since(s0)
    r.save_events("s7c-rollout-fail", evs)
    job = [e["details"]["job"] for e in evs if e["kind"] == "job_created"]
    r.check(sc, "setup: migration succeeded, rollout failed, identity unproven (Fleet MANUAL)",
            rc != 0 and sum(e["kind"] == "execution_finished" and e["details"]["outcome"] == "success" for e in evs) == 1
            and r.get("/_state")["services"][SVC]["scaling"].get("scalingMode") == "MANUAL", "rc=%d" % rc)
    r.inject(action="add_execution", parent=PARENT, job="fleet-migrate-aaaaaaaaaaaa", execution="fleet-migrate-aaaaaaaaaaaa-r9",
             active=True, create_job=True, job_field="short")
    s1 = r.seq()
    rc1, out1 = r.tf("s7c-replace-job", "apply", "-auto-approve", "-no-color", "-var", "image=" + image,
                     "-replace=%s.google_cloud_run_v2_job.migration[0]" % MOD)
    evs1 = r.events_since(s1)
    r.save_events("s7c-replace-job", evs1)
    r.check(sc, "-replace of the succeeded job blocked at PLAN: no DELETE, no new execution, nothing written",
            rc1 != 0 and "Refusing to start a new Fleet migration" in flat(out1) and "fleet-migrate-aaaaaaaaaaaa-r9" in flat(out1)
            and not writes(evs1) and job and job[0] in r.get("/_state")["jobs"], "rc=%d" % rc1)
    s2 = r.seq()
    rc2, out2 = r.apply("s7c-plain-blocked", "-var", "image=" + image)
    evs2 = r.events_since(s2)
    r.save_events("s7c-plain-blocked", evs2)
    r.check(sc, "plain rollout retry also blocked while the orphan is active (no writes)",
            rc2 != 0 and "Refusing to start a new Fleet migration" in flat(out2) and not writes(evs2), "rc=%d" % rc2)
    r.inject(action="complete_execution", execution="fleet-migrate-aaaaaaaaaaaa-r9")
    s3 = r.seq()
    rc3, _ = r.apply("s7c-retry", "-var", "image=" + image)
    evs3 = r.events_since(s3)
    r.save_events("s7c-retry", evs3)
    r.check(sc, "after it finished: plain retry redeploys and restores without a migration",
            rc3 == 0 and any(e["kind"] == "revision_created" and e["details"]["outcome"] == "ready" for e in evs3)
            and any(masked("AUTOMATIC")(e) for e in evs3), "rc=%d" % rc3)
    no_migration_checks(r, sc, evs3)
    noop_checks(r, sc, "s7c", "-var", "image=" + image)


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


SCENARIOS = [
    ("s1", scenario_fresh),
    ("s2", scenario_env_change),
    ("s3", scenario_upgrade),
    ("s4", lambda r: scenario_job_fail(r, "lro_error", "fleetdm/fleet:v4.95.0", "S4 job failure shape 1 (LRO done.error)", "s4", True)),
    ("s5", lambda r: scenario_job_fail(r, "terminal_failed", "fleetdm/fleet:v4.96.0", "S5 job failure shape 2 (LRO done.response, terminal FAILED)", "s5", False)),
    ("s6", lambda r: scenario_job_fail(r, "lro_error_reconciling", "fleetdm/fleet:v4.97.0", "S6 shape 1 with job not marked FAILED (same-name tainted retry)", "s6", True)),
    ("s7a", lambda r: scenario_rollout_fail(r, "lro_error", "fleetdm/fleet:v4.98.0", "S7a rollout failure (service LRO error)", "s7a")),
    ("s7b", lambda r: scenario_rollout_fail(r, "response_failed", "fleetdm/fleet:v4.99.0", "S7b rollout failure (LRO ok, revision not Ready)", "s7b")),
    ("s7c", scenario_replace_succeeded_unproven_job),
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
    ("s17", scenario_earlier_executions),
    ("s18", scenario_transient_restore_settles),
    ("s12", scenario_hard_kill),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider-version", default="6.50.0")
    ap.add_argument("--terraform", default="terraform")
    ap.add_argument("--only", default="")
    args = ap.parse_args()
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
        for key, fn in SCENARIOS:
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
                 "terraform %s, google-beta %s, terracurl 1.2.2, time 0.14.2; loopback fake API, fake token." % (r.tf_version(), args.provider_version),
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
