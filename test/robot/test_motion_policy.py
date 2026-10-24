"""Policy and failure-path tests that run without ROS or a simulator."""

import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/robot"))
import robot_common as common
from bow import bow


class MotionPolicyTests(unittest.TestCase):
    def setUp(self):
        self.config = common.load_config()
        self.names = self.config["controllers"]["arm"]["joints"]

    def sample(self, received, positions=None, velocities=None):
        return common.JointSample.from_arrays(
            self.names, positions or [0.0] * 4, velocities or [0.0] * 4, received)

    def test_joint_state_is_mapped_by_name_not_message_order(self):
        sample = common.JointSample.from_arrays(["j4", "j2", "j3", "j1"], [4., 2., 3., 1.], [0.] * 4, 1.)
        self.assertEqual([sample.positions[name] for name in ["j1", "j2", "j3", "j4"]], [1., 2., 3., 4.])

    def test_duplicate_missing_and_nonfinite_observations_are_rejected(self):
        for names, positions, velocities in [(["a", "a"], [0., 0.], [0., 0.]),
                                            (["a"], [0.], []), (["a"], [float("nan")], [0.])]:
            with self.subTest(names=names, positions=positions):
                with self.assertRaises(common.MotionError):
                    common.JointSample.from_arrays(names, positions, velocities, 1.)

    def test_bad_targets_are_rejected(self):
        for values in [[0.] * 3, [float("inf"), 0., 0., 0.], [True, 0., 0., 0.], [10., 0., 0., 0.]]:
            with self.subTest(values=values), self.assertRaises(common.MotionError):
                common.validate_positions(self.config, "arm", values)

    def test_success_requires_both_terminal_status_and_result_code(self):
        common.require_success(4, 0)
        for status, code in [(5, 0), (6, 0), (4, -5), (2, 0)]:
            with self.subTest(status=status, code=code), self.assertRaises(common.MotionError):
                common.require_success(status, code)

    def test_reusing_one_sample_cannot_confirm_settling(self):
        settled = common.Settler(self.config["completion"], self.names, [0.] * 4, 0.)
        sample = self.sample(1.)
        for now in [1., 1.05, 1.1, 1.25]:
            self.assertFalse(settled.update(sample, now))

    def test_settling_requires_time_and_multiple_fresh_samples(self):
        settled = common.Settler(self.config["completion"], self.names, [0.] * 4, 0.)
        for value in [1., 1.06, 1.12, 1.18]:
            self.assertFalse(settled.update(self.sample(value), value))
        self.assertTrue(settled.update(self.sample(1.24), 1.24))

    def test_stale_or_pre_goal_samples_never_confirm_settling(self):
        for sample, now, after in [(self.sample(1.), 2., 0.), (self.sample(1.), 1., 1.1)]:
            with self.subTest(now=now):
                settled = common.Settler(self.config["completion"], self.names, [0.] * 4, after)
                self.assertFalse(settled.update(sample, now))

    def test_gap_or_position_error_resets_the_stability_window(self):
        for disturbance in [self.sample(1.15, positions=[0.2, 0., 0., 0.]), self.sample(2.)]:
            settled = common.Settler(self.config["completion"], self.names, [0.] * 4, 0.)
            for value in [1., 1.05, 1.1]:
                settled.update(self.sample(value), value)
            self.assertFalse(settled.update(disturbance, disturbance.received))
            self.assertFalse(settled.update(self.sample(disturbance.received + 0.01), disturbance.received + 0.01))

    def test_moving_or_missing_joint_cannot_pass_stop_check(self):
        settled = common.Settler(self.config["completion"], self.names, None, 0.)
        self.assertFalse(settled.update(self.sample(1., velocities=[0.1, 0., 0., 0.]), 1.))
        with self.assertRaises(common.MotionError):
            settled.update(common.JointSample({"other": 0.}, {"other": 0.}, 2.), 2.)

    def test_unsupported_policy_is_rejected_without_assert_statements(self):
        for section, key, value in [("completion", "required_action_status", "CANCELED"),
                                    ("cancellation", "automatic_retry", True),
                                    ("timeouts", "motion_wall_sec", float("nan"))]:
            config = copy.deepcopy(self.config)
            config[section][key] = value
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "motion.yml"
                path.write_text(common.yaml.safe_dump(config))
                with self.assertRaises(common.MotionError):
                    common.load_config(path)

    def test_bow_validates_targets_before_connecting(self):
        config = copy.deepcopy(self.config)
        config["gestures"]["bow"]["positions_rad"] = [50.] * 4
        session = SimpleNamespace(prepare=lambda controller: self.fail("Must not connect"))
        with self.assertRaises(common.MotionError):
            bow(session, config)

    def fake_session(self):
        now = [100.0]
        session = object.__new__(common.RobotSession)
        session.config = copy.deepcopy(self.config)
        session.latest = self.sample(now[0])
        session.interrupted = False
        session.motion_deadline = 130.0
        session.observation_error = None
        session.foreign_goals = set()
        session.clock_progress = now[0]
        session.node = SimpleNamespace(count_publishers=lambda topic: 0)
        def spin(node, timeout_sec):
            now[0] += max(0.01, timeout_sec)
        session.rclpy = SimpleNamespace(spin_once=spin)
        return session, now

    def test_frozen_ros_clock_still_hits_wall_deadline(self):
        session, now = self.fake_session()
        def spin(node, timeout_sec):
            now[0] += 0.05
            session.latest = self.sample(now[0])
        session.rclpy.spin_once = spin
        with patch.object(common.time, "monotonic", side_effect=lambda: now[0]):
            with self.assertRaises(common.MotionError) as error:
                session._wait(lambda: False, 10., "goal_timeout")
        self.assertEqual(error.exception.code, "clock_stalled")
        self.assertLess(now[0], 102.)

    def test_overall_deadline_applies_even_during_discovery(self):
        session, now = self.fake_session()
        session.motion_deadline = 100.2
        with patch.object(common.time, "monotonic", side_effect=lambda: now[0]):
            with self.assertRaises(common.MotionError) as error:
                session._wait(lambda: False, 5., "server_unavailable", observations=False)
        self.assertEqual(error.exception.code, "motion_timeout")
        self.assertLess(now[0], 100.3)

    def cancellation(self, wrong_uuid=False, terminal=5, acknowledge=True, fresh=True):
        session, now = self.fake_session()
        goal_id = SimpleNamespace(uuid=list(range(16)))
        state = {"canceled": False}
        events, requests = [], []
        session.emit = lambda event, **fields: events.append(event)
        result = SimpleNamespace(done=lambda: state["canceled"], result=lambda: SimpleNamespace(status=terminal))
        session.pending = {"controller": "arm", "uuid": bytes(goal_id.uuid).hex(), "goal_id": goal_id,
                           "handle": object(), "accept": None, "result": result, "terminal": None}
        class CancelGoal:
            class Request:
                def __init__(self):
                    self.goal_info = SimpleNamespace(goal_id=None)
            class Response:
                ERROR_NONE = 0
        def cancel(request):
            requests.append(request)
            state["canceled"] = acknowledge
            returned = SimpleNamespace(uuid=[99] * 16) if wrong_uuid else goal_id
            return SimpleNamespace(done=lambda: acknowledge,
                                   result=lambda: SimpleNamespace(return_code=0, goals_canceling=[SimpleNamespace(goal_id=returned)]))
        session.cancel_clients = {"arm": SimpleNamespace(call_async=cancel)}
        def spin(node, timeout_sec):
            now[0] += 0.05
            if fresh:
                session.latest = self.sample(now[0])
        session.rclpy.spin_once = spin
        with patch.dict(sys.modules, {"action_msgs.srv": SimpleNamespace(CancelGoal=CancelGoal)}), \
                patch.object(common.time, "monotonic", side_effect=lambda: now[0]), contextlib.redirect_stderr(io.StringIO()):
            confirmed = session.cancel_and_confirm_stop()
        return confirmed, requests, events, now[0] - 100.

    def test_cancellation_targets_own_uuid_and_waits_for_stop(self):
        confirmed, requests, events, elapsed = self.cancellation()
        self.assertTrue(confirmed)
        self.assertEqual(requests[0].goal_info.goal_id.uuid, list(range(16)))
        self.assertIn("stop_confirmed", events)
        self.assertGreaterEqual(elapsed, 0.2)

    def test_unconfirmed_cancellation_never_reports_stopped(self):
        for options in [{"wrong_uuid": True}, {"terminal": 6}, {"acknowledge": False}, {"fresh": False}]:
            with self.subTest(options=options):
                confirmed, requests, events, elapsed = self.cancellation(**options)
                self.assertFalse(confirmed)
                self.assertNotIn("stop_confirmed", events)
                self.assertLess(elapsed, 6.1)

    def test_recovery_latch_prevents_new_ros_connection(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "tmp").mkdir()
            (root / "tmp/robot_recovery_required.json").write_text("{}")
            output = io.StringIO()
            with patch.object(common, "APP_ROOT", root), patch.object(common, "RobotSession") as constructor, \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                code = common.run_gesture("bow", lambda *args: self.fail("Must not execute"))
            constructor.assert_not_called()
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(code, 1)
            self.assertEqual(events[-1]["event"], "failed")
            self.assertEqual(events[-1]["code"], "recovery_required")
            self.assertTrue(events[-1]["requires_recovery"])


if __name__ == "__main__":
    unittest.main()
