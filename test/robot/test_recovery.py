"""Recovery policy tests without a ROS installation or robot commands."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/robot"))
import recovery


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.config = recovery.load_config()
        names = self.config["controllers"]["arm"]["joints"] + ["crane_plus_joint_hand"]
        self.positions = dict(zip(names, [0., 0., 0., 0., -0.6]))

    def session(self):
        calls = []
        positions = self.positions.copy()
        def move(controller, values, duration, stage):
            calls.append(("move", stage))
            positions.update(zip(self.config["controllers"][controller]["joints"], values))
        result = SimpleNamespace(
            cancel_recorded=lambda record, restarted: {"requested": False},
            prepare=lambda controller: calls.append(("stopped", controller)),
            move=move, _guard=lambda: None, clock=10,
            latest=SimpleNamespace(positions=positions, velocities={name: 0. for name in positions}))
        return result, calls

    def test_only_a_scoped_nonzero_goal_and_known_controller_can_be_canceled(self):
        valid = {"controller": "arm", "goal_id": "a" * 32}
        self.assertEqual(("arm", "a" * 32), recovery.recorded_goal(valid))
        for record in [{"goal_id": "0" * 32, "controller": "arm"}, {"goal_id": "../goal", "controller": "arm"},
                       {"goal_id": "a" * 32}, {"goal_id": "a" * 32, "controller": "other"}]:
            with self.subTest(record=record), self.assertRaises(recovery.MotionError):
                recovery.recorded_goal(record)
        self.assertIsNone(recovery.recorded_goal({}))

    def test_normal_recovery_verifies_stopped_controllers_without_moving(self):
        session, calls = self.session()
        result = recovery.verify(session, self.config, {})
        self.assertTrue(result["ready"])
        self.assertEqual([("stopped", "arm"), ("stopped", "gripper")], calls)

    def test_nonfront_pose_requires_explicit_home_and_stop_is_checked_first(self):
        session, calls = self.session()
        session.latest.positions["crane_plus_joint2"] = 0.3
        with self.assertRaises(recovery.MotionError):
            recovery.verify(session, self.config, {})
        self.assertFalse(any(item[0] == "move" for item in calls))
        result = recovery.verify(session, self.config, {}, home=True)
        self.assertTrue(result["front"])
        self.assertEqual(("move", "recovery_front"), calls[-1])

    def test_failed_observations_never_return_ready_or_start_home(self):
        session, calls = self.session()
        def unavailable(controller):
            raise recovery.MotionError("stale_joint_state", "No fresh state")
        session.prepare = unavailable
        with self.assertRaises(recovery.MotionError):
            recovery.verify(session, self.config, {}, home=True, after_restart=True)
        self.assertEqual([], calls)

    def test_home_also_establishes_an_open_gripper(self):
        session, calls = self.session()
        session.latest.positions["crane_plus_joint_hand"] = 0.6
        result = recovery.verify(session, self.config, {}, home=True)
        self.assertTrue(result["stopped"])
        self.assertEqual(("move", "recovery_open"), calls[-1])

    def test_damaged_legacy_records_require_an_explicit_simulator_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "latch.json"
            for text in ['{broken', '[]', '{"goal_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}']:
                path.write_text(text)
                with self.assertRaises(recovery.MotionError):
                    recovery.load_record(path)
                self.assertEqual({"previous_record_ignored_after_restart": True}, recovery.load_record(path, True))

    def cancellation_session(self, known=True, correct_ack=True):
        goal, requests = "a" * 32, []
        session = object.__new__(recovery.RecoverySession)
        session.config = self.config
        session.node = object()
        session.rclpy = SimpleNamespace(spin_once=lambda *args, **kwargs: None)
        session.status_sources = {"arm", "gripper"}
        session.recovery_statuses = {goal: 2} if known else {}
        session.owned_goals, session.foreign_goals = set(), {goal}
        session.emit = lambda *args, **kwargs: None
        class CancelGoal:
            class Request:
                def __init__(self):
                    self.goal_info = SimpleNamespace(goal_id=SimpleNamespace(uuid=[]))
            class Response:
                ERROR_NONE = 0
                ERROR_GOAL_TERMINATED = 3
        def cancel(request):
            requests.append(request)
            def result():
                session.recovery_statuses[goal] = 5
                returned = bytes.fromhex(goal if correct_ack else "b" * 32)
                return SimpleNamespace(return_code=0, goals_canceling=[SimpleNamespace(goal_id=SimpleNamespace(uuid=list(returned)))])
            return SimpleNamespace(done=lambda: True, result=result)
        session.cancel_clients = {"arm": SimpleNamespace(service_is_ready=lambda: True, call_async=cancel)}
        def wait(predicate, *args, **kwargs):
            if not predicate():
                raise recovery.MotionError("unconfirmed", "Wait did not complete")
        session._wait = wait
        return session, requests, CancelGoal

    def cancel_recorded(self, known=True, correct_ack=True, after_restart=False):
        session, requests, cancel_type = self.cancellation_session(known, correct_ack)
        ticks = iter([i * 0.5 for i in range(20)])
        with patch.dict(sys.modules, {"action_msgs.srv": SimpleNamespace(CancelGoal=cancel_type)}), \
                patch.object(recovery.time, "monotonic", side_effect=lambda: next(ticks)):
            result = session.cancel_recorded({"controller": "arm", "goal_id": "a" * 32}, after_restart)
        return result, requests

    def test_cancel_uses_only_the_recorded_goal_and_confirms_a_terminal_status(self):
        result, requests = self.cancel_recorded()
        self.assertEqual(list(bytes.fromhex("a" * 32)), requests[0].goal_info.goal_id.uuid)
        self.assertTrue(result["requested"])
        self.assertEqual(5, result["terminal_status"])
        self.assertEqual("a" * 32, result["goal_id"])

    def test_wrong_cancel_acknowledgement_never_confirms_recovery(self):
        with self.assertRaises(recovery.MotionError):
            self.cancel_recorded(correct_ack=False)

    def test_unknown_goals_require_the_simulator_restart_flag(self):
        with self.assertRaises(recovery.MotionError):
            self.cancel_recorded(known=False)
        result, requests = self.cancel_recorded(known=False, after_restart=True)
        self.assertTrue(result["previous_goal_unknown_after_restart"])
        self.assertEqual([], requests)

    def test_restart_flag_does_not_skip_cancellation_of_a_known_active_goal(self):
        result, requests = self.cancel_recorded(after_restart=True)
        self.assertTrue(result["requested"])
        self.assertEqual(1, len(requests))


if __name__ == "__main__":
    unittest.main()
