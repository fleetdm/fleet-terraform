"""Automatic recovery across consecutive applies (offline).

Every test keeps ONE FakeCloud for several consecutive gate runs, exactly as
consecutive `terraform apply` runs see the same project: a new Terraform run
id each time (the failed gate resource is tainted and replaced) and the
refreshed job generation. Clearing a fault between applies stands for the
underlying problem (database, configuration, API) having been fixed; nothing
else is edited between applies, in particular never the gate's records.

Checked on every apply: at most one new :run, never a :run while another
execution is active, and never a scaling restore before a verified migration
and a Ready target revision (fake invariants, see FakeCloud.violations).

Run from the repository root with the rest of the suite:

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s gcp/byo-project/scripts/tests -v
"""

import hashlib
import json
import os
import re
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import test_fleet_migration_gate as base  # noqa: E402

fg = base.fg
gate = base.gate

# The fake service's pre-migration scaling, as the service reports it and as
# the gate records it.
ORIGINAL = {"scalingMode": "AUTOMATIC", "minInstanceCount": 1}
ORIGINAL_RECORDED = {"scalingMode": "AUTOMATIC", "minInstanceCount": 1, "maxInstanceCount": 0}
NEWER_IMAGE = "fleetdm/fleet:v4.94.0"


def record_of(resource):
    raw = ((resource or {}).get("annotations") or {}).get(fg.CHECKPOINT)
    return json.loads(raw) if raw else None


def phase_of(body):
    cp = record_of(body)
    return cp["phase"] if cp else None


class Applies(base.OfflineTestCase):
    """Consecutive applies against one persistent fake project."""

    def setUp(self):
        super().setUp()
        self.new_cloud()

    def new_cloud(self, service=True):
        """A fresh project in the observed native shape: the execution (and
        new revisions) report the mirror.gcr.io digest, the task keeps the
        configured tag and omits uid/index/retried."""
        self.cloud = fg.FakeCloud(service=service)
        self.cloud.resolve_images()
        self.applies = 0
        self.run_ids = []
        return self.cloud

    def apply(self, expect=None, max_runs=1, **env):
        c = self.cloud
        self.applies += 1
        run_id = f"0b6c7c55-1d5e-4c1c-9a4e-{self.applies:012d}"
        self.run_ids.append(run_id)
        c.log.clear()
        c.bodies.clear()
        self.logs = []
        executions_before = len(c.executions)
        environ = fg.env(FLEET_GATE_RUN_ID=run_id, FLEET_GATE_JOB_GENERATION=c.job["generation"], **env)
        code = self.run_gate(environ=environ)
        # max_runs > 1 only where another apply runs nested inside this one.
        self.assertLessEqual(c.run_calls(), max_runs, "at most one fresh migration :run per apply")
        own = [e for e in c.executions[executions_before:] if not e.get("_prior")]
        self.assertLessEqual(len(own), max_runs, "at most one new migration execution per apply")
        if expect is not None:
            self.assertEqual(code, expect, self.text())
        return code

    def fix(self):
        """The underlying problem is resolved (faults cleared). The gate's
        records and the actual cloud state are left exactly as they are."""
        c = self.cloud
        c.faults.clear()
        c.outcome = "success"
        c.execution_hook = None
        c.metric_override = None
        c.series_hook = None
        c.no_metrics_for = set()
        c.no_metrics_after_stop_for = set()
        c.new_revision_ready = True
        c.new_revision_fail = False
        c.task_image = None
        c.new_revision_hook = None
        c.resolve_images()

    def latest_run(self):
        return self.run_ids[-1]

    def assert_stopped_with_original(self):
        c = self.cloud
        self.assertTrue(gate.is_stopped_scaling(c.service["scaling"]), "Fleet must stay stopped")
        cp = c.checkpoint()
        self.assertIsNotNone(cp)
        self.assertEqual(cp["pre_scaling"], ORIGINAL_RECORDED, "the original pre-migration scaling is kept")

    def assert_resumed(self, image=fg.NEW_IMAGE):
        c = self.cloud
        self.assertEqual(c.service["scaling"], ORIGINAL, "the ORIGINAL pre-migration scaling is restored")
        cp = c.checkpoint()
        self.assertEqual((cp["run"], cp["phase"]), (self.latest_run(), "completed"))
        self.assertEqual(cp["pre_scaling"], ORIGINAL_RECORDED)
        self.assertEqual(c.service["template"]["containers"][0]["image"], image)
        self.assertEqual(c.service["latestReadyRevision"], c.service["latestCreatedRevision"])
        self.assertEqual(c.run_calls(), 1, "the recovering apply ran exactly one fresh migration")
        newest = c.executions[-1]
        self.assertTrue(c.execution_finished(newest) and newest["_outcome"] == "success")
        self.assertIn("verified successful", self.text())
        self.assertNotIn("FAILED:", self.text())


# ---------------------------------------------------------------------------
# Upgrade: failure or interruption at every mutation boundary, then recovery
# ---------------------------------------------------------------------------


def _applied_then(kind, nth, status, predicate=lambda body: True):
    """The nth write of kind is applied, but its response is lost."""
    def setup(test):
        c = test.cloud
        state = {"n": 0}

        def fault(method, k, path, query, body):
            if method != "GET" and k == kind and predicate(body):
                state["n"] += 1
                if state["n"] == nth:
                    handler = getattr(c, "_h_" + kind.replace("-", "_"))
                    handler(method, None, query, body)
                    return fg.error(status, "UNAVAILABLE") if status != 504 else fg.FakeResponse(504, raw=b"")
            return None
        c.faults.append(fault)
    return setup


def _run_applied_then_lost(test):
    c = test.cloud

    def fault(method, k, path, query, body):
        if method == "POST" and k == "run":
            c._h_run(method, None, query, body)
            return fg.FakeResponse(504, raw=b"")
        return None
    c.faults.append(fault)


def _run_not_applied(status):
    def setup(test):
        test.cloud.faults.append(lambda m, k, p, q, b: fg.error(status, "UNAVAILABLE") if k == "run" else None)
    return setup


def _attr(name, value):
    def setup(test):
        setattr(test.cloud, name, value)
    return setup


def _hook(fn):
    def setup(test):
        test.cloud.execution_hook = base._completed_only(fn)
    return setup


def _tasks_api_down(test):
    test.cloud.faults.append(lambda m, k, p, q, b: fg.error(503, "UNAVAILABLE") if k == "tasks" else None)


def _restore_unreadable(test):
    c = test.cloud

    def fault(method, k, path, query, body):
        if c.restore_time is not None and method == "GET" and k in ("service", "operation"):
            return fg.error(503, "UNAVAILABLE")
        return None
    c.faults.append(fault)


def _restore_mismatch(test):
    c = test.cloud
    original = c._h_service

    def fault(method, k, path, query, body):
        if method == "PATCH" and k == "service" and body.get("scaling", {}).get("scalingMode") == "AUTOMATIC":
            return original(method, None, query, dict(body, scaling={"scalingMode": "AUTOMATIC",
                                                                     "minInstanceCount": 7}))
        return None
    c.faults.append(fault)


def _restore_and_restop_fail(test):
    test.cloud.faults.append(base._fail_nth_write("service", 5, fg.error(503, "UNAVAILABLE")))
    test.cloud.faults.append(base._fail_nth_write("service", 6, fg.error(503, "UNAVAILABLE")))


# name -> (setup, whether Fleet is left stopped by the failed apply)
UPGRADE_FAILURES = {
    "job_claim_rejected": (lambda t: t.cloud.faults.append(base._fail_nth_write("job", 1, fg.error(409, "ABORTED"))),
                           False),
    "job_claim_applied_response_lost": (_applied_then("job", 1, 503), False),
    "stop_rejected": (lambda t: t.cloud.faults.append(base._fail_nth_write("service", 1, fg.error(409, "ABORTED"))),
                      False),
    "stop_applied_response_lost": (_applied_then("service", 1, 500), True),
    "zero_timeout": (lambda t: t.cloud.no_metrics_after_stop_for.add("fleet-api-00001-aaa"), True),
    "intent_write_rejected": (lambda t: t.cloud.faults.append(
        base._fail_nth_write("service", 2, fg.error(409, "ABORTED"))), True),
    "intent_write_applied_response_lost": (_applied_then("service", 2, 503), True),
    "run_rejected": (lambda t: t.cloud.faults.append(lambda m, k, p, q, b: fg.error(409, "ABORTED")
                                                     if k == "run" else None), True),
    "run_not_applied_5xx": (_run_not_applied(503), True),
    "run_accepted_response_lost": (_run_applied_then_lost, True),
    "migration_failed": (_attr("outcome", "fail"), True),
    "migration_cancelled": (_attr("outcome", "cancel"), True),
    "migration_then_tasks_api_down": (_tasks_api_down, True),
    "migration_then_task_validator_failure": (_hook(lambda v, t, o: t[0].update(lastAttemptResult={"unknown": 0})),
                                              True),
    "migration_then_task_image_conflict": (lambda t: (t.cloud.resolve_images(), setattr(
        t.cloud, "task_image", "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST)), True),
    "migrated_checkpoint_rejected": (lambda t: t.cloud.faults.append(
        base._fail_nth_write("service", 3, fg.error(409, "ABORTED"))), True),
    "migrated_checkpoint_applied_response_lost": (_applied_then("service", 3, 503), True),
    "rollout_write_rejected": (lambda t: t.cloud.faults.append(
        base._fail_nth_write("service", 4, fg.error(409, "ABORTED"))), True),
    "rollout_write_applied_response_lost": (_applied_then("service", 4, 503), True),
    "rollout_failed": (_attr("new_revision_fail", True), True),
    "restore_rejected_then_restopped": (lambda t: t.cloud.faults.append(
        base._fail_nth_write("service", 5, fg.error(409, "ABORTED"))), True),
    "restore_applied_but_unreadable": (_restore_unreadable, False),
    "restore_mismatch_then_restopped": (_restore_mismatch, True),
    "restore_and_restop_both_fail": (_restore_and_restop_fail, True),
}


class UpgradeRecovery(Applies):
    """Failure at each boundary (apply A), underlying cause fixed, then a
    plain apply (B) recovers with the original scaling."""

    def check_recovers(self, name):
        setup, stopped = UPGRADE_FAILURES[name]
        setup(self)
        self.apply(expect=1)
        self.assertNotIn("emove the", self.text())
        if stopped:
            self.assert_stopped_with_original()
        self.fix()
        if name == "run_accepted_response_lost":
            # The execution A may have started is still running when B
            # starts: B waits (read-only) for it to settle, never overlaps it.
            self.assertFalse(self.cloud.execution_finished(self.cloud.executions[-1]))
        self.apply(expect=0)
        self.assert_resumed()
        if name == "run_accepted_response_lost":
            self.assertIn("waiting before any migration", self.text())


for _name in UPGRADE_FAILURES:
    setattr(UpgradeRecovery, "test_recovers_after_" + _name,
            lambda self, n=_name: self.check_recovers(n))


class RepeatedFailuresKeepOriginalScaling(Applies):
    """A and B fail at different boundaries; C succeeds with the original."""

    PAIRS = [
        ("stop_applied_response_lost", "zero_timeout"),
        ("migration_failed", "rollout_failed"),
        ("run_accepted_response_lost", "migration_then_task_validator_failure"),
        ("rollout_failed", "restore_rejected_then_restopped"),
        ("restore_mismatch_then_restopped", "migration_failed"),
        ("intent_write_applied_response_lost", "restore_and_restop_both_fail"),
    ]

    def test_pairs(self):
        for first, second in self.PAIRS:
            with self.subTest(first=first, second=second):
                self.new_cloud()
                UPGRADE_FAILURES[first][0](self)
                self.apply(expect=1)
                self.assert_stopped_with_original()
                self.fix()
                UPGRADE_FAILURES[second][0](self)
                self.apply(expect=1)
                self.assert_stopped_with_original()
                self.fix()
                self.apply(expect=0)
                self.assert_resumed()

    def test_many_failures_then_success(self):
        for _ in range(4):
            self.cloud.outcome = "fail"
            self.apply(expect=1)
            self.assert_stopped_with_original()
        self.fix()
        self.apply(expect=0)
        self.assert_resumed()
        self.assertEqual(len(self.cloud.executions), 5)

    def test_api_variants(self):
        """Job etag stable or changing on :run; annotation writes bumping job
        generation or not (observed live: not)."""
        for run_etag in (False, True):
            for bumps in (False, True):
                with self.subTest(run_changes_job_etag=run_etag, metadata_bumps_generation=bumps):
                    self.new_cloud()
                    self.cloud.run_changes_job_etag = run_etag
                    self.cloud.job_metadata_bumps_generation = bumps
                    _run_applied_then_lost(self)
                    self.apply(expect=1)
                    self.fix()
                    self.cloud.outcome = "fail"
                    self.apply(expect=1)
                    self.fix()
                    self.apply(expect=0)
                    self.assert_resumed()


class MigrationStillRunning(Applies):
    def test_never_finishing_execution_is_waited_for_then_retried(self):
        c = self.cloud
        c.outcome = "never"
        self.apply(expect=1)
        self.assertIn("Migration: " + gate.MIGRATION_UNKNOWN, self.text())
        stuck = c.executions[-1]
        self.fix()
        # B: the earlier execution is still running: bounded read-only wait,
        # then fail WITHOUT starting a new execution and without any write.
        self.apply(expect=1)
        self.assert_not_run()
        self.assert_no_writes()
        self.assertIn("have not settled", self.text())
        self.assertIn("a later terraform apply re-checks automatically", self.text())
        self.assert_stopped_with_original()
        # Cloud Run ends it at its task timeout; the next apply recovers.
        c.set_execution_outcome(stuck, "fail")
        self.apply(expect=0)
        self.assert_resumed()

    def test_lost_run_response_whose_execution_already_settled(self):
        for outcome in ("success", "fail"):
            with self.subTest(outcome=outcome):
                c = self.new_cloud()
                c.outcome = outcome
                _run_applied_then_lost(self)
                self.apply(expect=1)
                self.fix()
                c.clock.t += 1000  # it settled before the next apply started
                self.apply(expect=0)
                self.assertNotIn("waiting before any migration", self.text())
                self.assert_resumed()

    def test_execution_settling_during_the_wait_is_not_overlapped(self):
        c = self.cloud
        c.migration_duration = 2000
        _run_applied_then_lost(self)
        self.apply(expect=1)
        self.fix()
        self.apply(expect=0)
        self.assert_resumed()
        self.assertIn("waiting before any migration", self.text())


# ---------------------------------------------------------------------------
# Failed / reconciling / late-ready rollouts
# ---------------------------------------------------------------------------


class RolloutRecovery(Applies):
    def forced_names(self):
        return [b["template"].get("revision") for b in self.cloud.service_patches()
                if phase_of(b) == "rolling-out" and b["template"].get("revision")]

    def test_failed_rollout_is_redeployed_under_a_fresh_explicit_name(self):
        c = self.cloud
        c.new_revision_fail = True
        self.apply(expect=1)
        self.assertEqual(c.service["terminalCondition"]["state"], fg.FAILED)
        failed = c.service["latestCreatedRevision"].rsplit("/", 1)[-1]
        self.assertNotEqual(c.service["latestReadyRevision"], c.service["latestCreatedRevision"])
        # A's rollout let Google name the revision.
        a_rollout = [b for b in c.bodies if b[1] == "service" and phase_of(b[2]) == "rolling-out"]
        self.assertNotIn("revision", a_rollout[0][2]["template"])
        self.fix()
        self.apply(expect=0)
        self.assert_resumed()
        names = self.forced_names()
        self.assertEqual(len(names), 1)
        expected = "fleet-api-g" + hashlib.sha256(f"{self.latest_run()}/0".encode()).hexdigest()[:10]
        self.assertEqual(names[0], expected)
        self.assertLessEqual(len(names[0]), 63)
        self.assertTrue(re.fullmatch(r"fleet-api-[a-z0-9-]*[a-z0-9]", names[0]))
        self.assertNotEqual(names[0], failed)
        self.assertEqual(c.service["latestReadyRevision"].rsplit("/", 1)[-1], names[0])
        self.assertIn("deployed again as new revision", self.text())

    def test_forced_name_skips_names_already_in_the_inventory(self):
        c = self.cloud
        c.new_revision_fail = True
        self.apply(expect=1)
        self.fix()
        taken = "fleet-api-g" + hashlib.sha256(
            f"0b6c7c55-1d5e-4c1c-9a4e-{2:012d}/0".encode()).hexdigest()[:10]
        c.revisions.insert(0, c._revision(taken, fg.OLD_IMAGE, deleted=True))
        self.apply(expect=0)
        names = self.forced_names()
        expected = "fleet-api-g" + hashlib.sha256(f"{self.latest_run()}/1".encode()).hexdigest()[:10]
        self.assertEqual(names, [expected])

    def test_changed_template_after_failed_rollout_omits_the_name(self):
        c = self.cloud
        c.new_revision_fail = True
        self.apply(expect=1)
        self.fix()
        # The operator also moved to a newer image: a normal changed-template
        # rollout, named by Google.
        c.job["template"]["template"]["containers"][0]["image"] = NEWER_IMAGE
        c.job["generation"] = c.job["observedGeneration"] = str(int(c.job["generation"]) + 1)
        self.apply(expect=0, FLEET_GATE_IMAGE=NEWER_IMAGE, FLEET_GATE_TRIGGER="b" * 64)
        self.assert_resumed(image=NEWER_IMAGE)
        self.assertEqual(self.forced_names(), [])

    def assert_failed_reconciliation(self):
        """Cloud Run's documented settled failed-reconciliation shape."""
        svc = self.cloud.service
        self.assertIs(svc.get("reconciling", False), False)
        self.assertEqual(svc["terminalCondition"]["state"], fg.FAILED)
        self.assertLess(int(svc["observedGeneration"]), int(svc["generation"]),
                        "observedGeneration keeps the last serving generation")
        self.assertNotEqual(svc["latestReadyRevision"], svc["latestCreatedRevision"])

    def watch_lagging_reads(self):
        """Records every service read of the recovering run that still shows
        the failed-reconciliation shape before its own rollout."""
        c = self.cloud
        seen = []

        def fault(method, k, path, query, body):
            if method == "GET" and k == "service" and c.service and gate.failed_reconciliation(c.service):
                seen.append((phase_of(c.service), (record_of(c.service) or {}).get("run")))
            return None
        c.faults.append(fault)
        return seen

    def test_settled_failed_revision_left_by_reconciling_rollout(self):
        c = self.cloud
        c.new_revision_ready = False
        self.apply(expect=1)
        c.finish_pending_revision(ready=False)
        self.assert_failed_reconciliation()
        self.fix()
        seen = self.watch_lagging_reads()
        self.apply(expect=0)
        self.assert_resumed()
        self.assertEqual(len(self.forced_names()), 1)
        self.assertIn(("migrated", self.latest_run()), seen)

    def test_native_failed_reconciliation_then_fix_then_plain_apply(self):
        """Failed rollout with native generation semantics: observedGeneration
        stays at the last serving generation through the failed apply and
        through every metadata/scaling write of the recovering apply, until
        that apply's own new revision is Ready."""
        c = self.cloud
        c.new_revision_fail = True
        self.apply(expect=1)
        self.assert_failed_reconciliation()
        # The last serving generation is the one before the failed rollout
        # write (the stop and phase writes reconciled successfully).
        self.assertEqual(int(c.service["observedGeneration"]), int(c.service["generation"]) - 1)
        self.assert_stopped_with_original()
        self.fix()
        seen = self.watch_lagging_reads()
        executions = len(c.executions)
        self.apply(expect=0)
        self.assert_resumed()
        self.assertEqual(len(c.executions), executions + 1, "one fresh migration")
        names = self.forced_names()
        self.assertEqual(len(names), 1, "a genuinely new revision was deployed")
        self.assertEqual(c.service["latestReadyRevision"].rsplit("/", 1)[-1], names[0])
        self.assertEqual(c.service["observedGeneration"], c.service["generation"])
        self.assertEqual(c.service["terminalCondition"]["state"], fg.OK)
        run = self.latest_run()
        for phase in ("stopped", "migrating", "migrated"):
            self.assertIn((phase, run), seen, f"the lagging shape persisted through the {phase} write")

    def test_failed_reconciliation_still_waits_or_refuses_outside_the_exemption(self):
        c = self.cloud
        # Running service without a gate record in the failed shape: the
        # strict preflight refuses without writing anything.
        c.service.update(generation="8", observedGeneration="7", terminalCondition={"state": fg.FAILED})
        self.apply(expect=1)
        self.assert_no_writes()
        self.assertIn("observedGeneration does not match generation", self.text())
        # Stopped under a valid record but still reconciling: bounded wait,
        # then fail without writing; reconciling=false + FAILED proceeds.
        c = self.new_cloud()
        c.new_revision_fail = True
        self.apply(expect=1)
        self.fix()
        c.service["reconciling"] = True
        self.apply(expect=1)
        self.assertIn("still reconciling", self.text())
        self.assert_no_writes()
        c.service["reconciling"] = False
        self.apply(expect=0)
        self.assert_resumed()

    def test_late_ready_rollout_is_verified_without_a_new_revision(self):
        c = self.cloud
        c.new_revision_ready = False
        self.apply(expect=1)
        c.finish_pending_revision(ready=True)
        self.fix()
        revisions = len(c.revisions)
        self.apply(expect=0)
        self.assert_resumed()
        self.assertEqual(len(c.revisions), revisions)
        self.assertIn("no new revision needed", self.text())

    def test_still_reconciling_service_is_waited_for_then_retried(self):
        c = self.cloud
        c.new_revision_ready = False
        self.apply(expect=1)
        self.fix()
        self.apply(expect=1)
        self.assertIn("still reconciling", self.text())
        self.assert_no_writes()
        self.assert_not_run()
        self.assert_stopped_with_original()
        c.finish_pending_revision(ready=True)
        self.apply(expect=0)
        self.assert_resumed()

    def test_service_that_settles_during_the_wait(self):
        c = self.cloud
        c.new_revision_ready = False
        self.apply(expect=1)
        self.fix()
        state = {"reads": 0}

        def settle(method, k, path, query, body):
            if method == "GET" and k == "service" and c.service.get("reconciling"):
                state["reads"] += 1
                if state["reads"] == 3:
                    c.finish_pending_revision(ready=True)
            return None
        c.faults.append(settle)
        self.apply(expect=0)
        self.assert_resumed()

    def test_stale_failed_status_of_the_previous_generation_is_not_this_rollouts_failure(self):
        c = self.cloud
        c.new_revision_fail = True
        self.apply(expect=1)
        self.fix()
        # B's forced rollout first reports the previous generation's FAILED
        # terminal condition while reconciling, then becomes Ready.
        c.new_revision_ready = False
        state = {"polls": 0}

        def fault(method, k, path, query, body):
            if method == "GET" and k == "operation" and c.service.get("reconciling"):
                self.assertEqual(c.service["terminalCondition"]["state"], fg.FAILED)
                return fg.FakeResponse(200, {"name": fg.LOC + "/operations/" + path.rsplit("/", 1)[-1],
                                             "done": True, "response": {"name": fg.SVC_NAME}})
            if method == "GET" and k == "service" and c.service.get("reconciling") and phase_of(
                    c.service) == "rolling-out":
                state["polls"] += 1
                if state["polls"] == 3:
                    c.finish_pending_revision(ready=True)
            return None
        c.faults.append(fault)
        self.apply(expect=0)
        self.assertGreaterEqual(state["polls"], 3)
        self.assert_resumed()


class FailedReconciliationUnit(unittest.TestCase):
    def test_shape(self):
        ok = {"reconciling": False, "terminalCondition": {"state": fg.FAILED}, "generation": "9",
              "observedGeneration": "7"}
        self.assertTrue(gate.failed_reconciliation(ok))
        self.assertTrue(gate.failed_reconciliation(dict(ok, observedGeneration="9")))
        for bad in (dict(ok, reconciling=True), dict(ok, terminalCondition={"state": fg.OK}),
                    dict(ok, observedGeneration="10"), dict(ok, observedGeneration="0"),
                    {k: v for k, v in ok.items() if k != "observedGeneration"}, dict(ok, observedGeneration="x"),
                    dict(ok, terminalCondition=None)):
            with self.subTest(bad=bad):
                self.assertFalse(gate.failed_reconciliation(bad))


class RevisionNameUnit(unittest.TestCase):
    def gate_for(self, logs):
        cfg = gate.Config(project=fg.PROJECT, region=fg.REGION, service=fg.SERVICE, job=fg.JOB, image=fg.NEW_IMAGE,
                          run_id=fg.RUN_ID, job_generation="1", trigger=fg.TRIGGER)
        return gate.MigrationGate(cfg, api=None, clock=None, log=logs.append)

    def test_new_revision_ready_ignores_stale_status_until_settled(self):
        g = self.gate_for([])
        desired = gate.ServingConfig(fg.NEW_IMAGE, fg.fleet_env(), None)
        stale = {"reconciling": True, "generation": "9", "observedGeneration": "8",
                 "terminalCondition": {"state": fg.FAILED}}
        self.assertFalse(g.new_revision_ready(stale, "old", desired, "9"))
        stale_observed = dict(stale, reconciling=False)
        self.assertFalse(g.new_revision_ready(stale_observed, "old", desired, "9"))
        settled = dict(stale, reconciling=False, observedGeneration="9")
        with self.assertRaises(gate.GateError):
            g.new_revision_ready(settled, "old", desired, "9")

    def test_fake_validates_provided_revision_names_realistically(self):
        c = fg.FakeCloud()
        url = "https://run.googleapis.com/v2/" + fg.SVC_NAME
        auth = {"Authorization": "Bearer " + fg.TOKEN}

        def patch(name):
            body = {k: v for k, v in json.loads(json.dumps(c.service)).items() if k not in fg.SERVICE_OUTPUT_ONLY}
            body["template"]["revision"] = name
            return c.request("PATCH", url, auth, json.dumps(body).encode()).status

        self.assertEqual(patch("other-svc-abc"), 400, "must carry the service-name prefix")
        self.assertEqual(patch("fleet-api-" + "a" * 60), 400, "at most 63 characters")
        self.assertEqual(patch("fleet-api-Bad"), 400)
        self.assertEqual(patch("fleet-api-00001-aaa"), 409, "never reuse an existing name")
        self.assertEqual(patch("fleet-api-gfresh01"), 200, "a fresh valid name creates a new revision")
        self.assertEqual(c.service["latestCreatedRevision"], fg.SVC_NAME + "/revisions/fleet-api-gfresh01")


# ---------------------------------------------------------------------------
# Long stop with missing telemetry; image/trigger change between applies
# ---------------------------------------------------------------------------


class ContradictoryReadyRevision(Applies):
    def test_ready_revision_contradicting_its_template_needs_a_config_change(self):
        """Surfaced limitation (not a record latch): if the Ready revision of a
        template that matches the target reports a runtime image that is not
        that template's image (a platform contradiction, or a mutable tag
        resolved to a different digest), a retry re-verifies the same
        revision and fails again; the gate does not invent a redeploy for
        it. Changing the image configuration (an immutable tag or a digest)
        makes the next plain apply recover."""
        c = self.cloud
        c.new_revision_image = fg.OLD_IMAGE
        self.apply(expect=1)
        self.assert_stopped_with_original()
        self.fix()
        c.new_revision_image = None
        c.revisions[-1]["containers"][0]["image"] = fg.OLD_IMAGE  # the existing revision does not change
        self.apply(expect=1)
        self.assertIn("serving revision image does not match the target Fleet image", self.text())
        self.assert_stopped_with_original()
        c.job["template"]["template"]["containers"][0]["image"] = NEWER_IMAGE
        c.job["generation"] = c.job["observedGeneration"] = str(int(c.job["generation"]) + 1)
        self.apply(expect=0, FLEET_GATE_IMAGE=NEWER_IMAGE, FLEET_GATE_TRIGGER="f" * 64)
        self.assert_resumed(image=NEWER_IMAGE)


class LongStopAndTargetChange(Applies):
    def test_long_stop_with_missing_metrics_fails_without_execution_then_recovers(self):
        c = self.cloud
        c.outcome = "fail"
        self.apply(expect=1)
        self.fix()
        c.clock.t += 48 * 3600
        c.no_metrics_for = {r["name"].rsplit("/", 1)[-1] for r in c.revisions}
        self.apply(expect=1)
        self.assert_not_run()
        self.assertIn("no verified actual zero", self.text())
        self.assertIn("goes on to the bounded post-claim zero proof", self.text(),
                      "missing initial coverage alone does not latch recovery")
        self.assert_stopped_with_original()
        self.assertEqual(c.checkpoint()["run"], self.latest_run(), "the record is this run's claim, not a lock")
        self.fix()
        self.apply(expect=0)
        self.assert_resumed()

    def test_image_and_trigger_change_between_applies(self):
        c = self.cloud
        c.outcome = "fail"
        self.apply(expect=1)
        self.fix()
        c.job["template"]["template"]["containers"][0]["image"] = NEWER_IMAGE
        c.job["template"]["template"]["containers"][0]["env"] = fg.fleet_env(fg.NEW_DB_ADDRESS)
        c.job["generation"] = c.job["observedGeneration"] = str(int(c.job["generation"]) + 1)
        self.apply(expect=0, FLEET_GATE_IMAGE=NEWER_IMAGE, FLEET_GATE_TRIGGER="c" * 64)
        self.assert_resumed(image=NEWER_IMAGE)
        env = gate.normalize_env(c.service["template"]["containers"][0]["env"])
        self.assertEqual(env["FLEET_MYSQL_ADDRESS"], ("value", fg.NEW_DB_ADDRESS))

    def test_image_change_after_completed_rollout_but_failed_restore(self):
        c = self.cloud
        c.faults.append(base._fail_nth_write("service", 5, fg.error(409, "ABORTED")))
        self.apply(expect=1)
        self.assertEqual(c.checkpoint()["phase"], "failed")
        self.fix()
        c.job["template"]["template"]["containers"][0]["image"] = NEWER_IMAGE
        c.job["generation"] = c.job["observedGeneration"] = str(int(c.job["generation"]) + 1)
        self.apply(expect=0, FLEET_GATE_IMAGE=NEWER_IMAGE, FLEET_GATE_TRIGGER="d" * 64)
        self.assert_resumed(image=NEWER_IMAGE)


# ---------------------------------------------------------------------------
# Earlier records: valid ones keep their scaling; untrusted ones confer nothing
# ---------------------------------------------------------------------------


class EarlierRecords(Applies):
    def set_record(self, record, stopped):
        c = self.cloud
        c.service["annotations"][fg.CHECKPOINT] = record if isinstance(record, str) else json.dumps(record)
        if stopped:
            c.service["scaling"] = {"scalingMode": "MANUAL", "manualInstanceCount": 0}
            c.stop_time = fg.START - 3600

    def test_valid_record_with_extra_keys_and_other_image(self):
        self.set_record({"v": 1, "run": "old-run", "phase": "migrating", "image": "fleetdm/fleet:v4.90.0",
                         "trigger": "e" * 64, "extra": {"anything": True},
                         "pre_scaling": {"maxInstanceCount": 0, "scalingMode": "AUTOMATIC", "minInstanceCount": 1}},
                        stopped=True)
        self.apply(expect=0)
        self.assert_resumed()

    def test_unfinished_record_on_running_service_keeps_recorded_scaling(self):
        self.set_record({"v": 1, "run": "other", "phase": "migrating", "pre_scaling": {"scalingMode": "AUTOMATIC"}},
                        stopped=False)
        self.apply(expect=0)
        self.assertEqual(self.cloud.service["scaling"], {"scalingMode": "AUTOMATIC"})

    def test_failed_record_with_empty_scaling_is_a_valid_automatic_scaling(self):
        self.set_record({"v": 1, "run": "other", "phase": "failed", "pre_scaling": {}}, stopped=True)
        self.apply(expect=0)
        self.assertEqual(self.cloud.service["scaling"], {"scalingMode": "AUTOMATIC"})

    def test_unrecognised_record_on_running_service_is_replaced(self):
        self.set_record("not-json", stopped=False)
        self.apply(expect=0)
        self.assert_resumed()
        self.assertIn("confers nothing", "\n".join(self.logs) or self.text())

    def test_untrusted_records_on_a_stopped_service_confer_no_recovery_authority(self):
        cases = {
            "garbage": "not-json",
            "future_version": json.dumps({"v": 2, "run": "x", "phase": "stopped", "pre_scaling": ORIGINAL}),
            "no_scaling": json.dumps({"v": 1, "run": "x", "phase": "stopped", "pre_scaling": None}),
            "stopped_scaling": json.dumps({"v": 1, "run": "x", "phase": "stopped",
                                           "pre_scaling": {"scalingMode": "MANUAL", "manualInstanceCount": 0}}),
            "unknown_phase": json.dumps({"v": 1, "run": "x", "phase": "bootstrap-migrating",
                                         "pre_scaling": ORIGINAL}),
            "completed": json.dumps({"v": 1, "run": "x", "phase": "completed", "pre_scaling": ORIGINAL}),
            "bad_run": json.dumps({"v": 1, "run": "", "phase": "stopped", "pre_scaling": ORIGINAL}),
            "bad_scaling": json.dumps({"v": 1, "run": "x", "phase": "stopped", "pre_scaling": {"future": 1}}),
        }
        for name, raw in cases.items():
            with self.subTest(name=name):
                self.new_cloud()
                self.set_record(raw, stopped=True)
                self.apply(expect=1)
                self.assert_no_writes()
                self.assert_not_run()
                self.assertIn("never guesses scaling", self.text())

    def test_unfinished_job_record_with_service_present_is_not_a_blocker(self):
        self.cloud.job.setdefault("annotations", {})[fg.CHECKPOINT] = json.dumps(
            {"v": 1, "run": "other", "phase": "bootstrap-migrating", "pre_scaling": None})
        self.apply(expect=0)
        self.assert_resumed()
        self.assertEqual(record_of(self.cloud.job)["run"], self.latest_run())


# ---------------------------------------------------------------------------
# Bootstrap: failure at every boundary, legacy records, then recovery
# ---------------------------------------------------------------------------


BOOTSTRAP_FAILURES = {
    "claim_rejected": lambda t: t.cloud.faults.append(base._fail_nth_write("job", 1, fg.error(409, "ABORTED"))),
    "claim_applied_response_lost": _applied_then("job", 1, 503),
    "run_rejected": lambda t: t.cloud.faults.append(lambda m, k, p, q, b: fg.error(409, "ABORTED")
                                                    if k == "run" else None),
    "run_not_applied_5xx": _run_not_applied(503),
    "run_accepted_response_lost": _run_applied_then_lost,
    "migration_failed": _attr("outcome", "fail"),
    "migration_then_tasks_api_down": _tasks_api_down,
    "migration_then_task_validator_failure": _hook(lambda v, t, o: t[0].update(lastAttemptResult={"exitCode": 3})),
    "migration_then_task_image_conflict": lambda t: (t.cloud.resolve_images(), setattr(
        t.cloud, "task_image", "mirror.gcr.io/fleetdm/fleet@" + fg.OTHER_DIGEST)),
    "completion_write_rejected": lambda t: t.cloud.faults.append(
        base._fail_nth_write("job", 2, fg.error(409, "ABORTED"))),
    "completion_write_applied_response_lost": _applied_then("job", 2, 503),
}


class BootstrapRecovery(Applies):
    def setUp(self):
        super().setUp()
        self.new_cloud(service=False)

    def assert_bootstrapped(self):
        c = self.cloud
        cp = record_of(c.job)
        self.assertEqual((cp["run"], cp["phase"]), (self.latest_run(), "completed"))
        self.assertEqual(c.run_calls(), 1)
        self.assertEqual(cp["execution"], c.executions[-1]["name"])
        self.assertIsNone(c.service)
        self.assertIn("Terraform may now create the service", self.text())

    def check_recovers(self, name):
        BOOTSTRAP_FAILURES[name](self)
        self.apply(expect=1)
        self.assertNotIn("emove the", self.text())
        self.fix()
        self.apply(expect=0)
        self.assert_bootstrapped()


for _name in BOOTSTRAP_FAILURES:
    setattr(BootstrapRecovery, "test_recovers_after_" + _name,
            lambda self, n=_name: self.check_recovers(n))


class LiveLegacyBootstrapRecord(Applies):
    """The observed legacy state SHAPE, with the record left UNEDITED: an
    unfinished bootstrap-migrating v1 record (pre_scaling null) of an earlier
    run whose single execution succeeded; job generation 1; no service. The
    fixture reproduces the observed legacy format with synthetic identifiers
    and timestamps (fictional execution fleet-migration-abcde, fictional run
    id); it is a format/shape regression, not a copy of a live payload."""

    def setUp(self):
        super().setUp()
        self.new_cloud(service=False)

    def test_fixture_is_the_observed_job_shape(self):
        job = fg.OBSERVED["job_live_legacy"]
        self.assertEqual(set(job), {"annotations", "createTime", "creator", "etag", "executionCount", "generation",
                                    "labels", "lastModifier", "latestCreatedExecution", "launchStage", "name",
                                    "observedGeneration", "template", "terminalCondition", "uid", "updateTime"})
        self.assertEqual((job["generation"], job["observedGeneration"], job["executionCount"]), ("1", "1", 1))
        self.assertEqual(job["latestCreatedExecution"], {
            "name": "fleet-migration-abcde", "createTime": "2025-01-01T08:46:01.000000Z",
            "completionTime": "2025-01-01T08:49:06.000000Z", "completionStatus": "EXECUTION_SUCCEEDED"})
        record = json.loads(job["annotations"][fg.CHECKPOINT])
        self.assertEqual({k: record[k] for k in ("v", "run", "phase", "image", "pre_scaling")}, {
            "v": 1, "run": "00000000-0000-4000-8000-000000000001", "phase": "bootstrap-migrating",
            "image": "fleetdm/fleet:v4.93.0", "pre_scaling": None})
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", record["trigger"]))

    def check_live_legacy(self):
        c = self.cloud
        job = c.load_live_legacy_bootstrap()
        record_before = job["annotations"][fg.CHECKPOINT]
        view = c.job_view()
        self.assertEqual(gate.short_name(view["latestCreatedExecution"]["name"]), "fleet-migration-abcde")
        self.assertEqual(view["executionCount"], 1)
        self.assertEqual(c.job["annotations"][fg.CHECKPOINT], record_before, "the record is not edited")
        self.apply(expect=0)
        self.assertEqual(self.cloud.job["generation"] if not c.job_metadata_bumps_generation else "1", "1")
        cp = record_of(c.job)
        self.assertEqual((cp["run"], cp["phase"]), (self.latest_run(), "completed"))
        self.assertEqual(c.run_calls(), 1)
        self.assertEqual([e["name"].rsplit("/", 1)[-1] for e in c.executions],
                         ["fleet-migration-abcde", "fleet-migration-x002"])
        self.assertEqual(cp["executions"], sorted(e["name"] for e in c.executions))
        self.assertIn("unfinished record from run 00000000-0000-4000-8000-000000000001", self.text())
        self.assertIn("Terraform may now create the service", self.text())
        # The claim replaced the legacy record before :run.
        claim = next(b for (m, k, b) in c.bodies if k == "job")
        self.assertEqual(phase_of(claim), "bootstrap-migrating")
        self.assertEqual(record_of(claim)["run"], self.latest_run())

    def test_live_legacy_record_recovers_unedited(self):
        self.cloud.resolve_images()  # observed native task/execution image shape
        self.check_live_legacy()

    def test_live_legacy_record_with_api_variants(self):
        for run_etag in (False, True):
            for bumps in (False, True):
                with self.subTest(run_changes_job_etag=run_etag, metadata_bumps_generation=bumps):
                    self.new_cloud(service=False)
                    self.cloud.run_changes_job_etag = run_etag
                    self.cloud.job_metadata_bumps_generation = bumps
                    self.check_live_legacy()

    def test_live_legacy_with_full_pointer_name_spelling(self):
        self.cloud.pointer_full_name = True
        self.check_live_legacy()


class BootstrapStillRunning(BootstrapRecovery):
    def test_never_finishing_bootstrap_execution_is_waited_for_then_retried(self):
        c = self.cloud
        c.outcome = "never"
        self.apply(expect=1)
        stuck = c.executions[-1]
        self.fix()
        self.apply(expect=1)
        self.assert_not_run()
        self.assert_no_writes()
        self.assertIn("have not settled", self.text())
        c.set_execution_outcome(stuck, "fail")
        self.apply(expect=0)
        self.assert_bootstrapped()


class OldCompletedBootstrapRecords(BootstrapRecovery):
    def test_completed_record_with_mismatched_inventory_is_a_new_trusted_boundary(self):
        c = self.cloud
        c.add_prior_execution(settled=True)
        c.add_prior_execution(settled=True)
        c.job["annotations"] = {fg.CHECKPOINT: json.dumps({
            "v": 1, "run": "older", "phase": "completed", "pre_scaling": None,
            "execution": fg.JOB_NAME + "/executions/gone", "executions": [fg.JOB_NAME + "/executions/gone"]})}
        self.apply(expect=0)
        self.assert_bootstrapped()

    def test_current_run_extra_execution_still_fails_closed(self):
        base._add_execution_on("GET", "tasks")(self)
        self.apply(expect=1)
        self.assertIn("unexpected job executions exist after the migration", self.text())
        self.fix()
        self.apply(expect=0)
        self.assert_bootstrapped()


# ---------------------------------------------------------------------------
# Inventory reconciliation: latestCreatedExecution vs listing
# ---------------------------------------------------------------------------


class InventoryReconciliation(Applies):
    def test_materialized_old_execution_not_yet_listed_is_waited_for(self):
        c = self.cloud

        def fault(method, k, path, query, body):
            if method == "POST" and k == "run":
                c._h_run(method, None, query, body)
                # Accepted, but delayed in executions.list; the job's
                # latestCreatedExecution already advertises it.
                c.executions[-1]["_visible_at"] = c.now() + 1000
                return fg.FakeResponse(504, raw=b"")
            return None
        c.faults.append(fault)
        self.apply(expect=1)
        self.fix()
        self.apply(expect=0)
        self.assertIn("does not show yet", self.text())
        self.assert_resumed()

    def test_execution_advertised_but_never_listed_fails_without_launch(self):
        c = self.cloud

        def fault(method, k, path, query, body):
            if method == "POST" and k == "run":
                c._h_run(method, None, query, body)
                c.executions[-1]["_visible_at"] = c.now() + 10 ** 6
                return fg.FakeResponse(504, raw=b"")
            return None
        c.faults.append(fault)
        self.apply(expect=1)
        self.fix()
        self.apply(expect=1)
        self.assert_not_run()
        self.assert_no_writes()
        self.assertIn("does not show yet", self.text())
        self.assert_stopped_with_original()
        c.clock.t += 10 ** 6
        self.apply(expect=0)
        self.assert_resumed()

    def test_job_without_latest_pointer_but_with_executions_is_not_absence(self):
        c = self.cloud
        c.add_prior_execution(settled=True)
        original = c.job_view

        def view_without_pointer():
            v = original()
            v.pop("latestCreatedExecution", None)
            return v
        c.job_view = view_without_pointer
        self.apply(expect=1)
        self.assert_no_writes()
        self.assertIn("does not report its latest created execution", self.text())
        c.job_view = original
        self.apply(expect=0)

    def test_pointer_names(self):
        g = RevisionNameUnit().gate_for([])
        full = fg.JOB_NAME + "/executions/fleet-migration-abcde"
        self.assertEqual(g.execution_full_name("fleet-migration-abcde"), full)
        self.assertEqual(g.execution_full_name(full), full)
        for bad in (None, 7, "", "projects/p/locations/r/jobs/other/executions/x", "a/b", "UPPER",
                    fg.JOB_NAME + "/executions/", fg.JOB_NAME + "/executions/x/tasks/y"):
            with self.subTest(bad=bad):
                self.assertIsNone(g.execution_full_name(bad))
        with self.assertRaises(gate.GateError):
            g.execution_inventory({"latestCreatedExecution": {"name": "projects/p/locations/r/jobs/other/executions/x"}},
                                  [])
        names, pending = g.execution_inventory(
            {"executionCount": 1, "latestCreatedExecution": {"name": "fleet-migration-abcde",
                                                             "completionTime": "2025-01-01T08:49:06.000000Z"}},
            [{"name": full, "completionTime": "2025-01-01T08:49:06.000000Z"}])
        self.assertEqual((names, pending), ({full}, []))
        _, pending = g.execution_inventory(
            {"executionCount": 1, "latestCreatedExecution": {"name": "fleet-migration-abcde"}},
            [{"name": full, "completionTime": "2025-01-01T08:49:06.000000Z"}])
        self.assertTrue(pending, "a pointer without completionTime is in flight")


# ---------------------------------------------------------------------------
# Takeover fences stale controllers and stale requests
# ---------------------------------------------------------------------------


class StaleControllers(Applies):
    def nested_apply(self, run_id):
        logs = []
        code = gate.main(argv=["run"], environ=fg.env(FLEET_GATE_RUN_ID=run_id,
                                                      FLEET_GATE_JOB_GENERATION=self.cloud.job["generation"]),
                         transport=self.cloud, token_source=fg.FakeToken(), clock=self.cloud.clock, log=logs.append)
        return code, logs

    def test_delayed_old_run_request_is_rejected_after_takeover(self):
        for run_etag in (False, True):
            with self.subTest(run_changes_job_etag=run_etag):
                c = self.new_cloud()
                c.run_changes_job_etag = run_etag
                held = {}

                def hold(method, k, path, query, body):
                    if method == "POST" and k == "run" and "body" not in held:
                        held["body"] = body  # A's :run is still in flight, not applied
                        return fg.FakeResponse(504, raw=b"")
                    return None
                c.faults.append(hold)
                self.apply(expect=1)
                self.assertEqual(held["body"]["etag"], c.job["etag"], "without a new claim the old etag would match")
                self.fix()
                delivered = {}

                def deliver(method, k, path, query, body):
                    # After B's claim, A's delayed request finally arrives.
                    if (not delivered and method == "GET" and k == "executions"
                            and record_of(c.job)["run"] == self.run_ids[-1]):
                        delivered["status"] = c._h_run("POST", None, {}, held["body"]).status
                    return None
                c.faults.append(deliver)
                self.apply(expect=0)
                self.assertEqual(delivered["status"], 409, "the claim etag fences the old request")
                self.assertEqual(len(c.executions), 1, "only B's execution exists")
                self.assert_resumed()

    def test_late_old_controller_restop_cannot_clobber_the_new_owner(self):
        c = self.cloud
        state = {}

        def takeover(method, k, path, query, body):
            if (not state and method == "PATCH" and k == "service"
                    and body.get("scaling", {}).get("scalingMode") == "AUTOMATIC"):
                # A's restore is in flight; meanwhile B takes over and finishes.
                state["started"] = True
                state["b"] = self.nested_apply("0b6c7c55-1d5e-4c1c-9a4e-00000000000b")
                state["patches_after_b"] = len(c.service_patches())
                return fg.error(503, "UNAVAILABLE")  # A's restore outcome unknown
            return None
        c.faults.append(takeover)
        self.apply(expect=1, max_runs=2)
        b_code, b_logs = state["b"]
        self.assertEqual(b_code, 0, "\n".join(b_logs))
        # A's restore attempt was logged before B ran; after B nothing of A's
        # reached the service.
        self.assertEqual(len(c.service_patches()), state["patches_after_b"] + 0)
        self.assertIn("not re-stopping: the service record is no longer this run's", self.text())
        self.assertEqual(c.service["scaling"], ORIGINAL)
        cp = c.checkpoint()
        self.assertEqual((cp["run"], cp["phase"]), ("0b6c7c55-1d5e-4c1c-9a4e-00000000000b", "completed"))
        self.assertEqual(len([e for e in c.executions if not e.get("_prior")]), 2)

    def test_old_controller_phase_writes_stop_after_takeover(self):
        c = self.cloud
        state = {}

        def takeover(method, k, path, query, body):
            # While A waits for its migration, A's process is presumed dead and
            # B runs after A's execution settles.
            if not state and method == "GET" and k == "executions" and c.run_calls() == 1:
                state["started"] = True
                c.clock.t += 600
                state["b"] = self.nested_apply("0b6c7c55-1d5e-4c1c-9a4e-00000000000c")
                state["writes_after_b"] = len(c.writes())
            return None
        c.faults.append(takeover)
        self.apply(expect=1, max_runs=2)
        self.assertEqual(state["b"][0], 0, "\n".join(state["b"][1]))
        self.assertEqual(len(c.writes()), state["writes_after_b"], "A writes nothing after B's takeover")
        self.assertTrue(any(m in self.text() for m in (
            "no longer this run's", "service checkpoint is missing or owned by another run",
            "unexpected job executions appeared during the migration")), self.text())
        self.assertEqual(c.service["scaling"], ORIGINAL)
        self.assertEqual(c.checkpoint()["run"], "0b6c7c55-1d5e-4c1c-9a4e-00000000000c")
        self.assertIn("Fleet service: ", self.text())
        self.assertNotIn("Fleet service: " + gate.FLEET_MEASURED_ZERO, self.text())

    def test_late_old_bootstrap_completion_cannot_clobber_the_new_owner(self):
        c = self.new_cloud(service=False)
        state = {"armed": False, "reads": 0}

        def takeover(method, k, path, query, body):
            if method == "GET" and k == "tasks" and not state.get("b"):
                state["armed"] = True
            if state["armed"] and not state.get("b") and method == "GET" and k == "job":
                state["reads"] += 1
                if state["reads"] == 3:  # A's completion read
                    state["b"] = "running"
                    state["b"] = self.nested_apply("0b6c7c55-1d5e-4c1c-9a4e-00000000000d")
            return None
        c.faults.append(takeover)
        self.apply(expect=1, max_runs=2)
        self.assertEqual(state["b"][0], 0, "\n".join(state["b"][1]))
        self.assertIn("no longer this run's before the bootstrap completion write", self.text())
        cp = record_of(c.job)
        self.assertEqual((cp["run"], cp["phase"]), ("0b6c7c55-1d5e-4c1c-9a4e-00000000000d", "completed"))
        a_completions = [b for (m, k, b) in c.bodies if k == "job" and phase_of(b) == "completed"
                         and record_of(b)["run"] == self.run_ids[-1]]
        self.assertEqual(a_completions, [], "A never sends its completion after B's takeover")

    def test_claim_requires_the_job_etag_to_change(self):
        c = self.cloud
        original = c._h_job

        def keep_etag(method, match, query, data):
            etag = c.job["etag"]
            resp = original(method, match, query, data)
            if method == "PATCH":
                c.job["etag"] = etag
            return resp
        c._h_job = keep_etag
        self.apply(expect=1)
        self.assertIn("did not change with the ownership claim", self.text())
        self.assert_not_run()
        self.assertEqual(c.service_patches(), [], "Fleet is not stopped")


# ---------------------------------------------------------------------------
# Operator guidance: never a record-editing or manual-recovery recipe
# ---------------------------------------------------------------------------

GCP = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
GUIDANCE_FILES = [
    os.path.join(GCP, "byo-project", "scripts", "fleet_migration_gate.py"),
    os.path.join(GCP, "byo-project", "cloud_run.tf"),
    os.path.join(GCP, ".header.md"),
    os.path.join(GCP, "README.md"),
]
FORBIDDEN_GUIDANCE = [
    r"manual[- ]recovery",
    r"remove the (?:[`\w./-]+ )?annotation",
    r"(?:clear|delete|edit) the (?:[`\w./-]+ )?annotation",
    r"annotation after checking",
    r"restore the recorded scaling",
    r"(?:record|annotation) (?:is|has been) resolved",
    r"until (?:that|the unfinished) record",
    r"refuses until",
]


class OperatorGuidance(base.OfflineTestCase):
    def test_sources_and_docs_never_advise_record_edits_or_manual_recovery(self):
        for path in GUIDANCE_FILES:
            with open(path, encoding="utf-8") as f:
                text = f.read()
            for pattern in FORBIDDEN_GUIDANCE:
                with self.subTest(path=os.path.basename(path), pattern=pattern):
                    self.assertIsNone(re.search(pattern, text, re.IGNORECASE))

    def test_docs_describe_automatic_retry(self):
        for name in (".header.md", "README.md"):
            with open(os.path.join(GCP, name), encoding="utf-8") as f:
                text = f.read()
            self.assertIn("run `terraform apply` again", text)
            self.assertIn("not a lock", text)

    def test_every_failure_prints_retry_guidance(self):
        self.cloud.outcome = "fail"
        self.assertEqual(self.run_gate(), 1)
        text = self.text()
        self.assertIn(gate.RETRY_GUIDANCE, text)
        self.assertIn("do not edit or remove it", text)
        for pattern in FORBIDDEN_GUIDANCE:
            self.assertIsNone(re.search(pattern, text, re.IGNORECASE), pattern)


if __name__ == "__main__":
    unittest.main()
