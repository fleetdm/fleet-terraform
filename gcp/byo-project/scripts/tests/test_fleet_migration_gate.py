"""Offline unit tests for fleet_migration_gate.py.

Run from the repository root (stdlib only, no credentials, no network):

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s gcp/byo-project/scripts/tests -v

Every test injects a fake transport, token source and clock. Real network
access, subprocesses and the gcloud CLI are blocked for the whole run, so an
unmatched call fails the test instead of reaching Google.
"""

import copy
import json
import math
import os
import socket
import subprocess
import sys
import unittest
import urllib.request
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import fake_gcp as fg  # noqa: E402
import fleet_migration_gate as gate  # noqa: E402


def _blocked(*args, **kwargs):
    raise AssertionError("real network/subprocess access attempted in an offline test")


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        for target in (
            "urllib.request.urlopen",
            "subprocess.run",
            "subprocess.Popen",
            "socket.create_connection",
            "socket.socket.connect",
            "shutil.which",
        ):
            patcher = mock.patch(target, side_effect=_blocked)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.cloud = fg.FakeCloud()
        self.logs = []

    def run_gate(self, environ=None, argv=("run",)):
        token = fg.FakeToken()
        code = gate.main(
            argv=list(argv),
            environ=environ or fg.env(),
            transport=self.cloud,
            token_source=token,
            clock=self.cloud.clock,
            log=self.logs.append,
        )
        self.assert_no_leaks()
        self.assertEqual(self.cloud.violations, [], "fake safety invariants (no overlapping :run, no early resume)")
        return code

    def assert_no_leaks(self):
        text = "\n".join(self.logs)
        self.assertNotIn(fg.TOKEN, text)
        self.assertNotIn("Bearer", text)
        self.assertNotIn(fg.SECRET_ENV_VALUE, text)
        self.assertNotIn("FLEET_LICENSE_KEY", text)
        for _, _, body in self.cloud.bodies:
            raw = (body or {}).get("annotations", {}).get(fg.CHECKPOINT)
            if raw:
                self.assertNotIn(fg.SECRET_ENV_VALUE, raw)
                self.assertNotIn(fg.TOKEN, raw)

    def text(self):
        return "\n".join(self.logs)

    # Outcome assertions ------------------------------------------------------

    def assert_no_writes(self):
        self.assertEqual(self.cloud.writes(), [])

    def assert_not_run(self):
        self.assertEqual(self.cloud.run_calls(), 0)

    def assert_not_resumed(self):
        """No new-image write and no scaling restore happened."""
        for body in self.cloud.service_patches():
            self.assertEqual(body["template"]["containers"][0]["image"], fg.OLD_IMAGE,
                             "the new image must not be deployed")
            scaling = body.get("scaling", {})
            self.assertEqual(scaling.get("scalingMode"), "MANUAL", "scaling must never leave MANUAL/0")
            self.assertEqual(scaling.get("manualInstanceCount"), 0)
        if self.cloud.service is not None:
            self.assertEqual(self.cloud.service["scaling"].get("scalingMode"), "MANUAL")
            self.assertEqual(self.cloud.service["scaling"].get("manualInstanceCount"), 0)

    def assert_not_claimed_measured_zero(self):
        self.assertNotIn(gate.FLEET_MEASURED_ZERO, self.text())

    def assert_no_old_image_restart(self):
        for body in self.cloud.service_patches():
            scaling = body.get("scaling", {})
            if scaling.get("scalingMode") != "MANUAL":
                self.assertEqual(body["template"]["containers"][0]["image"], fg.NEW_IMAGE)


# ---------------------------------------------------------------------------
# Positive protocol
# ---------------------------------------------------------------------------


class UpgradeHappyPath(OfflineTestCase):
    def test_verified_zero_single_job_new_image_then_resume(self):
        c = self.cloud
        self.assertEqual(self.run_gate(), 0, self.text())
        writes = c.writes()
        self.assertEqual(writes, [
            ("PATCH", "job"),      # job ownership claim (fences older :run etags)
            ("PATCH", "service"),  # stop + checkpoint (atomic)
            ("PATCH", "service"),  # phase migrating
            ("POST", "run"),       # exactly one execution
            ("PATCH", "service"),  # phase migrated
            ("PATCH", "service"),  # new image while MANUAL/0
            ("PATCH", "service"),  # restore pre-migration scaling
        ])
        patches = c.service_patches()
        stop, migrating, migrated, image, restore = patches
        self.assertEqual(stop["scaling"], {"scalingMode": "MANUAL", "manualInstanceCount": 0, "minInstanceCount": 0})
        self.assertEqual(stop["template"]["containers"][0]["image"], fg.OLD_IMAGE)
        cp = json.loads(stop["annotations"][fg.CHECKPOINT])
        self.assertEqual(cp["phase"], "stopped")
        self.assertEqual(cp["run"], fg.RUN_ID)
        self.assertEqual(cp["pre_scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1, "maxInstanceCount": 0})
        self.assertEqual(stop["annotations"]["example.com/owner"], "platform-team",
                         "other annotations must be preserved")
        self.assertEqual(json.loads(migrating["annotations"][fg.CHECKPOINT])["phase"], "migrating")
        self.assertEqual(json.loads(migrated["annotations"][fg.CHECKPOINT])["phase"], "migrated")
        # New image is deployed while still MANUAL/0, before any restore.
        self.assertEqual(image["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertEqual(image["scaling"]["scalingMode"], "MANUAL")
        self.assertEqual(image["scaling"]["manualInstanceCount"], 0)
        self.assertEqual(image["template"]["containers"][0]["env"], stop["template"]["containers"][0]["env"],
                         "only the image changes in the gate's template write")
        self.assertEqual(restore["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
        self.assertEqual(json.loads(restore["annotations"][fg.CHECKPOINT])["phase"], "completed")
        # :run happened only after a monitoring read that proved zero.
        run_at = c.index("POST", "run")
        stop_at = c.index("PATCH", "service")
        monitoring_after_stop = [i for i, (m, k, _, q) in enumerate(c.log)
                                 if k == "monitoring" and stop_at < i < run_at]
        self.assertTrue(monitoring_after_stop)
        for i in monitoring_after_stop:
            start = fg.parse_ts(c.log[i][3]["interval.startTime"])
            self.assertGreater(start, c.stop_time, "telemetry window must start after the stop")
        self.assertEqual(len(c.executions), 1)
        self.assertEqual(c.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
        self.assertEqual(c.service["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        self.assert_no_old_image_restart()

    def test_generated_revision_name_is_preserved_on_metadata_writes_and_omitted_on_rollout(self):
        c = self.cloud
        original_template = json.loads(json.dumps(c.service["template"]))
        self.assertEqual(original_template["revision"], "fleet-api-00002-bbb")
        self.assertEqual(self.run_gate(), 0, self.text())
        stop, migrating, migrated, image, restore = c.service_patches()
        for body in (stop, migrating, migrated):
            self.assertEqual(body["template"], original_template, "metadata/scaling writes resend the template as read")
        self.assertNotIn("revision", image["template"], "the new-image write must let Google name the revision")
        self.assertEqual(image["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        new_rev = c.service["latestReadyRevision"].rsplit("/", 1)[-1]
        self.assertNotEqual(new_rev, "fleet-api-00002-bbb")
        self.assertEqual(c.service["template"]["revision"], new_rev)
        self.assertEqual(restore["template"]["revision"], new_rev)
        self.assertEqual(c.service["trafficStatuses"], [{"type": fg.LATEST, "percent": 100, "revision": new_rev}])

    def test_service_without_reflected_revision_name(self):
        self.cloud.service["template"].pop("revision")
        self.cloud.reflect_revision_name = False
        self.assertEqual(self.run_gate(), 0, self.text())
        image = self.cloud.service_patches()[3]
        self.assertNotIn("revision", image["template"])

    def test_fake_rejects_reusing_an_existing_revision_name(self):
        # Guards the regression above: the fake enforces immutable names.
        c = self.cloud
        body = {k: v for k, v in json.loads(json.dumps(c.service)).items() if k not in fg.SERVICE_OUTPUT_ONLY}
        body["template"]["containers"][0]["image"] = fg.NEW_IMAGE
        resp = c.request("PATCH", "https://run.googleapis.com/v2/" + fg.SVC_NAME,
                         {"Authorization": "Bearer " + fg.TOKEN}, json.dumps(body).encode())
        self.assertEqual(resp.status, 409)

    def test_run_uses_job_etag_and_is_single_attempt(self):
        self.assertEqual(self.run_gate(), 0, self.text())
        runs = [b for (m, k, b) in self.cloud.bodies if k == "run"]
        self.assertEqual(runs, [{"etag": self.cloud.job["etag"]}])

    def test_draining_instances_then_zero_is_accepted(self):
        self.cloud.drain = 150
        self.assertEqual(self.run_gate(), 0, self.text())

    def test_manual_prescaling_is_restored_exactly(self):
        self.cloud.service["scaling"] = {"scalingMode": "MANUAL", "manualInstanceCount": 3, "maxInstanceCount": 4}
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(self.cloud.service["scaling"],
                         {"scalingMode": "MANUAL", "manualInstanceCount": 3, "maxInstanceCount": 4})

    def test_previous_completed_checkpoint_allows_a_new_run(self):
        self.cloud.service["annotations"][fg.CHECKPOINT] = json.dumps(
            {"v": 1, "run": "older-run", "phase": "completed", "pre_scaling": None})
        self.assertEqual(self.run_gate(), 0, self.text())

    def test_token_refresh_on_401_for_reads(self):
        state = {"n": 0}

        def once_401(method, kind, path, query, body):
            if method == "GET" and kind == "job" and state["n"] == 0:
                state["n"] += 1
                return fg.error(401, "UNAUTHENTICATED")
            return None

        self.cloud.faults.append(once_401)
        self.assertEqual(self.run_gate(), 0, self.text())


class BootstrapHappyPath(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.cloud = fg.FakeCloud(service=False)

    def test_fresh_bootstrap_runs_once_and_records_ownership_on_job(self):
        c = self.cloud
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("POST", "run"), ("PATCH", "job")])
        self.assertEqual(c.service_patches(), [])
        cp = json.loads(c.job["annotations"][fg.CHECKPOINT])
        self.assertEqual(cp["phase"], "completed")
        self.assertGreater(c.index("POST", "run"), c.index("GET", "service-list"))


# ---------------------------------------------------------------------------
# Preflight refusals: nothing is written, Fleet is untouched
# ---------------------------------------------------------------------------


def svc_mutation(fn):
    def apply(test):
        fn(test.cloud.service)
    return apply


def job_mutation(fn):
    def apply(test):
        fn(test.cloud.job)
    return apply


PREFLIGHT_CASES = {
    "service_reconciling": svc_mutation(lambda s: s.update(reconciling=True)),
    "service_generation_not_observed": svc_mutation(lambda s: s.update(observedGeneration="6")),
    "service_terminal_failed": svc_mutation(lambda s: s.update(terminalCondition={"state": "CONDITION_FAILED"})),
    "traffic_tag": svc_mutation(lambda s: s["traffic"].append({"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION",
                                                                "revision": "fleet-api-00001-aaa", "tag": "old"})),
    "tag_only_traffic_status": svc_mutation(lambda s: s["trafficStatuses"].append(
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00001-aaa", "tag": "x",
         "uri": "https://x---fleet-api"})),
    "traffic_pinned_to_revision": svc_mutation(lambda s: s.update(traffic=[
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00002-bbb", "percent": 100}])),
    "traffic_split": svc_mutation(lambda s: s.update(trafficStatuses=[
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00001-aaa", "percent": 50},
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00002-bbb", "percent": 50}])),
    "template_revision_malformed": svc_mutation(lambda s: s["template"].update(revision=5)),
    "two_containers": svc_mutation(lambda s: s["template"]["containers"].append({"image": "sidecar"})),
    "latest_created_not_ready": svc_mutation(lambda s: s.update(
        latestCreatedRevision=fg.SVC_NAME + "/revisions/fleet-api-00003-ccc")),
    "already_manual_zero_without_checkpoint": svc_mutation(lambda s: s.update(
        scaling={"scalingMode": "MANUAL", "manualInstanceCount": 0})),
    "manual_without_explicit_count": svc_mutation(lambda s: s.update(scaling={"scalingMode": "MANUAL"})),
    "unknown_scaling_field": svc_mutation(lambda s: s.update(scaling={"minInstanceCount": 1, "future": 1})),
    "service_without_etag": svc_mutation(lambda s: s.pop("etag")),
    "service_wrong_name": svc_mutation(lambda s: s.update(name=fg.LOC + "/services/other")),
    "job_old_image": job_mutation(lambda j: j["template"]["template"]["containers"][0].update(image=fg.OLD_IMAGE)),
    "job_max_retries_missing": job_mutation(lambda j: j["template"]["template"].pop("maxRetries")),
    "job_max_retries_three": job_mutation(lambda j: j["template"]["template"].update(maxRetries=3)),
    "job_two_tasks": job_mutation(lambda j: j["template"].update(taskCount=2)),
    "job_parallelism_missing": job_mutation(lambda j: j["template"].pop("parallelism")),
    "job_generation_mismatch": job_mutation(lambda j: j.update(generation="4", observedGeneration="4")),
    "job_reconciling": job_mutation(lambda j: j.update(reconciling=True)),
    "job_execution_token": job_mutation(lambda j: j.update(runExecutionToken="abc")),
    "job_bad_timeout": job_mutation(lambda j: j["template"]["template"].update(timeout="1h")),
    "unsettled_prior_execution": lambda t: t.cloud.add_prior_execution(settled=False),
    "old_revision_has_no_telemetry": lambda t: t.cloud.no_metrics_for.add("fleet-api-00001-aaa"),
    "telemetry_for_unknown_revision_without_coverage": lambda t: t.cloud.extra_series.append(
        fg.make_series("fleet-api-00000-zzz", "active", [fg.point(fg.START - 600, 0)])),
    "latest_revision_missing_from_listing": lambda t: t.cloud.revisions.pop(),
    "monitoring_forbidden": lambda t: t.cloud.faults.append(
        lambda m, k, p, q, b: fg.error(403, "PERMISSION_DENIED") if k == "monitoring" else None),
    "revisions_listing_partial": lambda t: t.cloud.faults.append(
        lambda m, k, p, q, b: fg.FakeResponse(200, {"revisions": [], "unreachable": ["x"]}) if k == "revisions" else None),
    "revisions_second_page_fails": lambda t: (t.cloud.revisions.insert(0, t.cloud._revision(
        "fleet-api-00000-del", fg.OLD_IMAGE, deleted=True)), t.cloud.faults.append(
        lambda m, k, p, q, b: fg.error(503, "UNAVAILABLE") if k == "revisions" and "pageToken" in q else None)),
    "missing_date_header": lambda t: t.cloud.faults.append(_no_date_for("job")),
    "unexpected_state_label_preflight": lambda t: t.cloud.extra_series.append(
        _series_with_state("fleet-api-00002-bbb", "starting", fg.START - 600)),
}


def _no_date_for(kind):
    def fault(method, k, path, query, body):
        if k == kind:
            resp = fg.FakeResponse(200, {})
            resp.no_date = True
            return resp
        return None
    return fault


def _series_with_state(rev, state, t):
    s = fg.make_series(rev, "active", [fg.point(t, 0)])
    s["metric"]["labels"]["state"] = state
    return s


class PreflightRefusals(OfflineTestCase):
    pass


def _make_preflight_test(name, setup):
    def test(self):
        setup(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assert_no_writes()
        self.assert_not_run()
        self.assertIn("Fleet service: " + gate.FLEET_UNCHANGED, self.text())
    test.__name__ = "test_refuses_" + name
    return test


for _name, _setup in PREFLIGHT_CASES.items():
    setattr(PreflightRefusals, "test_refuses_" + _name, _make_preflight_test(_name, _setup))


class ConfigurationRefusals(OfflineTestCase):
    def test_invalid_env_makes_no_requests(self):
        for key in fg.env():
            self.cloud.log.clear()
            self.logs.clear()
            self.assertEqual(self.run_gate(environ=fg.env(**{key: None})), 1)
            self.assertEqual(self.cloud.log, [])
        self.assertEqual(self.run_gate(environ=fg.env(FLEET_GATE_IMAGE="img; rm -rf /")), 1)
        self.assertEqual(self.cloud.log, [])

    def test_usage(self):
        self.assertEqual(self.run_gate(argv=()), 2)
        self.assertEqual(self.run_gate(argv=("run", "--force")), 2)
        self.assertEqual(self.cloud.log, [])

    def test_monitoring_error_message_is_not_echoed(self):
        PREFLIGHT_CASES["monitoring_forbidden"](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("PERMISSION_DENIED", self.text())


# ---------------------------------------------------------------------------
# Stop write failures
# ---------------------------------------------------------------------------


def _fail_nth_write(kind, nth, response):
    state = {"n": 0}

    def fault(method, k, path, query, body):
        if method != "GET" and k == kind:
            state["n"] += 1
            if state["n"] == nth:
                return response() if callable(response) else response
        return None
    return fault


class StopFailures(OfflineTestCase):
    def test_concurrent_writer_etag_conflict(self):
        self.cloud.faults.append(_fail_nth_write("service", 1, fg.error(409, "ABORTED")))
        self.assertEqual(self.run_gate(), 1)
        self.assert_not_run()
        self.assertIn("Fleet service: " + gate.FLEET_UNCHANGED, self.text())

    def test_ambiguous_stop_is_reverified_and_not_run(self):
        self.cloud.faults.append(_fail_nth_write("service", 1, fg.error(503, "UNAVAILABLE")))
        self.assertEqual(self.run_gate(), 1)
        self.assert_not_run()
        # The fake did not apply the write, so the report must not claim a stop.
        self.assertIn(gate.FLEET_NOT_STOPPED, self.text())

    def test_ambiguous_stop_that_was_applied_is_reported_stopped(self):
        c = self.cloud
        original = c._h_service

        def applied_then_503(method, k, path, query, body):
            if method == "PATCH" and k == "service" and c.stop_time is None:
                original(method, None, query, body)
                return fg.error(500, "INTERNAL")
            return None

        c.faults.append(applied_then_503)
        self.assertEqual(self.run_gate(), 1)
        self.assert_not_run()
        # Restart is disabled, but no actual zero was measured.
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_stop_operation_error(self):
        c = self.cloud
        original = c._new_op

        def failing_op(response, done_after=1, error=None, pending=None):
            return original(response, done_after, error={"code": 9}, pending=pending)

        c._new_op = failing_op
        self.assertEqual(self.run_gate(), 1)
        self.assert_not_run()


# ---------------------------------------------------------------------------
# Verified-zero failures: Fleet stays stopped, migration not run
# ---------------------------------------------------------------------------


def _override(fn):
    def apply(test):
        test.cloud.metric_override = fn
    return apply


def _set_override_after_stop(fn):
    def apply(test):
        c = test.cloud

        def override(rev, state, t, value):
            if c.stop_time is not None and t > c.stop_time:
                return fn(c, rev, state, t, value)
            return value
        c.metric_override = override
    return apply


def _hook(fn):
    def apply(test):
        test.cloud.series_hook = lambda series: fn(test.cloud, series)
    return apply


def _after_stop_fault(predicate, response):
    def apply(test):
        c = test.cloud

        def fault(method, k, path, query, body):
            if c.stop_time is not None and predicate(method, k, query):
                return response() if callable(response) else response
            return None
        c.faults.append(fault)
    return apply


def _mutate_service_after_stop(fn):
    """Mutate once, after the stop was confirmed (second service read)."""
    def apply(test):
        c = test.cloud
        state = {"reads": 0}

        def fault(method, k, path, query, body):
            if c.stop_time is not None and method == "GET" and k == "service":
                state["reads"] += 1
                if state["reads"] == 2:
                    fn(c)
            return None
        c.faults.append(fault)
    return apply


def _drop_state(state):
    def fn(c, series):
        if c.stop_time is None:
            return series
        out = []
        for s in series:
            if s["metric"]["labels"]["state"] == state:
                s = dict(s, points=[p for p in s["points"] if fg.parse_ts(p["interval"]["endTime"]) <= c.stop_time])
            out.append(s)
        return out
    return fn


def _asymmetric(c, series):
    if c.stop_time is None:
        return series
    for s in series:
        if s["metric"]["labels"]["state"] == "idle":
            for p in s["points"]:
                t = fg.parse_ts(p["interval"]["endTime"]) + 30
                p["interval"] = {"startTime": fg.ts(t), "endTime": fg.ts(t)}
    return series


def _start_before_fence(c, series):
    if c.stop_time is None:
        return series
    for s in series:
        for p in s["points"]:
            p["interval"]["startTime"] = fg.ts(c.stop_time - 1)
    return series


def _future_point(c, series):
    if c.stop_time is None:
        return series
    series.append(fg.make_series("fleet-api-00002-bbb", "active", [fg.point(c.now() + 3600, 0)]))
    return series


def _future_zeros(delta):
    """Zero points for every revision dated `delta` seconds after the HTTP
    Date (floor) of the very response that returns them; the real telemetry
    never reaches zero, so only the future points could "prove" a stop."""
    def apply(test):
        c = test.cloud

        def override(rev, state, t, value):
            if c.stop_time is not None and t > c.stop_time and state == "active":
                return 1
            return value
        c.metric_override = override

        def hook(cloud, series):
            if cloud.stop_time is None:
                return series
            t = math.floor(cloud.now()) + delta
            for r in cloud.revisions:
                rev = r["name"].rsplit("/", 1)[-1]
                for state in ("active", "idle"):
                    series.append(fg.make_series(rev, state, [fg.point(t, 0)]))
            return series
        c.series_hook = lambda series: hook(c, series)
    return apply


def _foreign_series(c, series):
    if c.stop_time is None:
        return series
    series.append(fg.make_series("fleet-api-00002-bbb", "idle", [fg.point(c.now() - 200, 0)], service_name="other"))
    return series


def _double_value(c, series):
    if c.stop_time is None:
        return series
    for s in series:
        for p in s["points"]:
            p["value"] = {"doubleValue": 0.0}
    return series


def _new_series_without_zero(c, series):
    if c.stop_time is None:
        return series
    series.append(fg.make_series("fleet-api-00009-zzz", "active", [fg.point(c.stop_time + 0.5, 1)]))
    return series


def _second_series_same_revision_missing(c, series):
    if c.stop_time is None:
        return series
    s = fg.make_series("fleet-api-00002-bbb", "active", [fg.point(c.stop_time - 30, 1)])
    s["metric"]["labels"]["container_name"] = "sidecar"
    series.append(s)
    return series


ZERO_CASES = {
    "old_revision_stops_emitting_after_stop": lambda t: t.cloud.no_metrics_after_stop_for.add("fleet-api-00001-aaa"),
    "serving_revision_stops_emitting_after_stop": lambda t: t.cloud.no_metrics_after_stop_for.add("fleet-api-00002-bbb"),
    "never_reaches_zero": _set_override_after_stop(lambda c, rev, state, t, v: 1 if state == "idle" else 0),
    "idle_only_zero_active_missing": _hook(_drop_state("active")),
    "active_only_zero_idle_missing": _hook(_drop_state("idle")),
    "asymmetric_timestamps": _hook(_asymmetric),
    "interval_starts_before_fence": _hook(_start_before_fence),
    "telemetry_partial_execution_errors": lambda t: setattr(
        t.cloud, "monitoring_extra", None) or _after_stop_fault(
        lambda m, k, q: k == "monitoring",
        lambda: fg.FakeResponse(200, {"timeSeries": [], "executionErrors": [{"code": 14}]}))(t),
    "telemetry_page_two_unavailable": _after_stop_fault(
        lambda m, k, q: k == "monitoring" and "pageToken" in q, lambda: fg.error(503, "UNAVAILABLE")),
    "telemetry_permission_denied_after_stop": _after_stop_fault(
        lambda m, k, q: k == "monitoring", lambda: fg.error(403, "PERMISSION_DENIED")),
    "telemetry_unparseable": _after_stop_fault(
        lambda m, k, q: k == "monitoring", lambda: fg.FakeResponse(200, raw=b"<html>")),
    "future_dated_point_clock_skew": _hook(_future_point),
    "future_zero_1s_after_response_date": _future_zeros(1),
    "future_zero_30s_after_response_date": _future_zeros(30),
    "future_zero_119s_after_response_date": _future_zeros(119),
    "zero_within_fraction_of_response_second_only": _future_zeros(0.5),
    "series_for_other_service": _hook(_foreign_series),
    "double_valued_points": _hook(_double_value),
    "unexpected_state_label": _hook(lambda c, s: s + ([_series_with_state("fleet-api-00002-bbb", "starting",
                                                                         c.now() - 200)] if c.stop_time else [])),
    "new_revision_in_telemetry_without_zero": _hook(_new_series_without_zero),
    "extra_series_for_revision_without_zero": _hook(_second_series_same_revision_missing),
}

def _zero_then_nonzero(c, series):
    """A coherent zero followed by a non-zero point in the same response."""
    if c.stop_time is None:
        return series
    s = c.stop_time
    series.append(fg.make_series("fleet-api-00002-bbb", "active", [fg.point(s + 20, 1), fg.point(s + 10, 0)]))
    series.append(fg.make_series("fleet-api-00002-bbb", "idle", [fg.point(s + 20, 0), fg.point(s + 10, 0)]))
    return series


ZERO_FATAL_CASES = {
    "instance_reappears_after_zero": _hook(_zero_then_nonzero),
}

ZERO_CHANGE_CASES = {
    "service_etag_changes": _mutate_service_after_stop(lambda c: c.service.update(etag='"svc-external"')),
    "service_generation_changes": _mutate_service_after_stop(
        lambda c: c.service.update(generation="99", observedGeneration="99")),
    "service_starts_reconciling": _mutate_service_after_stop(lambda c: c.service.update(reconciling=True)),
    "tag_added_while_stopped": _mutate_service_after_stop(lambda c: c.service["trafficStatuses"].append(
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00001-aaa", "tag": "t"})),
    "scaling_changed_by_admin": _mutate_service_after_stop(lambda c: c.service.update(scaling={"minInstanceCount": 1})),
    "checkpoint_removed": _mutate_service_after_stop(lambda c: c.service["annotations"].pop(fg.CHECKPOINT)),
    "revision_created_while_stopped": _mutate_service_after_stop(lambda c: c.revisions.append(
        c._revision("fleet-api-00042-zzz", fg.OLD_IMAGE, deleted=False))),
}

# The job (not the service) changes after the zero proof: the gate refuses to
# run, and the measured zero still describes the unchanged service.
PRE_RUN_JOB_CHANGE_CASES = {
    "job_changed_while_stopped": _mutate_service_after_stop(lambda c: c.job.update(etag='"job-external"')),
    "execution_started_by_someone_else": _mutate_service_after_stop(lambda c: c.add_prior_execution(settled=True)),
}


class VerifiedZeroFailures(OfflineTestCase):
    pass


def _make_zero_test(setup, expect_fleet=gate.FLEET_RESTART_DISABLED):
    def test(self):
        setup(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(self.cloud.count("PATCH", "service") >= 1, True, "the gate must have stopped Fleet")
        self.assert_not_run()
        if expect_fleet != gate.FLEET_MEASURED_ZERO:
            # No current complete measured zero exists in these scenarios.
            self.assert_not_claimed_measured_zero()
        self.assertIn("Migration: " + gate.MIGRATION_NOT_RUN, self.text())
        if expect_fleet:
            self.assertIn("Fleet service: " + expect_fleet, self.text())
        if self.cloud.service.get("scaling", {}).get("scalingMode") == "MANUAL":
            self.assert_not_resumed()
    return test


for _name, _setup in ZERO_CASES.items():
    setattr(VerifiedZeroFailures, "test_no_run_" + _name, _make_zero_test(_setup))
for _name, _setup in ZERO_FATAL_CASES.items():
    setattr(VerifiedZeroFailures, "test_no_run_" + _name, _make_zero_test(_setup))
for _name, _setup in ZERO_CHANGE_CASES.items():
    setattr(VerifiedZeroFailures, "test_no_run_" + _name, _make_zero_test(_setup, expect_fleet=None))
for _name, _setup in PRE_RUN_JOB_CHANGE_CASES.items():
    setattr(VerifiedZeroFailures, "test_no_run_" + _name, _make_zero_test(_setup, expect_fleet=gate.FLEET_MEASURED_ZERO))


class VerifiedZeroDetails(OfflineTestCase):
    def test_zero_wait_is_bounded(self):
        self.cloud.no_metrics_after_stop_for.add("fleet-api-00001-aaa")
        self.assertEqual(self.run_gate(), 1)
        elapsed = self.cloud.clock.t - fg.START
        self.assertLess(elapsed, gate.ZERO_TIMEOUT + 300)
        self.assertIn("no verified actual zero", self.text())

    def test_zero_timeout_output_does_not_claim_actual_stop(self):
        self.cloud.no_metrics_after_stop_for.add("fleet-api-00001-aaa")
        self.assertEqual(self.run_gate(), 1)
        text = self.text()
        self.assertIn("FAILED: no verified actual zero for every revision", text)
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, text)
        self.assertIn("actual instance zero is NOT verified", text)
        self.assertIn("Migration: " + gate.MIGRATION_NOT_RUN, text)
        self.assertNotIn(gate.FLEET_MEASURED_ZERO, text)
        self.assertNotIn("Fleet service: stopped", text)

    def test_missing_metrics_never_report_measured_zero(self):
        self.cloud.no_metrics_after_stop_for.update({"fleet-api-00001-aaa", "fleet-api-00002-bbb"})
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assertNotIn(gate.FLEET_MEASURED_ZERO, self.text())

    def test_future_zero_failure_is_reported_as_clock_anomaly(self):
        ZERO_CASES["future_zero_30s_after_response_date"](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("dated after the server's own response time", self.text())
        self.assert_not_run()

    def test_tag_added_while_stopped_is_not_reported_stopped(self):
        ZERO_CHANGE_CASES["tag_added_while_stopped"](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn(gate.FLEET_NOT_STOPPED, self.text())

    def test_admin_scaling_change_is_reported_not_stopped(self):
        ZERO_CHANGE_CASES["scaling_changed_by_admin"](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn(gate.FLEET_NOT_STOPPED, self.text())

    def test_new_instance_after_zero_is_fatal(self):
        ZERO_FATAL_CASES["instance_reappears_after_zero"](self)
        self.assertEqual(self.run_gate(), 1)
        self.assert_not_run()
        self.assertIn("reported instances after a verified zero", self.text())


# ---------------------------------------------------------------------------
# Pure telemetry analysis
# ---------------------------------------------------------------------------


class TelemetryAnalysis(unittest.TestCase):
    cfg = gate.Config(**{k: v for k, v in zip(gate.Config.ENV, [
        fg.PROJECT, fg.REGION, fg.SERVICE, fg.JOB, fg.NEW_IMAGE, fg.RUN_ID, fg.JOB_GENERATION, fg.TRIGGER])})
    N = gate.NANOS
    FENCE = 1_000_000 * N

    def series(self, rev, state, points):
        return fg.make_series(rev, state, [fg.point(t, v) for t, v in points])

    def analyze(self, series, required=("r1",), now=1_000_600, observed=None):
        observed = now if observed is None else observed
        return gate.analyze_zero(series, self.cfg, self.FENCE, now * self.N, observed * self.N, set(required))

    def zeros_at(self, t):
        return [self.series("r1", "active", [(t, 0)]), self.series("r1", "idle", [(t, 0)])]

    def test_future_zero_is_never_proof(self):
        for delta in (1, 30, 119, 120, 121, 3600):
            r = self.analyze(self.zeros_at(1_000_600 + delta))
            self.assertTrue(r.fatal, delta)
            self.assertEqual(r.zero_at, {}, delta)

    def test_future_zero_with_older_real_zero_is_still_fatal(self):
        series = self.zeros_at(1_000_060)
        series += self.zeros_at(1_000_630)
        self.assertTrue(self.analyze(series).fatal)

    def test_zero_in_fraction_of_observed_second_waits(self):
        series = self.zeros_at(1_000_600.5)
        r = self.analyze(series)
        self.assertEqual((r.fatal, r.pending, r.zero_at), ([], ["r1"], {}))
        # A later query (bound past the point) can use it.
        r = self.analyze(series, now=1_000_601)
        self.assertEqual((r.fatal, r.pending), ([], []))

    def test_point_after_query_end_but_before_response_date_is_not_used(self):
        r = self.analyze(self.zeros_at(1_000_605), now=1_000_600, observed=1_000_610)
        self.assertEqual((r.fatal, r.pending), ([], ["r1"]))

    def test_coverage_rejects_future_points(self):
        r = gate.analyze_coverage(self.zeros_at(1_000_601), self.cfg, 1_000_600 * self.N, 1_000_600 * self.N, {"r1"})
        self.assertTrue(r.fatal)
        r = gate.analyze_coverage(self.zeros_at(1_000_600.5), self.cfg, 1_000_600 * self.N, 1_000_600 * self.N, {"r1"})
        self.assertEqual((r.fatal, r.pending), ([], ["r1"]))

    def test_coherent_zero(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 0)]), self.series("r1", "idle", [(1_000_060, 0)])])
        self.assertEqual(r.fatal, [])
        self.assertEqual(r.pending, [])
        self.assertEqual(r.zero_at, {"r1": 1_000_060 * self.N})

    def test_point_at_fence_is_not_accepted(self):
        r = self.analyze([self.series("r1", "active", [(1_000_000, 0)]), self.series("r1", "idle", [(1_000_000, 0)])])
        self.assertEqual(r.pending, ["r1"])

    def test_point_one_nanosecond_after_fence_is_accepted(self):
        s1 = fg.make_series("r1", "active", [{"interval": {"endTime": "1970-01-12T13:46:40.000000001Z"},
                                               "value": {"int64Value": "0"}}])
        s2 = fg.make_series("r1", "idle", [{"interval": {"endTime": "1970-01-12T13:46:40.000000001Z"},
                                             "value": {"int64Value": "0"}}])
        r = self.analyze([s1, s2])
        self.assertEqual(r.pending, [])

    def test_missing_required_revision_is_pending(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 0)]), self.series("r1", "idle", [(1_000_060, 0)])],
                         required=("r1", "r0"))
        self.assertEqual(r.pending, ["r0"])

    def test_independent_zeros_do_not_count(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 0), (1_000_120, 1)]),
                          self.series("r1", "idle", [(1_000_060, 1), (1_000_120, 0)])])
        self.assertEqual(r.pending, ["r1"])

    def test_nonzero_after_zero_is_fatal(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 0), (1_000_120, 1)]),
                          self.series("r1", "idle", [(1_000_060, 0), (1_000_120, 0)])])
        self.assertTrue(r.fatal)

    def test_draining_before_zero_is_fine(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 1), (1_000_120, 0)]),
                          self.series("r1", "idle", [(1_000_060, 1), (1_000_120, 0)])])
        self.assertEqual((r.fatal, r.pending), ([], []))

    def test_conflicting_duplicate_points_are_fatal(self):
        r = self.analyze([self.series("r1", "active", [(1_000_060, 0)]), self.series("r1", "active", [(1_000_060, 2)]),
                          self.series("r1", "idle", [(1_000_060, 0)])])
        self.assertTrue(r.fatal)

    def test_missing_value_is_fatal(self):
        s = self.series("r1", "active", [(1_000_060, 0)])
        s["points"][0]["value"] = {}
        self.assertTrue(self.analyze([s]).fatal)

    def test_wrong_kind_is_fatal(self):
        s = self.series("r1", "active", [(1_000_060, 0)])
        s["metricKind"] = "DELTA"
        self.assertTrue(self.analyze([s]).fatal)

    def test_empty_series_blocks(self):
        r = self.analyze([self.series("r1", "active", []), self.series("r1", "idle", [(1_000_060, 0)])])
        self.assertEqual(r.pending, ["r1"])

    def test_timestamp_parsing(self):
        self.assertEqual(gate.parse_rfc3339_ns("1970-01-01T00:00:01.5Z"), 1_500_000_000)
        for bad in ("1970-01-01T00:00:01+00:00", "yesterday", "", None):
            with self.assertRaises(ValueError):
                gate.parse_rfc3339_ns(bad)
        self.assertEqual(gate.parse_http_date_ns("Thu, 01 Jan 1970 00:00:10 GMT"), 10 * self.N)
        self.assertIsNone(gate.parse_http_date_ns("garbage"))
        self.assertIsNone(gate.parse_http_date_ns(None))

    def test_scaling_normalization(self):
        self.assertEqual(gate.normalize_scaling(None),
                         {"scalingMode": "AUTOMATIC", "minInstanceCount": 0, "maxInstanceCount": 0})
        with self.assertRaises(ValueError):
            gate.normalize_scaling({"scalingMode": "MANUAL"})
        with self.assertRaises(ValueError):
            gate.normalize_scaling({"scalingMode": "SOMETHING"})
        self.assertTrue(gate.is_stopped_scaling({"scalingMode": "MANUAL", "manualInstanceCount": 0}))
        self.assertFalse(gate.is_stopped_scaling({"scalingMode": "MANUAL", "manualInstanceCount": 1}))
        self.assertFalse(gate.is_stopped_scaling({"minInstanceCount": 0}))


# ---------------------------------------------------------------------------
# Migration failures: Fleet stays stopped, never resumed
# ---------------------------------------------------------------------------


def _run_response(payload_fn):
    def apply(test):
        def fault(method, k, path, query, body):
            if method == "POST" and k == "run":
                return payload_fn(test.cloud, body)
            return None
        test.cloud.faults.append(fault)
    return apply


def _ex_hook(fn):
    def apply(test):
        test.cloud.execution_hook = fn
    return apply


def _set(attr, value):
    def apply(test):
        setattr(test.cloud, attr, value)
    return apply


def _during_migration(fn):
    def apply(test):
        c = test.cloud

        def fault(method, k, path, query, body):
            if c.executions and k == "executions" and not getattr(c, "_mig_mutated", False):
                c._mig_mutated = True
                fn(c)
            return None
        c.faults.append(fault)
    return apply


def _completed_only(fn):
    def hook(view, tasks, op):
        if view.get("completionTime"):
            fn(view, tasks, op)
    return hook


class TaskResultProtoDefaults(OfflineTestCase):
    def test_successful_default_scalars_upgrade_and_bootstrap(self):
        # These are equivalent ProtoJSON encodings of a successful attempt.
        # Success still requires all task, execution and operation evidence.
        results = [
            {}, {"status": {}}, {"status": {"code": 0}},
            {"exitCode": 0}, {"termSignal": 0},
            {"exitCode": 0, "termSignal": 0, "status": {"code": 0}},
            {"status": {"message": "completed", "details": []}},
        ]
        for bootstrap in (False, True):
            for result in results:
                with self.subTest(bootstrap=bootstrap, result=result):
                    self.cloud = fg.FakeCloud(service=not bootstrap)
                    self.logs = []
                    self.cloud.execution_hook = _completed_only(
                        lambda v, t, o, r=result: t[0].update(lastAttemptResult=r))
                    self.assertEqual(self.run_gate(), 0, self.text())
                    self.assertEqual(self.cloud.run_calls(), 1)
                    if not bootstrap:
                        self.assert_no_old_image_restart()


MIGRATION_CASES = {
    "task_attempt_result_unknown_field": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"unknown": 0}))), gate.MIGRATION_UNKNOWN),
    "task_attempt_status_unknown_field": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"status": {"unknown": 0}}))), gate.MIGRATION_UNKNOWN),
    "task_attempt_exit_null": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"exitCode": None}))), gate.MIGRATION_UNKNOWN),
    "task_attempt_signal_boolean": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"termSignal": False}))), gate.MIGRATION_UNKNOWN),
    "task_attempt_status_null": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"status": None}))), gate.MIGRATION_UNKNOWN),
    "task_attempt_status_message_malformed": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"status": {"message": 0}}))), gate.MIGRATION_UNKNOWN),
    "task_terminated_by_signal": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"termSignal": 9}))), gate.MIGRATION_UNKNOWN),
    "task_conflicting_exit_and_signal": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].update(lastAttemptResult={"exitCode": 0, "termSignal": 9}))), gate.MIGRATION_UNKNOWN),
    "execution_failed": (_set("outcome", "fail"), gate.MIGRATION_FAILED),
    "execution_cancelled": (_set("outcome", "cancel"), gate.MIGRATION_FAILED),
    "execution_never_finishes": (_set("outcome", "never"), gate.MIGRATION_UNKNOWN),
    "task_exit_code_nonzero": (_ex_hook(_completed_only(
        lambda v, t, o: t[0]["lastAttemptResult"].update(exitCode=2))), gate.MIGRATION_UNKNOWN),
    "task_status_code_nonzero": (_ex_hook(_completed_only(
        lambda v, t, o: t[0]["lastAttemptResult"].update(status={"code": 13}))), gate.MIGRATION_UNKNOWN),
    "task_without_last_attempt_result": (_ex_hook(_completed_only(
        lambda v, t, o: t[0].pop("lastAttemptResult"))), gate.MIGRATION_UNKNOWN),
    "task_retried": (_ex_hook(_completed_only(lambda v, t, o: t[0].update(retried=1))), gate.MIGRATION_UNKNOWN),
    "execution_retried_count": (_ex_hook(_completed_only(lambda v, t, o: v.update(retriedCount=1))),
                                gate.MIGRATION_FAILED),
    "two_tasks": (_ex_hook(_completed_only(lambda v, t, o: t.append(dict(t[0], name=t[0]["name"] + "x")))),
                  gate.MIGRATION_UNKNOWN),
    "task_wrong_image": (_ex_hook(_completed_only(
        lambda v, t, o: t[0]["containers"][0].update(image=fg.OLD_IMAGE))), gate.MIGRATION_UNKNOWN),
    "execution_missing_succeeded_count": (_ex_hook(_completed_only(lambda v, t, o: v.pop("succeededCount"))),
                                          gate.MIGRATION_UNKNOWN),
    "execution_missing_completed_condition": (_ex_hook(_completed_only(lambda v, t, o: v.update(conditions=[]))),
                                              gate.MIGRATION_UNKNOWN),
    "execution_task_count_missing": (_ex_hook(_completed_only(lambda v, t, o: v.pop("taskCount"))),
                                     gate.MIGRATION_UNKNOWN),
    "execution_uid_missing": (_ex_hook(_completed_only(lambda v, t, o: v.pop("uid"))), gate.MIGRATION_UNKNOWN),
    "operation_done_with_error": (_ex_hook(_completed_only(lambda v, t, o: o.update(error={"code": 13}))),
                                  gate.MIGRATION_FAILED),
    "operation_response_other_execution": (_ex_hook(_completed_only(
        lambda v, t, o: o.update(response={"name": "x"}))), gate.MIGRATION_UNKNOWN),
    "run_rejected_conflict": (_run_response(lambda c, b: fg.error(409, "ABORTED")), gate.MIGRATION_NOT_RUN),
    "run_ambiguous_5xx": (_run_response(lambda c, b: fg.error(503, "UNAVAILABLE")), gate.MIGRATION_UNKNOWN),
    "run_transport_drop_after_apply": (_run_response(
        lambda c, b: (c._h_run("POST", None, {}, b), fg.FakeResponse(504, raw=b""))[1]), gate.MIGRATION_UNKNOWN),
    "run_response_without_execution": (_run_response(lambda c, b: (
        c._h_run("POST", None, {}, b), fg.FakeResponse(200, {"name": fg.LOC + "/operations/x"}))[1]),
        gate.MIGRATION_UNKNOWN),
    "extra_execution_appears": (_during_migration(lambda c: c.add_prior_execution(settled=True)),
                                gate.MIGRATION_UNKNOWN),
    "job_changed_during_migration": (_during_migration(lambda c: c.job.update(generation="9", observedGeneration="9")),
                                     gate.MIGRATION_UNKNOWN),
    "service_changed_during_migration": (_during_migration(lambda c: c.service.update(etag='"x"')),
                                         gate.MIGRATION_UNKNOWN),
    "tag_added_during_migration": (_during_migration(lambda c: c.service["traffic"].append(
        {"type": "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION", "revision": "fleet-api-00001-aaa", "tag": "t"})),
        gate.MIGRATION_UNKNOWN),
    "instance_during_migration": (_set_override_after_stop(
        lambda c, rev, state, t, v: 1 if (c.executions and rev == "fleet-api-00002-bbb" and state == "active"
                                          and t > c.executions[0]["_start"]) else v), gate.MIGRATION_SUCCEEDED),
}


class MigrationFailures(OfflineTestCase):
    def test_failed_migration_after_proof_reports_measured_zero(self):
        MIGRATION_CASES["execution_failed"][0](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Fleet service: " + gate.FLEET_MEASURED_ZERO, self.text())

    def test_config_change_during_migration_drops_measured_zero_claim(self):
        MIGRATION_CASES["service_changed_during_migration"][0](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_instance_during_migration_drops_measured_zero_claim(self):
        MIGRATION_CASES["instance_during_migration"][0](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_run_retry_never_happens(self):
        MIGRATION_CASES["run_ambiguous_5xx"][0](self)
        self.assertEqual(self.run_gate(), 1)
        self.assertEqual(self.cloud.run_calls(), 1)


def _make_migration_test(setup, migration_state):
    def test(self):
        setup(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertLessEqual(self.cloud.run_calls(), 1)
        self.assertEqual(self.cloud.run_calls(), 1, "the gate must have attempted exactly one run")
        self.assert_not_resumed()
        self.assertIn("Migration: " + migration_state, self.text())
        # Each scenario leaves the fake service MANUAL/0 under this run's record.
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
    return test


for _name, (_setup, _state) in MIGRATION_CASES.items():
    setattr(MigrationFailures, "test_no_resume_" + _name, _make_migration_test(_setup, _state))


# ---------------------------------------------------------------------------
# Resume failures (migration already verified)
# ---------------------------------------------------------------------------


class ResumeFailures(OfflineTestCase):
    def test_new_revision_never_ready_under_manual_zero(self):
        self.cloud.new_revision_ready = False
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
        restores = [b for b in self.cloud.service_patches() if b["scaling"].get("scalingMode") != "MANUAL"]
        self.assertEqual(restores, [], "no restore without a new Ready revision")
        self.assert_no_old_image_restart()

    def test_new_revision_runs_wrong_image(self):
        self.cloud.new_revision_image = fg.OLD_IMAGE
        self.assertEqual(self.run_gate(), 1)
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_image_write_rejected(self):
        self.cloud.faults.append(_fail_nth_write("service", 4, fg.error(409, "ABORTED")))
        self.assertEqual(self.run_gate(), 1)
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_migrated_checkpoint_write_rejected(self):
        self.cloud.faults.append(_fail_nth_write("service", 3, fg.error(409, "ABORTED")))
        self.assertEqual(self.run_gate(), 1)
        self.assertEqual(self.cloud.count("PATCH", "service"), 3)
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())

    def test_restore_rejected_then_verified_restop(self):
        self.cloud.faults.append(_fail_nth_write("service", 5, fg.error(409, "ABORTED")))
        self.assertEqual(self.run_gate(), 1)
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
        cp = self.cloud.checkpoint()
        self.assertEqual(cp["phase"], "failed")
        self.assertEqual(cp["pre_scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1, "maxInstanceCount": 0},
                         "the recorded pre-migration scaling is never overwritten")
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())

    def test_restore_applied_but_unreadable_is_reported_unknown(self):
        c = self.cloud

        def fault(method, k, path, query, body):
            if c.restore_time is not None and method == "GET" and k in ("service", "operation"):
                return fg.error(503, "UNAVAILABLE")
            return None
        c.faults.append(fault)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("Fleet service: " + gate.FLEET_STATE_UNKNOWN, self.text())
        self.assertNotIn(gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_restore_and_restop_both_fail_never_claims_stopped(self):
        c = self.cloud
        c.faults.append(_fail_nth_write("service", 5, fg.error(503, "UNAVAILABLE")))
        c.faults.append(_fail_nth_write("service", 6, fg.error(503, "UNAVAILABLE")))
        self.assertEqual(self.run_gate(), 1)
        # Neither write was applied by the fake: the read-back shows MANUAL/0
        # under this run's record (restart disabled). A new revision was
        # deployed after the proof, so no measured zero is claimed.
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))
        self.assertIn("Fleet service: " + gate.FLEET_RESTART_DISABLED, self.text())
        self.assert_not_claimed_measured_zero()

    def test_restore_mismatch_restops(self):
        c = self.cloud
        original = c._h_service

        def drop_min(method, k, path, query, body):
            if method == "PATCH" and k == "service" and body.get("scaling", {}).get("scalingMode") == "AUTOMATIC":
                body = dict(body, scaling={"scalingMode": "AUTOMATIC", "minInstanceCount": 7})
                return original(method, None, query, body)
            return None
        c.faults.append(drop_min)
        self.assertEqual(self.run_gate(), 1)
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))


# ---------------------------------------------------------------------------
# Fresh bootstrap refusals
# ---------------------------------------------------------------------------


class BootstrapRefusals(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.cloud = fg.FakeCloud(service=False)

    def check_refused(self):
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assert_not_run()

    def test_soft_deleted_service_blocks(self):
        self.cloud.deleted_services.append({"name": fg.SVC_NAME, "deleteTime": fg.ts(fg.START - 60)})
        self.check_refused()
        self.assert_no_writes()

    def test_recent_telemetry_blocks(self):
        self.cloud.bootstrap_series = [fg.make_series("fleet-api-00001-aaa", "idle", [fg.point(fg.START - 900, 0)])]
        self.check_refused()
        self.assert_no_writes()

    def test_404_without_not_found_status_is_not_absence(self):
        self.cloud.faults.append(
            lambda m, k, p, q, b: fg.FakeResponse(404, raw=b"<html>not found</html>") if k == "service" else None)
        self.check_refused()
        self.assert_no_writes()

    def test_unsettled_execution_blocks(self):
        self.cloud.add_prior_execution(settled=False)
        self.check_refused()
        self.assert_no_writes()

    def test_service_appears_before_run(self):
        c = self.cloud

        def appear(method, k, path, query, body):
            if method == "PATCH" and k == "job":
                c.service = c._make_service()
            return None
        c.faults.append(appear)
        self.check_refused()

    def test_service_appears_during_migration(self):
        c = self.cloud

        def appear(method, k, path, query, body):
            if c.executions and k == "executions":
                c.service = c._make_service()
            return None
        c.faults.append(appear)
        self.assertEqual(self.run_gate(), 1)
        self.assertEqual(c.run_calls(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())

    def test_job_record_conflict(self):
        self.cloud.faults.append(_fail_nth_write("job", 1, fg.error(409, "ABORTED")))
        self.check_refused()

    def test_failed_bootstrap_migration_is_retried_by_the_next_apply(self):
        self.cloud.outcome = "fail"
        self.assertEqual(self.run_gate(), 1)
        cp = json.loads(self.cloud.job["annotations"][fg.CHECKPOINT])
        self.assertEqual(cp["phase"], "bootstrap-migrating")
        # The database problem is fixed; the next apply (new Terraform run id)
        # proves the deployment is still fresh and runs one fresh migration.
        self.cloud.log.clear()
        self.cloud.outcome = "success"
        self.assertEqual(self.run_gate(environ=fg.env(FLEET_GATE_RUN_ID="second-run",
                                                      FLEET_GATE_JOB_GENERATION=self.cloud.job["generation"])), 0,
                         self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        cp = json.loads(self.cloud.job["annotations"][fg.CHECKPOINT])
        self.assertEqual((cp["run"], cp["phase"]), ("second-run", "completed"))


# ---------------------------------------------------------------------------
# Retry / concurrency across runs
# ---------------------------------------------------------------------------


class RerunAfterFailure(OfflineTestCase):
    def test_failed_migration_is_not_retried_within_the_apply_but_by_the_next_one(self):
        self.cloud.outcome = "fail"
        self.assertEqual(self.run_gate(), 1)
        self.assertEqual(self.cloud.run_calls(), 1, "never retried within an apply")
        snapshot = self.cloud.checkpoint()["pre_scaling"]
        self.cloud.outcome = "success"
        self.cloud.log.clear()
        self.cloud.bodies.clear()
        self.logs.clear()
        self.assertEqual(self.run_gate(environ=fg.env(FLEET_GATE_RUN_ID="retry-run",
                                                      FLEET_GATE_JOB_GENERATION=self.cloud.job["generation"])), 0,
                         self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertEqual(self.cloud.checkpoint()["pre_scaling"], snapshot)
        self.assertEqual(self.cloud.checkpoint()["run"], "retry-run")
        self.assertEqual(self.cloud.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})

    def test_stopped_service_of_an_earlier_run_is_recovered_with_its_recorded_scaling(self):
        # An earlier run left the service stopped; its recorded scaling (not
        # the current MANUAL/0) is restored after one fresh migration.
        self.cloud.service["scaling"] = {"scalingMode": "MANUAL", "manualInstanceCount": 0}
        self.cloud.stop_time = fg.START - 3600
        self.cloud.service["annotations"][fg.CHECKPOINT] = json.dumps(
            {"v": 1, "run": "other-controller", "phase": "stopped",
             "pre_scaling": {"scalingMode": "AUTOMATIC", "minInstanceCount": 3, "maxInstanceCount": 0}})
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertEqual(self.cloud.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 3})


# ---------------------------------------------------------------------------
# Runtime dependencies (no real gcloud / network)
# ---------------------------------------------------------------------------


class RuntimeDependencies(unittest.TestCase):
    def test_gcloud_token_source_argv_and_no_shell(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=b"ya29.UNIT-TOKEN\n", stderr=b"")
        with mock.patch("shutil.which", return_value="/fake/bin/gcloud"), \
                mock.patch("subprocess.run", return_value=completed) as run:
            self.assertEqual(gate.GcloudAdcTokenSource().token(), "ya29.UNIT-TOKEN")
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["/fake/bin/gcloud", "auth", "application-default", "print-access-token"])
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    def test_gcloud_failure_is_a_gate_error(self):
        failed = subprocess.CompletedProcess(args=[], returncode=1, stdout=b"", stderr=b"")
        with mock.patch("shutil.which", return_value="/fake/bin/gcloud"), \
                mock.patch("subprocess.run", return_value=failed):
            with self.assertRaises(gate.GateError):
                gate.GcloudAdcTokenSource().token()
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(gate.GateError):
                gate.GcloudAdcTokenSource().token()

    def test_gcloud_bad_output(self):
        weird = subprocess.CompletedProcess(args=[], returncode=0, stdout=b"two words\n", stderr=b"")
        with mock.patch("shutil.which", return_value="/fake/bin/gcloud"), \
                mock.patch("subprocess.run", return_value=weird):
            with self.assertRaises(gate.GateError):
                gate.GcloudAdcTokenSource().token()

    def test_urllib_transport_maps_connection_errors(self):
        import urllib.error
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("down")):
            with self.assertRaises(gate.TransportError):
                gate.UrllibTransport().request("GET", "https://run.googleapis.com/v2/x", {}, None)

    def test_import_has_no_side_effects(self):
        import importlib
        with mock.patch("urllib.request.urlopen", side_effect=_blocked), \
                mock.patch("subprocess.run", side_effect=_blocked), \
                mock.patch("subprocess.Popen", side_effect=_blocked):
            importlib.reload(gate)

    def test_writes_are_never_retried(self):
        cloud = fg.FakeCloud()
        cloud.faults.append(lambda m, k, p, q, b: fg.error(503, "UNAVAILABLE") if m != "GET" else None)
        api = gate.Api(cloud, fg.FakeToken(), cloud.clock, lambda m: None)
        with self.assertRaises(gate.WriteOutcomeUnknown):
            api.write("POST", "https://run.googleapis.com/v2/" + fg.JOB_NAME + ":run", "run", {"etag": "x"})
        self.assertEqual(cloud.run_calls(), 1)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Review regressions: monotonic revision set and execution inventory
# ---------------------------------------------------------------------------


def _transient_revision(points_fn):
    """A revision appears in exactly one post-stop telemetry response, then
    disappears from every later response."""
    def apply(test):
        c = test.cloud
        state = {"query_end": None}

        def hook(series):
            # Pages of one query share interval.endTime; show the ghost on
            # every page of the first post-stop query that has points, and
            # never again.
            end = c.current_query["interval.endTime"]
            if c.stop_time is None or state["query_end"] not in (None, end):
                return series
            visible = [p for s in series for p in s["points"]
                       if fg.parse_ts(p["interval"]["endTime"]) > c.stop_time]
            if not visible:
                return series
            state["query_end"] = end
            t = max(fg.parse_ts(p["interval"]["endTime"]) for p in visible)
            return series + points_fn(t)
        c.series_hook = hook
    return apply


class TransientRevisionTelemetry(OfflineTestCase):
    def check_blocked(self):
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assert_not_run()
        self.assertIn("fleet-api-00077-ghost", self.text())
        self.assertIn("no verified actual zero", self.text())
        self.assert_not_claimed_measured_zero()

    def test_nonzero_revision_that_disappears_still_blocks(self):
        _transient_revision(lambda t: [fg.make_series("fleet-api-00077-ghost", "active", [fg.point(t, 1)]),
                                       fg.make_series("fleet-api-00077-ghost", "idle", [fg.point(t, 0)])])(self)
        self.check_blocked()

    def test_incomplete_revision_that_disappears_still_blocks(self):
        _transient_revision(lambda t: [fg.make_series("fleet-api-00077-ghost", "active", [fg.point(t, 0)])])(self)
        self.check_blocked()

    def test_revision_with_complete_zero_once_is_accepted(self):
        # Seen once with a coherent zero: that revision has its own proof.
        _transient_revision(lambda t: [fg.make_series("fleet-api-00077-ghost", "active", [fg.point(t, 0)]),
                                       fg.make_series("fleet-api-00077-ghost", "idle", [fg.point(t, 0)])])(self)
        c = self.cloud
        hook = c.series_hook
        # Keep returning the ghost's (zero) data so the post-migration recheck
        # can still see it; it must not be dropped from the required set.
        seen = {}

        def sticky(series):
            out = hook(series)
            for s in out:
                if s["resource"]["labels"]["revision_name"] == "fleet-api-00077-ghost":
                    seen.setdefault(s["metric"]["labels"]["state"], s)
            names = {(s["resource"]["labels"]["revision_name"], s["metric"]["labels"]["state"]) for s in out}
            for state, s in seen.items():
                if ("fleet-api-00077-ghost", state) not in names:
                    out.append(s)
            return out
        c.series_hook = sticky
        self.assertEqual(self.run_gate(), 0, self.text())


def _add_execution_on(method, kind, predicate=lambda body: True, settled=True):
    def apply(test):
        c = test.cloud
        state = {"done": False}

        def fault(m, k, path, query, body):
            if not state["done"] and m == method and k == kind and predicate(body):
                state["done"] = True
                c.add_prior_execution(settled=settled)
            return None
        c.faults.append(fault)
    return apply


def _new_image_body(body):
    return bool(body) and body.get("template", {}).get("containers", [{}])[0].get("image") == fg.NEW_IMAGE


class ExecutionInventoryBeforeStartup(OfflineTestCase):
    def assert_no_startup(self, expected):
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertIn(expected, self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        restores = [b for b in self.cloud.service_patches() if b["scaling"].get("scalingMode") != "MANUAL"]
        self.assertEqual(restores, [], "Fleet must not be allowed to start")
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))

    def test_extra_execution_during_final_task_read(self):
        _add_execution_on("GET", "tasks")(self)
        self.assert_no_startup("unexpected job executions exist after the migration")
        self.assertFalse(any(_new_image_body(b) for b in self.cloud.service_patches()),
                         "the new image must not be deployed")

    def test_running_extra_execution_during_final_task_read(self):
        _add_execution_on("GET", "tasks", settled=False)(self)
        self.assert_no_startup("unexpected job executions exist after the migration")

    def test_extra_execution_during_rollout(self):
        _add_execution_on("PATCH", "service", _new_image_body)(self)
        self.assert_no_startup("unexpected job executions exist during the rollout")
        self.assertTrue(any(_new_image_body(b) for b in self.cloud.service_patches()))

    def test_extra_execution_before_new_image_write(self):
        def is_migrated_phase(body):
            raw = (body or {}).get("annotations", {}).get(fg.CHECKPOINT)
            return bool(raw) and json.loads(raw)["phase"] == "migrated"
        _add_execution_on("PATCH", "service", is_migrated_phase)(self)
        self.assert_no_startup("unexpected job executions exist before deploying the new image")
        self.assertFalse(any(_new_image_body(b) for b in self.cloud.service_patches()))

    def test_owned_execution_turns_failed_before_restore(self):
        c = self.cloud

        def flip(m, k, path, query, body):
            if m == "PATCH" and k == "service" and _new_image_body(body):
                c.execution_hook = lambda v, t, o: v.update(failedCount=1) if v.get("completionTime") else None
            return None
        c.faults.append(flip)
        self.assert_no_startup("the migration execution no longer reports success during the rollout")

    def test_job_changed_before_restore(self):
        c = self.cloud

        def change(m, k, path, query, body):
            if m == "PATCH" and k == "service" and _new_image_body(body):
                c.job.update(generation="11", observedGeneration="11")
            return None
        c.faults.append(change)
        self.assert_no_startup("the job changed during the rollout")


class BootstrapExecutionInventory(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.cloud = fg.FakeCloud(service=False)

    def test_job_change_at_completion_read_blocks_bootstrap(self):
        c = self.cloud
        state = {"armed": False, "reads": 0}

        def change(method, kind, path, query, body):
            if method == "GET" and kind == "tasks":
                state["armed"] = True
            if state["armed"] and method == "GET" and kind == "job":
                state["reads"] += 1
                # After-task verification, before-completion verification,
                # then the fresh read used for the completion PATCH.
                if state["reads"] == 3:
                    generation = str(int(c.job["generation"]) + 1)
                    c.job.update(generation=generation, observedGeneration=generation, etag=c.etag("job"))
                    c.job["template"]["template"]["containers"][0]["env"] = fg.fleet_env(fg.NEW_DB_ADDRESS)
            return None

        c.faults.append(change)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("the job changed before the bootstrap completion write", self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("POST", "run")])
        self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")

    def rerun(self, run_id):
        self.cloud.log.clear()
        self.cloud.bodies.clear()
        self.logs.clear()
        return self.run_gate(environ=fg.env(FLEET_GATE_RUN_ID=run_id,
                                            FLEET_GATE_JOB_GENERATION=self.cloud.job["generation"]))

    def test_uncertain_completion_is_retried_with_a_fresh_migration(self):
        def is_completion(body):
            raw = (body or {}).get("annotations", {}).get(fg.CHECKPOINT)
            return bool(raw) and json.loads(raw)["phase"] == "completed"
        _add_execution_on("PATCH", "job", is_completion)(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        # The extra execution has settled by now (the fake adds it settled):
        # the next apply treats it as prior baseline and runs one fresh
        # migration under its own claim; the earlier success is not adopted.
        self.assertEqual(self.rerun("retry-run"), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)

    def test_completed_bootstrap_is_never_adopted_instead_of_a_migration(self):
        self.assertEqual(self.run_gate(), 0, self.text())
        cp = json.loads(self.cloud.job["annotations"][fg.CHECKPOINT])
        self.assertEqual(cp["executions"], [cp["execution"]])
        self.assertEqual(self.rerun("next-run"), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertEqual(len(self.cloud.executions), 2)

    def test_completed_record_without_inventory_is_not_a_blocker(self):
        self.cloud.job["annotations"] = {fg.CHECKPOINT: json.dumps(
            {"v": 1, "run": "older", "phase": "completed", "pre_scaling": None})}
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)

    def test_completed_record_whose_execution_vanished_is_not_a_blocker(self):
        self.assertEqual(self.run_gate(), 0, self.text())
        self.cloud.executions.clear()
        self.assertEqual(self.rerun("next-run"), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)

    def test_extra_execution_during_final_task_read_blocks_completion(self):
        _add_execution_on("GET", "tasks")(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("unexpected job executions exist after the migration", self.text())
        self.assertEqual(json.loads(self.cloud.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")
        self.assertEqual(self.cloud.writes(), [("PATCH", "job"), ("POST", "run")])

    def test_extra_execution_at_completion_write_fails_the_gate(self):
        def is_completion(body):
            raw = (body or {}).get("annotations", {}).get(fg.CHECKPOINT)
            return bool(raw) and json.loads(raw)["phase"] == "completed"
        _add_execution_on("PATCH", "job", is_completion)(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("unexpected job executions exist before Terraform creates the service", self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())


# ---------------------------------------------------------------------------
# Serving configuration after the migration (same image, changed serving env)
# ---------------------------------------------------------------------------


def _same_image(cloud):
    """The deployment already runs the target image (e.g. the first apply after
    adopting the gate, or a replaced gate resource), while the job's serving
    env differs from the service (e.g. a changed backend address)."""
    cloud.service["template"]["containers"][0]["image"] = fg.NEW_IMAGE
    for rev in cloud.revisions:
        rev["containers"][0]["image"] = fg.NEW_IMAGE


def _phase(body):
    raw = (body or {}).get("annotations", {}).get(fg.CHECKPOINT)
    return json.loads(raw)["phase"] if raw else None


class ServingConfigAfterMigration(OfflineTestCase):
    def test_same_image_new_database_address_rolls_out_new_env(self):
        c = self.cloud
        _same_image(c)
        original_template = json.loads(json.dumps(c.service["template"]))
        c.job["template"]["template"]["containers"][0]["env"] = fg.fleet_env(fg.NEW_DB_ADDRESS)
        old_ready = c.service["latestReadyRevision"]
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("PATCH", "service"), ("PATCH", "service"), ("POST", "run"),
                                      ("PATCH", "service"), ("PATCH", "service"), ("PATCH", "service")])
        stop, migrating, migrated, rollout, restore = c.service_patches()
        # Before the verified migration the template (old DB address) is untouched.
        for body in (stop, migrating, migrated):
            self.assertEqual(body["template"], original_template)
        self.assertEqual(_phase(rollout), "rolling-out")
        container = rollout["template"]["containers"][0]
        self.assertEqual(gate.normalize_env(container["env"]), gate.normalize_env(fg.fleet_env(fg.NEW_DB_ADDRESS)))
        self.assertEqual(container["image"], fg.NEW_IMAGE)
        # Service-only fields are preserved; job-only fields are not copied.
        self.assertEqual(container["ports"], original_template["containers"][0]["ports"])
        self.assertEqual(container["startupProbe"], original_template["containers"][0]["startupProbe"])
        self.assertNotIn("command", container)
        self.assertNotIn("args", container)
        self.assertNotIn("revision", rollout["template"])
        self.assertEqual(set(rollout["template"]) | {"revision"}, set(original_template))
        # The template write (first possible startup) happens only after :run
        # and the verified-success checkpoint.
        rollout_at = [i for i, (m, k, _, _) in enumerate(c.log) if m == "PATCH" and k == "service"][3]
        self.assertGreater(rollout_at, c.index("POST", "run"))
        # A new Ready revision with the new DB address serves before scaling returns.
        new_ready = c.service["latestReadyRevision"]
        self.assertNotEqual(new_ready, old_ready)
        rev = next(r for r in c.revisions if r["name"] == new_ready)
        self.assertEqual(gate.normalize_env(rev["containers"][0]["env"])["FLEET_MYSQL_ADDRESS"],
                         ("value", fg.NEW_DB_ADDRESS))
        self.assertEqual(c.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
        self.assertNotIn(fg.NEW_DB_ADDRESS, self.text(), "env values are never logged")

    def test_same_image_same_config_needs_no_new_revision(self):
        c = self.cloud
        _same_image(c)
        original_template = json.loads(json.dumps(c.service["template"]))
        revisions_before = len(c.revisions)
        ready_before = c.service["latestReadyRevision"]
        self.assertEqual(self.run_gate(), 0, self.text())
        patches = c.service_patches()
        self.assertEqual([_phase(b) for b in patches], ["stopped", "migrating", "migrated", "rolling-out", "completed"])
        for body in patches:
            self.assertEqual(body["template"], original_template, "no template change is needed")
        self.assertEqual(len(c.revisions), revisions_before)
        self.assertEqual(c.service["latestReadyRevision"], ready_before)
        self.assertIn("no new revision needed", self.text())

    def test_same_config_but_ready_revision_differs_is_refused(self):
        c = self.cloud
        _same_image(c)
        # The template matches, but the Ready revision does not run it.
        c.revisions[-1]["containers"][0]["env"] = fg.fleet_env("10.99.0.1:3306")
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("does not run the target image and serving configuration", self.text())
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))

    def test_cmek_key_from_job_is_applied(self):
        c = self.cloud
        key = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/run"
        c.job["template"]["template"]["encryptionKey"] = key
        self.assertEqual(self.run_gate(), 0, self.text())
        rollout = c.service_patches()[3]
        self.assertEqual(rollout["template"]["encryptionKey"], key)
        rev = next(r for r in c.revisions if r["name"] == c.service["latestReadyRevision"])
        self.assertEqual(rev.get("encryptionKey"), key)

    def test_cmek_key_removed_when_job_has_none(self):
        c = self.cloud
        c.service["template"]["encryptionKey"] = "projects/kms-proj/locations/us-central1/keyRings/r/cryptoKeys/old"
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertNotIn("encryptionKey", c.service_patches()[3]["template"])

    def test_new_revision_with_stale_env_never_starts(self):
        c = self.cloud
        _same_image(c)
        c.job["template"]["template"]["containers"][0]["env"] = fg.fleet_env(fg.NEW_DB_ADDRESS)
        c.new_revision_hook = lambda rev: rev["containers"][0].update(env=fg.fleet_env(fg.OLD_DB_ADDRESS))
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("does not run the target image and serving configuration", self.text())
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())
        restores = [b for b in c.service_patches() if b["scaling"].get("scalingMode") != "MANUAL"]
        self.assertEqual(restores, [])

    def test_extra_execution_while_waiting_for_new_revision(self):
        c = self.cloud
        c.new_revision_ready = False
        state = {"reads": 0}

        def fault(m, k, path, query, body):
            # While the new-revision operation is still being polled.
            if m == "GET" and k == "operation" and c.checkpoint() and c.checkpoint()["phase"] == "rolling-out":
                state["reads"] += 1
                if state["reads"] == 1:
                    c.add_prior_execution(settled=True)
            return None
        c.faults.append(fault)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("unexpected job executions exist during the rollout", self.text())
        self.assertNotIn("did not finish within", self.text(), "detected while deploying, not by timeout")
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))

    def test_extra_execution_just_before_restore(self):
        c = self.cloud
        state = {"n": 0}

        def fault(m, k, path, query, body):
            if m == "GET" and k == "executions" and c.checkpoint() and c.checkpoint()["phase"] == "rolling-out":
                state["n"] += 1
                # 1: operation poll, 2: rollout poll, 3: rollout final check,
                # 4: the check immediately before the scaling restore.
                if state["n"] == 4:
                    c.add_prior_execution(settled=True)
            return None
        c.faults.append(fault)
        self.assertEqual(self.run_gate(), 1)
        self.assertIn("unexpected job executions exist before restoring scaling", self.text())
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))


PREFLIGHT_CASES_SERVING = {
    "job_env_value_and_secret": job_mutation(lambda j: j["template"]["template"]["containers"][0]["env"].append(
        {"name": "X", "value": "a", "valueSource": {"secretKeyRef": {"secret": "s", "version": "1"}}})),
    "job_env_duplicate_name": job_mutation(lambda j: j["template"]["template"]["containers"][0]["env"].append(
        {"name": "FLEET_MYSQL_ADDRESS", "value": "x"})),
    "job_env_unknown_source": job_mutation(lambda j: j["template"]["template"]["containers"][0]["env"].append(
        {"name": "X", "valueSource": {"somethingElse": {}}})),
    "job_encryption_key_malformed": job_mutation(lambda j: j["template"]["template"].update(encryptionKey=7)),
}

for _name, _setup in PREFLIGHT_CASES_SERVING.items():
    setattr(PreflightRefusals, "test_refuses_" + _name, _make_preflight_test(_name, _setup))


# ---------------------------------------------------------------------------
# Fresh-bootstrap absence proof: structured identities only
# ---------------------------------------------------------------------------


class BootstrapListingIdentity(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.cloud = fg.FakeCloud(service=False)

    def refused_with(self, entry, message):
        self.cloud.deleted_services.append(entry)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assert_not_run()
        self.assert_no_writes()
        self.assertIn(message, self.text())

    def test_entry_without_name_is_unknown(self):
        self.refused_with({"uid": "x", "deleteTime": fg.ts(fg.START - 60)}, "without a valid name")

    def test_entry_with_non_string_name_is_unknown(self):
        self.refused_with({"name": 42}, "without a valid name")

    def test_entry_with_malformed_name_is_unknown(self):
        for bad in ("fleet-api", f"{fg.LOC}/services/", f"{fg.LOC}/jobs/fleet-api",
                    f"{fg.LOC}/services/fleet-api/revisions/x"):
            with self.subTest(bad=bad):
                self.cloud = fg.FakeCloud(service=False)
                self.cloud.log.clear()
                self.refused_with({"name": bad}, "without a valid name")

    def test_project_number_alias_of_soft_deleted_fleet_is_refused(self):
        self.refused_with({"name": f"projects/123456789012/locations/{fg.REGION}/services/{fg.SERVICE}",
                           "deleteTime": fg.ts(fg.START - 60)}, "exists or is soft-deleted")

    def test_unexpected_project_spelling_is_refused(self):
        self.refused_with({"name": f"projects/other-project-x/locations/{fg.REGION}/services/unrelated"},
                          "unexpected project")

    def test_unexpected_location_is_refused(self):
        self.refused_with({"name": f"projects/{fg.PROJECT}/locations/europe-west1/services/unrelated"},
                          "unexpected location")

    def test_unrelated_services_in_scope_are_allowed(self):
        self.cloud.deleted_services += [
            {"name": f"{fg.LOC}/services/other-app"},
            {"name": f"projects/123456789012/locations/{fg.REGION}/services/other-app-2",
             "deleteTime": fg.ts(fg.START - 60)},
        ]
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)


# ---------------------------------------------------------------------------
# Image identity: configured reference vs Cloud Run's runtime resolution
# ---------------------------------------------------------------------------

AR_IMAGE = "us-central1-docker.pkg.dev/fleet-test-project/fleet/fleet:v4.93.0"
AR_RESOLVED = "us-central1-docker.pkg.dev/fleet-test-project/fleet/fleet@" + fg.NEW_DIGEST


def _with_configured_image(cloud, image):
    """Terraform sets the same configured string on the job (and passes it as
    FLEET_GATE_IMAGE); runtime objects may report it resolved."""
    cloud.job["template"]["template"]["containers"][0]["image"] = image
    return fg.env(FLEET_GATE_IMAGE=image)


class ImageReferenceParsing(unittest.TestCase):
    def canon(self, value):
        ref = gate.parse_image_ref(value)
        return ref.host, ref.path, ref.tag, ref.digest

    def test_docker_hub_canonicalization(self):
        expected = ("docker.io", "fleetdm/fleet", "v4.93.0", None)
        for value in ("fleetdm/fleet:v4.93.0", "docker.io/fleetdm/fleet:v4.93.0",
                      "index.docker.io/fleetdm/fleet:v4.93.0", "registry-1.docker.io/fleetdm/fleet:v4.93.0",
                      "mirror.gcr.io/fleetdm/fleet:v4.93.0"):
            with self.subTest(value=value):
                self.assertEqual(self.canon(value), expected)
        self.assertEqual(self.canon("mirror.gcr.io/fleetdm/fleet@" + fg.NEW_DIGEST),
                         ("docker.io", "fleetdm/fleet", None, fg.NEW_DIGEST))
        self.assertEqual(self.canon("busybox"), ("docker.io", "library/busybox", "latest", None))
        self.assertEqual(self.canon("docker.io/library/busybox:1"), ("docker.io", "library/busybox", "1", None))
        self.assertEqual(self.canon("fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST),
                         ("docker.io", "fleetdm/fleet", "v4.93.0", fg.NEW_DIGEST))

    def test_other_registries_keep_exact_host_and_path(self):
        self.assertEqual(self.canon(AR_IMAGE),
                         ("us-central1-docker.pkg.dev", "fleet-test-project/fleet/fleet", "v4.93.0", None))
        self.assertEqual(self.canon("localhost:5000/fleet"), ("localhost:5000", "fleet", "latest", None))
        for value in ("gcr.io/fleetdm/fleet:v4.93.0", "mirror.gcr.io.evil/fleetdm/fleet:v4.93.0",
                      "evilmirror.gcr.io/fleetdm/fleet:v4.93.0", "docker.io.evil/fleetdm/fleet:v4.93.0",
                      "mirror.gcr.io:443/fleetdm/fleet:v4.93.0"):
            with self.subTest(value=value):
                self.assertNotEqual(self.canon(value)[0], "docker.io")

    def test_malformed_references_are_rejected(self):
        for value in (None, "", " fleetdm/fleet", "fleetdm/fleet:v1 ", "FleetDM/fleet:v1",
                      "fleetdm/fleet@sha256:" + "A" * 64, "fleetdm/fleet@sha256:" + "a" * 63,
                      "fleetdm/fleet@sha256:" + "a" * 65, "fleetdm/fleet@sha512:" + "a" * 128,
                      "fleetdm/fleet@", "fleetdm/fleet@sha256:", "fleetdm/fleet@@" + fg.NEW_DIGEST,
                      "fleetdm/fleet:", "fleetdm/fleet:-bad", "fleetdm//fleet", "/fleetdm/fleet",
                      "fleetdm/fleet/", "-bad.host/fleet", "mirror.gcr.io/", "x" * 600):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    gate.parse_image_ref(value)

    def test_runtime_compatibility_rules(self):
        def mismatch(configured, observed):
            return gate.runtime_image_mismatch(gate.parse_image_ref(configured), gate.parse_image_ref(observed))

        tag, digest = "fleetdm/fleet:v4.93.0", "fleetdm/fleet@" + fg.NEW_DIGEST
        both = "fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST
        ok = [
            (tag, tag), (tag, "docker.io/fleetdm/fleet:v4.93.0"), (tag, fg.MIRROR_NEW_IMAGE),
            (tag, "mirror.gcr.io/fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST),
            (digest, digest), (digest, fg.MIRROR_NEW_IMAGE), (both, fg.MIRROR_NEW_IMAGE), (both, both),
            (AR_IMAGE, AR_RESOLVED), (AR_IMAGE, AR_IMAGE),
        ]
        bad = [
            (tag, "fleetdm/fleet:v4.92.0"), (tag, "mirror.gcr.io/fleetdm/fleet:v4.92.0@" + fg.NEW_DIGEST),
            (tag, "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST), (tag, "mirror.gcr.io/fleet@" + fg.NEW_DIGEST),
            (tag, "mirror.gcr.io/fleetdm/fleet-other@" + fg.NEW_DIGEST),
            (tag, "mirror.gcr.io.evil/fleetdm/fleet@" + fg.NEW_DIGEST),
            (tag, "gcr.io/fleetdm/fleet@" + fg.NEW_DIGEST), (tag, "fleetdm/fleet"),
            (digest, "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST), (digest, tag),
            (both, "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST), (both, tag),
            (both, "fleetdm/fleet:v4.92.0@" + fg.NEW_DIGEST),
            (AR_IMAGE, "us-docker.pkg.dev/fleet-test-project/fleet/fleet@" + fg.NEW_DIGEST),
            (AR_IMAGE, "us-central1-docker.pkg.dev/other-project/fleet/fleet@" + fg.NEW_DIGEST),
            (AR_IMAGE, "mirror.gcr.io/fleet-test-project/fleet/fleet@" + fg.NEW_DIGEST),
            ("fleetdm/fleet:v4.93.0", "us-central1-docker.pkg.dev/fleetdm/fleet@" + fg.NEW_DIGEST),
        ]
        for configured, observed in ok:
            with self.subTest(configured=configured, observed=observed):
                self.assertIsNone(mismatch(configured, observed))
        for configured, observed in bad:
            with self.subTest(configured=configured, observed=observed):
                self.assertIsNotNone(mismatch(configured, observed))


class ImageIdentityHappyPath(OfflineTestCase):
    def test_upgrade_with_mirror_digest_execution_and_revision(self):
        c = self.cloud
        c.resolve_images()
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("PATCH", "service"), ("PATCH", "service"), ("POST", "run"),
                                      ("PATCH", "service"), ("PATCH", "service"), ("PATCH", "service")])
        self.assertEqual(c.run_calls(), 1)
        # The observed shape: the job and the task keep the configured tag;
        # the execution (and here the revision) report the digest.
        self.assertEqual(c.job["template"]["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        view, tasks, _ = c.render_execution(c.executions[0])
        self.assertEqual(view["template"]["containers"][0]["image"], fg.MIRROR_NEW_IMAGE)
        self.assertEqual(tasks[0]["containers"][0]["image"], fg.NEW_IMAGE)
        new_rev = next(r for r in c.revisions if r["name"] == c.service["latestReadyRevision"])
        self.assertEqual(new_rev["containers"][0]["image"], fg.MIRROR_NEW_IMAGE)
        # Configuration written by the gate stays the configured tag, so the
        # provider does not later revert a digest to the tag.
        image = c.service_patches()[3]
        self.assertEqual(image["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertEqual(c.service["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        for body in c.service_patches():
            self.assertNotIn(fg.NEW_DIGEST, json.dumps(body))
        self.assertEqual(c.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
        self.assertIn(fg.NEW_DIGEST, self.text())
        self.assert_no_old_image_restart()

    def test_upgrade_with_digest_execution_and_tag_only_revision(self):
        # Cloud Run v2 may report the revision image as configured (a tag):
        # accepted under the documented immutable-tag assumption.
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        self.assertEqual(self.run_gate(), 0, self.text())
        new_rev = next(r for r in c.revisions if r["name"] == c.service["latestReadyRevision"])
        self.assertEqual(new_rev["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertEqual(c.run_calls(), 1)

    def test_upgrade_with_tag_only_execution_and_digest_revision(self):
        c = self.cloud
        c.new_revision_image = fg.MIRROR_NEW_IMAGE
        self.assertEqual(self.run_gate(), 0, self.text())

    def test_bootstrap_with_mirror_digest_execution_and_task(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.resolve_images()
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("POST", "run"), ("PATCH", "job")])
        self.assertEqual(c.run_calls(), 1)
        self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "completed")
        self.assertEqual(c.job["template"]["template"]["containers"][0]["image"], fg.NEW_IMAGE)

    def test_same_image_adoption_with_digest_revision(self):
        c = self.cloud
        c.resolve_images()
        _same_image(c)
        for rev in c.revisions:
            rev["containers"][0]["image"] = fg.MIRROR_NEW_IMAGE
        revisions_before = len(c.revisions)
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertIn("no new revision needed", self.text())
        self.assertEqual(len(c.revisions), revisions_before)
        for body in c.service_patches():
            self.assertEqual(body["template"]["containers"][0]["image"], fg.NEW_IMAGE)

    def test_same_image_adoption_with_tag_only_revision(self):
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        _same_image(c)
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertIn("no new revision needed", self.text())

    def test_configured_digest(self):
        for configured in ("fleetdm/fleet@" + fg.NEW_DIGEST, "fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST):
            for bootstrap in (False, True):
                with self.subTest(configured=configured, bootstrap=bootstrap):
                    self.cloud = fg.FakeCloud(service=not bootstrap)
                    self.logs = []
                    environ = _with_configured_image(self.cloud, configured)
                    self.cloud.resolve_images()
                    self.assertEqual(self.run_gate(environ=environ), 0, self.text())
                    self.assertEqual(self.cloud.run_calls(), 1)
                    if not bootstrap:
                        self.assertEqual(self.cloud.service["template"]["containers"][0]["image"], configured)

    def test_artifact_registry_same_path_resolution(self):
        for bootstrap in (False, True):
            with self.subTest(bootstrap=bootstrap):
                self.cloud = fg.FakeCloud(service=not bootstrap)
                self.logs = []
                environ = _with_configured_image(self.cloud, AR_IMAGE)
                self.cloud.resolve_images(AR_RESOLVED)
                self.assertEqual(self.run_gate(environ=environ), 0, self.text())
                if not bootstrap:
                    self.assertEqual(self.cloud.service["template"]["containers"][0]["image"], AR_IMAGE)


BAD_RUNTIME_IMAGES = {
    "wrong_namespace": "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST,
    "wrong_repository": "mirror.gcr.io/fleetdm/fleet-other@" + fg.NEW_DIGEST,
    "library_namespace": "mirror.gcr.io/fleet@" + fg.NEW_DIGEST,
    "host_suffix_lookalike": "mirror.gcr.io.evil/fleetdm/fleet@" + fg.NEW_DIGEST,
    "host_prefix_lookalike": "evilmirror.gcr.io/fleetdm/fleet@" + fg.NEW_DIGEST,
    "gcr_io_is_not_docker_hub": "gcr.io/fleetdm/fleet@" + fg.NEW_DIGEST,
    "other_registry": "us-docker.pkg.dev/fleetdm/fleet@" + fg.NEW_DIGEST,
    "wrong_version_tag": "fleetdm/fleet:v4.92.0",
    "contradicting_tag_with_digest": "mirror.gcr.io/fleetdm/fleet:v4.92.0@" + fg.NEW_DIGEST,
    "uppercase_digest": "mirror.gcr.io/fleetdm/fleet@sha256:" + fg.NEW_DIGEST[7:].upper(),
    "short_digest": "mirror.gcr.io/fleetdm/fleet@" + fg.NEW_DIGEST[:-1],
    "sha512_digest": "mirror.gcr.io/fleetdm/fleet@sha512:" + "a" * 128,
    "empty_digest": "mirror.gcr.io/fleetdm/fleet@",
    "uppercase_repository": "mirror.gcr.io/FleetDM/fleet@" + fg.NEW_DIGEST,
    "empty": "",
    "not_a_string": 42,
}


def _make_bad_execution_image_test(image, task_only):
    def test(self):
        c = self.cloud
        if task_only:
            c.execution_image = fg.MIRROR_NEW_IMAGE
            c.task_image = image
        else:
            c.execution_image = image
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(c.run_calls(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assertIn("image", self.text())
        self.assert_not_resumed()
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]))
        if isinstance(image, str) and image:
            self.assertNotIn(image, self.text(), "reported image text is never echoed")
    return test


class ImageIdentityRefusals(OfflineTestCase):
    def assert_migrated_but_not_resumed(self):
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_SUCCEEDED, self.text())
        self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
        restores = [b for b in self.cloud.service_patches() if b["scaling"].get("scalingMode") != "MANUAL"]
        self.assertEqual(restores, [], "scaling is never restored")
        self.assert_no_old_image_restart()
        self.assert_not_claimed_measured_zero()

    def test_task_digest_conflicts_with_execution_digest(self):
        # For example an image index digest vs a platform manifest digest:
        # no mapping is attempted, the outcome is UNKNOWN.
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        c.task_image = "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("digest differs", self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assert_not_resumed()

    def test_bootstrap_wrong_execution_repository_never_completes(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.execution_image = "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(c.run_calls(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")

    def test_bootstrap_task_digest_conflict_never_completes(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.execution_image = fg.MIRROR_NEW_IMAGE
        c.task_image = "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")

    def test_configured_digest_mismatch_fails(self):
        for configured in ("fleetdm/fleet@" + fg.NEW_DIGEST, "fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST):
            for observed in ("mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST, fg.NEW_IMAGE):
                with self.subTest(configured=configured, observed=observed):
                    self.cloud = fg.FakeCloud()
                    self.logs = []
                    environ = _with_configured_image(self.cloud, configured)
                    self.cloud.execution_image = observed
                    self.assertEqual(self.run_gate(environ=environ), 1, self.text())
                    self.assertEqual(self.cloud.run_calls(), 1)
                    self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
                    self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
                    self.assertNotIn(configured, [b["template"]["containers"][0]["image"]
                                                  for b in self.cloud.service_patches()])

    def test_artifact_registry_other_location_or_project_fails(self):
        for observed in ("us-docker.pkg.dev/fleet-test-project/fleet/fleet@" + fg.NEW_DIGEST,
                         "us-central1-docker.pkg.dev/other-project/fleet/fleet@" + fg.NEW_DIGEST,
                         "mirror.gcr.io/fleet-test-project/fleet/fleet@" + fg.NEW_DIGEST):
            with self.subTest(observed=observed):
                self.cloud = fg.FakeCloud()
                self.logs = []
                environ = _with_configured_image(self.cloud, AR_IMAGE)
                self.cloud.execution_image = observed
                self.assertEqual(self.run_gate(environ=environ), 1, self.text())
                self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
                self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))

    def test_revision_digest_conflicts_with_execution_digest(self):
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        c.new_revision_image = "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST
        self.assert_migrated_but_not_resumed()
        self.assertIn("digest differs", self.text())

    def test_revision_wrong_repository_digest(self):
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        c.new_revision_image = "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST
        self.assert_migrated_but_not_resumed()

    def test_revision_wrong_tag(self):
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        c.new_revision_image = "fleetdm/fleet:v4.92.0"
        self.assert_migrated_but_not_resumed()

    def test_same_image_adoption_revision_digest_conflict(self):
        # The existing Ready revision was resolved from the same tag earlier,
        # but to another digest (a mutable tag): never adopted.
        c = self.cloud
        c.resolve_images()
        _same_image(c)
        for rev in c.revisions:
            rev["containers"][0]["image"] = "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST
        self.assert_migrated_but_not_resumed()
        self.assertIn("digest differs", self.text())

    def test_service_template_reading_back_a_digest_is_never_ready(self):
        # Configuration must stay the exact configured string: a template that
        # reads back as a digest (another writer) is not the target.
        c = self.cloud
        c.resolve_images()

        def rewrite(method, kind, path, query, body):
            cp = c.checkpoint() or {}
            if method == "GET" and kind == "service" and cp.get("phase") == "rolling-out":
                c.service["template"]["containers"][0]["image"] = fg.MIRROR_NEW_IMAGE
            return None
        c.faults.append(rewrite)
        self.assert_migrated_but_not_resumed()

    def test_invalid_configured_reference_makes_no_requests(self):
        for image in ("fleetdm/fleet@sha256:" + "A" * 64, "fleetdm/fleet@sha256:abc",
                      "fleetdm/fleet@sha512:" + "a" * 128, "FleetDM/fleet:v1", "fleetdm//fleet:v1"):
            with self.subTest(image=image):
                self.cloud.log.clear()
                self.logs.clear()
                self.assertEqual(self.run_gate(environ=fg.env(FLEET_GATE_IMAGE=image)), 1)
                self.assertEqual(self.cloud.log, [])
                self.assertIn("not a valid image reference", self.text())


for _name, _image in BAD_RUNTIME_IMAGES.items():
    setattr(ImageIdentityRefusals, "test_execution_image_" + _name, _make_bad_execution_image_test(_image, False))
    setattr(ImageIdentityRefusals, "test_task_image_" + _name, _make_bad_execution_image_test(_image, True))


PREFLIGHT_CASES_IMAGE = {
    # The job is configuration: a resolved digest there is drift, not the target.
    "job_image_resolved_digest": job_mutation(
        lambda j: j["template"]["template"]["containers"][0].update(image=fg.MIRROR_NEW_IMAGE)),
    "job_image_docker_io_spelling": job_mutation(
        lambda j: j["template"]["template"]["containers"][0].update(image="docker.io/fleetdm/fleet:v4.93.0")),
}
for _name, _setup in PREFLIGHT_CASES_IMAGE.items():
    setattr(PreflightRefusals, "test_refuses_" + _name, _make_preflight_test(_name, _setup))


def _set_execution_image(view, tasks, image):
    view["template"]["containers"][0]["image"] = image
    for task in tasks:
        task["containers"][0]["image"] = image


class OwnedExecutionImageRechecks(OfflineTestCase):
    """Every image the owned execution reports in this run is checked: while
    pending, at completion, and in every later inventory re-verification."""

    OTHER = "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST

    def pending_then_completed(self, pending, completed):
        polls = {"pending": 0}

        def hook(view, tasks, op):
            if view.get("completionTime"):
                _set_execution_image(view, tasks, completed)
            else:
                polls["pending"] += 1
                _set_execution_image(view, tasks, pending)
        self.cloud.execution_hook = hook
        return polls

    def assert_unknown_not_resumed(self, needle):
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(self.cloud.run_calls(), 1)
        self.assertIn(needle, self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        if self.cloud.service is not None:
            self.assertTrue(gate.is_stopped_scaling(self.cloud.service["scaling"]))
            restores = [b for b in self.cloud.service_patches() if b["scaling"].get("scalingMode") != "MANUAL"]
            self.assertEqual(restores, [], "scaling is never restored")
            self.assert_no_old_image_restart()
        else:
            self.assertEqual(json.loads(self.cloud.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")

    def test_pending_digest_then_other_digest_at_completion(self):
        for bootstrap in (False, True):
            with self.subTest(bootstrap=bootstrap):
                self.cloud = fg.FakeCloud(service=not bootstrap)
                self.logs = []
                polls = self.pending_then_completed(fg.MIRROR_NEW_IMAGE, self.OTHER)
                self.assert_unknown_not_resumed("execution image digest differs")
                self.assertGreater(polls["pending"], 0)
                self.assert_not_resumed()

    def test_pending_wrong_repository_fails_before_completion(self):
        c = self.cloud
        polls = self.pending_then_completed("mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST, fg.MIRROR_NEW_IMAGE)
        self.assert_unknown_not_resumed("execution image does not match the target Fleet image")
        self.assertGreater(polls["pending"], 0)
        self.assertIsNone(c.index("GET", "tasks"), "the gate fails on the pending poll, before completion")
        self.assertNotIn("FAILED: task", self.text())
        self.assert_not_resumed()

    def test_pending_same_digest_then_completion_succeeds(self):
        self.pending_then_completed(fg.MIRROR_NEW_IMAGE, fg.MIRROR_NEW_IMAGE)
        self.cloud.new_revision_image = fg.MIRROR_NEW_IMAGE
        self.assertEqual(self.run_gate(), 0, self.text())

    def changes_in_phase(self, phase):
        c = self.cloud
        c.resolve_images()

        def hook(view, tasks, op):
            if (c.checkpoint() or {}).get("phase") == phase:
                _set_execution_image(view, tasks, self.OTHER)
        c.execution_hook = hook

    def test_execution_digest_changes_before_new_image_write(self):
        self.changes_in_phase("migrated")
        self.assert_unknown_not_resumed("execution image digest differs")
        self.assert_not_resumed()

    def test_execution_digest_changes_during_rollout(self):
        self.changes_in_phase("rolling-out")
        self.assert_unknown_not_resumed("execution image digest differs")

    def test_execution_wrong_repository_during_rollout(self):
        c = self.cloud
        c.resolve_images()

        def hook(view, tasks, op):
            if (c.checkpoint() or {}).get("phase") == "rolling-out":
                _set_execution_image(view, tasks, "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST)
        c.execution_hook = hook
        self.assert_unknown_not_resumed("execution image does not match the target Fleet image")

    def test_bootstrap_execution_digest_changes_before_completion_record(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.resolve_images()
        state = {"tasks_read": False}

        def hook(view, tasks, op):
            # Only the execution changes, after its task was verified.
            if state["tasks_read"]:
                view["template"]["containers"][0]["image"] = self.OTHER

        def mark(method, kind, path, query, body):
            if method == "GET" and kind == "tasks":
                state["tasks_read"] = True
            return None
        c.execution_hook = hook
        c.faults.append(mark)
        self.assert_unknown_not_resumed("execution image digest differs")
        self.assertEqual(c.writes(), [("PATCH", "job"), ("POST", "run")])

    def test_completed_bootstrap_record_from_an_earlier_image_does_not_pin_this_run(self):
        # A completed record names an execution of an earlier image (another
        # digest). It is neither adopted nor re-verified as this run's
        # evidence: this run runs its own execution, which is pinned and
        # checked on its own digest.
        c = self.cloud = fg.FakeCloud(service=False)
        first = fg.MIRROR_NEW_IMAGE
        second = self.OTHER

        def hook(view, tasks, op):
            _set_execution_image(view, tasks, first if view["name"].endswith("x001") else second)
        c.execution_hook = hook
        self.assertEqual(self.run_gate(), 0, self.text())
        newer = "fleetdm/fleet:v4.94.0"
        generation = str(int(c.job["generation"]) + 1)
        c.job.update(generation=generation, observedGeneration=generation, etag=c.etag("job"))
        c.job["template"]["template"]["containers"][0]["image"] = newer
        c.log.clear()
        c.bodies.clear()
        self.logs = []
        self.assertEqual(self.run_gate(environ=fg.env(FLEET_GATE_RUN_ID="next-run", FLEET_GATE_IMAGE=newer,
                                                      FLEET_GATE_JOB_GENERATION=generation)), 0, self.text())
        self.assertEqual(c.run_calls(), 1)
        self.assertIn(fg.OTHER_DIGEST, self.text())
        self.assertNotIn(fg.NEW_DIGEST, self.text())


def _embedded_execution(view, image, **overrides):
    embedded = json.loads(json.dumps(view))
    embedded["template"]["containers"][0]["image"] = image
    embedded.update(overrides)
    return {k: v for k, v in embedded.items() if v is not None}


def _embed_in_operation(test, source, make):
    """Embed an Execution (built by make(view)) in the initial :run metadata,
    the polled operation metadata, or the successful operation response."""
    c = test.cloud
    if source == "initial":
        original = c._h_run

        def run(method, match, query, data):
            response = original(method, match, query, data)
            payload = json.loads(response.body)
            view, _, _ = c.render_execution(c.executions[-1])
            payload["metadata"] = make(view)
            return fg.FakeResponse(200, payload)
        c._h_run = run
    else:
        def hook(view, tasks, op):
            if source == "metadata" or "response" in op:
                op[source] = make(view)
        c.execution_hook = hook


class OperationEmbeddedExecutionImage(OwnedExecutionImageRechecks.__bases__[0]):
    OTHER = OwnedExecutionImageRechecks.OTHER
    assert_unknown_not_resumed = OwnedExecutionImageRechecks.assert_unknown_not_resumed

    def test_operation_embedded_execution_digest_conflicts(self):
        for bootstrap in (False, True):
            for source in ("initial", "metadata", "response"):
                with self.subTest(bootstrap=bootstrap, source=source):
                    self.cloud = fg.FakeCloud(service=not bootstrap)
                    self.logs = []
                    self.cloud.resolve_images()
                    _embed_in_operation(self, source, lambda v: _embedded_execution(v, self.OTHER))
                    self.assert_unknown_not_resumed("execution image digest differs")
                    self.assert_not_resumed()

    def test_operation_embedded_execution_wrong_repository(self):
        for source in ("initial", "metadata", "response"):
            with self.subTest(source=source):
                self.cloud = fg.FakeCloud()
                self.logs = []
                self.cloud.resolve_images()
                _embed_in_operation(self, source, lambda v: _embedded_execution(
                    v, "mirror.gcr.io/otherns/fleet@" + fg.NEW_DIGEST))
                self.assert_unknown_not_resumed("execution image does not match the target Fleet image")
                self.assert_not_resumed()

    def test_operation_embedding_another_execution_is_not_trusted(self):
        for source in ("initial", "metadata", "response"):
            with self.subTest(source=source):
                self.cloud = fg.FakeCloud()
                self.logs = []
                self.cloud.resolve_images()
                _embed_in_operation(self, source, lambda v: _embedded_execution(
                    v, fg.MIRROR_NEW_IMAGE, name=fg.JOB_NAME + "/executions/other"))
                # The initial metadata name defines the owned execution, so a
                # different name there is an unknown execution; later payloads
                # must embed the owned one.
                self.assert_unknown_not_resumed("unexpected job executions appeared" if source == "initial"
                                                else "embeds an execution other than this run's")
                self.assert_not_resumed()

    def test_operation_embedded_matching_execution_is_compatible(self):
        # Same digest; an embedded copy may omit uid/job. Name-only metadata
        # (the default fake) stays compatible too.
        for bootstrap in (False, True):
            for source in ("initial", "metadata", "response"):
                with self.subTest(bootstrap=bootstrap, source=source):
                    self.cloud = fg.FakeCloud(service=not bootstrap)
                    self.logs = []
                    self.cloud.resolve_images()
                    _embed_in_operation(self, source, lambda v: _embedded_execution(
                        v, fg.MIRROR_NEW_IMAGE, uid=None, job=None))
                    self.assertEqual(self.run_gate(), 0, self.text())
                    self.assertEqual(self.cloud.run_calls(), 1)



# ---------------------------------------------------------------------------
# Observed Cloud Run task shape (sanitized real tasks.list response)
# ---------------------------------------------------------------------------
#
# A real successful migration task has no uid, index, retried or reconciling,
# and lastAttemptResult is {"status": {}} (ProtoJSON omits the zero exit code,
# signal and status code). Its image is the configured tag while the execution
# reports the mirror.gcr.io digest. The gate binds the task by its resource
# name under the owned execution and its execution and job fields.

OBSERVED_TASK_ABSENT = ("uid", "index", "retried", "reconciling")
OBSERVED_EXECUTION_ABSENT = ("runningCount", "failedCount", "cancelledCount", "retriedCount", "reconciling")


def _observed_gate(logs):
    cfg = gate.Config(project="test-project", region="us-central1", service="fleet-api", job="fleet-migration",
                      image=fg.NEW_IMAGE, run_id=fg.RUN_ID, job_generation="1", trigger=fg.TRIGGER)
    g = gate.MigrationGate(cfg, api=None, clock=None, log=logs.append)
    g.execution_name = fg.OBSERVED["execution"]["name"]
    return g


class ObservedTaskShape(OfflineTestCase):
    def test_fixture_is_the_observed_shape(self):
        execution = fg.OBSERVED["execution"]
        page = fg.OBSERVED["tasks_page"]
        self.assertEqual(set(page), {"tasks"}, "one page, no nextPageToken")
        self.assertEqual(len(page["tasks"]), 1)
        task = page["tasks"][0]
        self.assertEqual(set(task), {
            "completionTime", "conditions", "containers", "createTime", "etag", "execution", "generation", "job",
            "lastAttemptResult", "name", "observedGeneration", "scheduledTime", "serviceAccount", "startTime",
            "timeout", "updateTime", "vpcAccess"})
        for field in OBSERVED_TASK_ABSENT:
            self.assertNotIn(field, task)
        for field in OBSERVED_EXECUTION_ABSENT:
            self.assertNotIn(field, execution)
        self.assertEqual(task["lastAttemptResult"], {"status": {}})
        self.assertEqual(task["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertEqual(execution["template"]["containers"][0]["image"], fg.MIRROR_NEW_IMAGE)

    def test_fixture_execution_and_task_verify(self):
        logs = []
        g = _observed_gate(logs)
        execution = copy.deepcopy(fg.OBSERVED["execution"])
        tasks = copy.deepcopy(fg.OBSERVED["tasks_page"]["tasks"])
        op = {"name": "projects/test-project/locations/us-central1/operations/x", "done": True,
              "response": copy.deepcopy(execution)}
        self.assertEqual(g.evaluate_execution(op, execution), "succeeded")
        self.assertEqual(g.image_digest, fg.NEW_DIGEST)
        g.verify_tasks(tasks)
        # The task's configured tag did not replace or weaken the pinned digest.
        self.assertEqual(g.image_digest, fg.NEW_DIGEST)

    def test_fixture_task_with_a_well_formed_uid_still_verifies(self):
        g = _observed_gate([])
        g.image_digest = fg.NEW_DIGEST
        task = copy.deepcopy(fg.OBSERVED_TASK)
        task["uid"] = "0f3c2b1a-0000-4000-8000-000000000000"
        g.verify_tasks([task])

    def test_fixture_task_refusals(self):
        exec_name = fg.OBSERVED["execution"]["name"]
        job_name = exec_name.split("/executions/")[0]
        cases = {
            "name_missing": lambda t: t.pop("name"),
            "name_not_string": lambda t: t.update(name=7),
            "name_empty_id": lambda t: t.update(name=exec_name + "/tasks/"),
            "name_nested_id": lambda t: t.update(name=exec_name + "/tasks/a/b"),
            "name_other_execution": lambda t: t.update(name=job_name + "/executions/other/tasks/other-task0"),
            "name_execution_prefix_lookalike": lambda t: t.update(name=exec_name + "x/tasks/x-task0"),
            "name_other_job": lambda t: t.update(name=exec_name.replace("/jobs/fleet-migration/", "/jobs/other/")),
            "name_short_form": lambda t: t.update(name="fleet-migration-real-task0"),
            "execution_missing": lambda t: t.pop("execution"),
            "execution_other": lambda t: t.update(execution="other"),
            "execution_full_name": lambda t: t.update(execution=exec_name),
            "job_missing": lambda t: t.pop("job"),
            "job_other": lambda t: t.update(job="other"),
            "index_nonzero": lambda t: t.update(index=1),
            "index_malformed": lambda t: t.update(index="x"),
            "retried": lambda t: t.update(retried="1"),
            "reconciling": lambda t: t.update(reconciling=True),
            "not_completed": lambda t: t.pop("completionTime"),
            "completed_condition_missing": lambda t: t.update(conditions=[t["conditions"][0]]),
            "completed_condition_pending": lambda t: t["conditions"][1].update(state="CONDITION_PENDING"),
            "other_condition_failed": lambda t: t["conditions"][0].update(state="CONDITION_FAILED"),
            "conditions_malformed": lambda t: t.update(conditions={"type": "Completed"}),
            "attempt_result_missing": lambda t: t.pop("lastAttemptResult"),
            "attempt_result_null": lambda t: t.update(lastAttemptResult=None),
            "exit_code_nonzero": lambda t: t["lastAttemptResult"].update(exitCode=1),
            "term_signal": lambda t: t["lastAttemptResult"].update(termSignal=15),
            "status_code_nonzero": lambda t: t["lastAttemptResult"]["status"].update(code=4),
            "image_other_tag": lambda t: t["containers"][0].update(image=fg.OLD_IMAGE),
            "image_other_digest": lambda t: t["containers"][0].update(
                image="mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST),
            "image_other_repository": lambda t: t["containers"][0].update(image="fleetdm/other:v4.93.0"),
            "image_missing": lambda t: t["containers"][0].pop("image"),
            "containers_missing": lambda t: t.pop("containers"),
            "two_containers": lambda t: t["containers"].append({"image": fg.NEW_IMAGE}),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                g = _observed_gate([])
                g.image_digest = fg.NEW_DIGEST
                task = copy.deepcopy(fg.OBSERVED_TASK)
                mutate(task)
                with self.assertRaises(gate.GateError):
                    g.verify_tasks([task])
        with self.subTest(name="no_task"):
            with self.assertRaises(gate.GateError):
                _observed_gate([]).verify_tasks([])
        with self.subTest(name="extra_task"):
            second = copy.deepcopy(fg.OBSERVED_TASK)
            second["name"] = exec_name + "/tasks/fleet-migration-real-task1"
            second["index"] = 1
            with self.assertRaises(gate.GateError):
                _observed_gate([]).verify_tasks([copy.deepcopy(fg.OBSERVED_TASK), second])

    def test_fake_renders_the_observed_task_shape(self):
        c = self.cloud
        c.resolve_images()
        self.assertEqual(self.run_gate(), 0, self.text())
        view, tasks, _ = c.render_execution(c.executions[0])
        self.assertEqual(len(tasks), 1)
        task = tasks[0]
        self.assertEqual(set(task), set(fg.OBSERVED_TASK))
        for field in OBSERVED_TASK_ABSENT:
            self.assertNotIn(field, task)
        for field in OBSERVED_EXECUTION_ABSENT:
            self.assertNotIn(field, view)
        self.assertEqual(task["lastAttemptResult"], {"status": {}})
        self.assertEqual(task["name"], view["name"] + "/tasks/" + view["name"].rsplit("/", 1)[-1] + "-task0")
        self.assertEqual(task["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertEqual(view["template"]["containers"][0]["image"], fg.MIRROR_NEW_IMAGE)

    def test_upgrade_with_observed_task_shape(self):
        c = self.cloud
        c.resolve_images()
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("PATCH", "service"), ("PATCH", "service"), ("POST", "run"),
                                      ("PATCH", "service"), ("PATCH", "service"), ("PATCH", "service")])
        self.assertEqual(c.run_calls(), 1)
        self.assertIn("verified successful", self.text())
        self.assertEqual(c.checkpoint()["phase"], "completed")
        self.assertEqual(c.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})
        self.assertEqual(c.service["template"]["containers"][0]["image"], fg.NEW_IMAGE)
        self.assertIn(fg.NEW_DIGEST, self.text())
        self.assert_no_old_image_restart()

    def test_upgrade_with_observed_task_shape_and_tag_only_revision(self):
        c = self.cloud
        c.execution_image = fg.MIRROR_NEW_IMAGE
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.checkpoint()["phase"], "completed")
        self.assertEqual(c.service["scaling"], {"scalingMode": "AUTOMATIC", "minInstanceCount": 1})

    def test_bootstrap_with_observed_task_shape(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.resolve_images()
        self.assertEqual(self.run_gate(), 0, self.text())
        self.assertEqual(c.writes(), [("PATCH", "job"), ("POST", "run"), ("PATCH", "job")])
        self.assertEqual(c.run_calls(), 1)
        cp = json.loads(c.job["annotations"][fg.CHECKPOINT])
        self.assertEqual(cp["phase"], "completed")
        self.assertEqual(cp["execution"], c.executions[0]["name"])
        self.assertIsNone(c.service, "the gate never creates the service; Terraform does after it succeeds")
        self.assertIn("verified successful", self.text())

    def test_task_reporting_the_resolved_digest_still_verifies(self):
        # Legitimate variant: the task reports the same digest the execution
        # reported (pinned), instead of the configured tag.
        for bootstrap in (False, True):
            with self.subTest(bootstrap=bootstrap):
                c = self.cloud = fg.FakeCloud(service=not bootstrap)
                self.logs = []
                c.resolve_images()
                c.task_image = fg.MIRROR_NEW_IMAGE
                self.assertEqual(self.run_gate(), 0, self.text())
                self.assertEqual(c.run_calls(), 1)
                _, tasks, _ = c.render_execution(c.executions[0])
                self.assertEqual(tasks[0]["containers"][0]["image"], fg.MIRROR_NEW_IMAGE)
                if bootstrap:
                    self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "completed")
                else:
                    self.assertEqual(c.checkpoint()["phase"], "completed")
                    self.assert_no_old_image_restart()

    def test_configured_digest_still_requires_the_task_to_report_it(self):
        # With a configured digest, a task that reports only a tag cannot be
        # compared with it and fails closed (the digest pin is not weakened).
        configured = "fleetdm/fleet:v4.93.0@" + fg.NEW_DIGEST
        environ = _with_configured_image(self.cloud, configured)
        self.cloud.resolve_images()
        self.cloud.task_image = fg.NEW_IMAGE
        self.assertEqual(self.run_gate(environ=environ), 1, self.text())
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assert_not_resumed()


def _task_mutation(fn):
    return _ex_hook(_completed_only(lambda v, t, o: fn(v, t)))


def _rename_task(name_fn):
    return _task_mutation(lambda v, t: t[0].update(name=name_fn(v)))


TASK_IDENTITY_CASES = {
    "task_name_missing": _task_mutation(lambda v, t: t[0].pop("name")),
    "task_name_malformed": _task_mutation(lambda v, t: t[0].update(name=["x"])),
    "task_name_empty_id": _rename_task(lambda v: v["name"] + "/tasks/"),
    "task_name_nested_id": _rename_task(lambda v: v["name"] + "/tasks/x/y"),
    "task_name_other_execution": _rename_task(lambda v: fg.JOB_NAME + "/executions/other/tasks/other-task0"),
    "task_name_execution_prefix_lookalike": _rename_task(lambda v: v["name"] + "0/tasks/x-task0"),
    "task_name_other_job_namespace": _rename_task(
        lambda v: v["name"].replace("/jobs/" + fg.JOB + "/", "/jobs/other/") + "/tasks/x-task0"),
    "task_execution_missing": _task_mutation(lambda v, t: t[0].pop("execution")),
    "task_execution_other": _task_mutation(lambda v, t: t[0].update(execution="fleet-migration-other")),
    "task_job_missing": _task_mutation(lambda v, t: t[0].pop("job")),
    "task_job_other": _task_mutation(lambda v, t: t[0].update(job="other-job")),
    "task_missing": _task_mutation(lambda v, t: t.clear()),
    "task_extra": _task_mutation(lambda v, t: t.append(dict(copy.deepcopy(t[0]), index=1,
                                                            name=t[0]["name"][:-1] + "1"))),
    "task_index_nonzero": _task_mutation(lambda v, t: t[0].update(index=1)),
    "task_retried_string": _task_mutation(lambda v, t: t[0].update(retried="2")),
    "task_not_completed": _task_mutation(lambda v, t: t[0].pop("completionTime")),
    "task_reconciling": _task_mutation(lambda v, t: t[0].update(reconciling=True)),
    "task_completed_failed": _task_mutation(lambda v, t: t[0].update(conditions=[
        {"type": "Started", "state": fg.OK}, {"type": "Completed", "state": fg.FAILED}])),
    "task_completed_missing": _task_mutation(lambda v, t: t[0].update(conditions=[{"type": "Started", "state": fg.OK}])),
    "task_attempt_result_missing": _task_mutation(lambda v, t: t[0].pop("lastAttemptResult")),
    "task_exit_code_nonzero_observed_shape": _task_mutation(
        lambda v, t: t[0].update(lastAttemptResult={"status": {}, "exitCode": 3})),
    "task_term_signal_observed_shape": _task_mutation(
        lambda v, t: t[0].update(lastAttemptResult={"status": {}, "termSignal": 9})),
    "task_status_code_observed_shape": _task_mutation(
        lambda v, t: t[0].update(lastAttemptResult={"status": {"code": 10}})),
}


class TaskIdentityFailures(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.cloud.resolve_images()  # observed mixed digest/tag shape


for _name, _setup in TASK_IDENTITY_CASES.items():
    setattr(TaskIdentityFailures, "test_no_resume_" + _name, _make_migration_test(_setup, gate.MIGRATION_UNKNOWN))


def _make_bootstrap_task_test(setup):
    def test(self):
        c = self.cloud = fg.FakeCloud(service=False)
        c.resolve_images()
        setup(self)
        self.assertEqual(self.run_gate(), 1, self.text())
        self.assertEqual(c.run_calls(), 1)
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        self.assertEqual(json.loads(c.job["annotations"][fg.CHECKPOINT])["phase"], "bootstrap-migrating")
        self.assertIsNone(c.service)
    return test


class BootstrapTaskIdentityFailures(OfflineTestCase):
    pass


for _name in ("task_name_missing", "task_name_other_execution", "task_execution_other", "task_job_other",
              "task_missing", "task_extra", "task_index_nonzero", "task_not_completed", "task_attempt_result_missing",
              "task_exit_code_nonzero_observed_shape"):
    setattr(BootstrapTaskIdentityFailures, "test_never_completes_" + _name,
            _make_bootstrap_task_test(TASK_IDENTITY_CASES[_name]))
