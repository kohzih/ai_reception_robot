"""Two complete gripper cycles, controller readiness, and failure boundaries."""

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/robot"))
from hold import hold
from robot_common import MotionError, load_config


class RecordingSession:
    def __init__(self, config, initial, fail_at=None, unavailable=None):
        self.config = config
        self.gripper = initial
        self.arm = [1.0, 0.0, 0.0, 0.0]
        self.fail_at, self.unavailable = fail_at, unavailable
        self.prepared, self.moves, self.transitions = [], [], []

    def prepare(self, controller):
        self.prepared.append(controller)
        if controller == self.unavailable:
            raise MotionError("server_unavailable", "Injected unavailable controller")

    def move(self, controller, positions, duration, stage):
        self.moves.append((controller, positions.copy(), stage))
        if stage == self.fail_at:
            raise MotionError("action_failed", "Injected failed stage")
        if set(self.prepared) != {"arm", "gripper"}:
            raise AssertionError("Both controllers must be ready before any motion")
        if controller == "arm":
            self.arm = positions.copy()
        else:
            if self.arm != self.config["reference_pose"]["arm_positions_rad"]:
                raise AssertionError("Gripper moved before facing front")
            self.transitions.append((self.gripper, positions[0], stage))
            self.gripper = positions[0]

    def dwell(self, seconds):
        pass


class HoldTests(unittest.TestCase):
    def setUp(self):
        self.config = load_config()

    def test_two_complete_cycles_from_open_closed_or_intermediate_start(self):
        settings = self.config["gestures"]["hold"]
        opened, closed = settings["open_positions_rad"][0], settings["closed_positions_rad"][0]
        for initial in (opened, closed, 0.0):
            with self.subTest(initial=initial):
                session = RecordingSession(self.config, initial)
                hold(session, self.config)
                cycles = [(before, after) for before, after, stage in session.transitions if stage != "open_ready"]
                self.assertEqual(cycles, [(opened, closed), (closed, opened)] * 2)
                self.assertEqual(session.gripper, opened)
                self.assertEqual(session.arm, self.config["reference_pose"]["arm_positions_rad"])
                self.assertEqual(sum(controller == "arm" for controller, _, _ in session.moves), 1)

    def test_either_unavailable_controller_prevents_all_motion(self):
        for controller in ("arm", "gripper"):
            with self.subTest(controller=controller):
                session = RecordingSession(self.config, 0.0, unavailable=controller)
                with self.assertRaises(MotionError):
                    hold(session, self.config)
                self.assertFalse(session.moves)

    def test_failed_stage_stops_without_retry_or_automatic_open(self):
        for stage in ("front", "open_ready", "close_1", "open_1", "close_2", "open_2"):
            with self.subTest(stage=stage):
                session = RecordingSession(self.config, 0.0, fail_at=stage)
                with self.assertRaises(MotionError):
                    hold(session, self.config)
                self.assertEqual(session.moves[-1][2], stage)
                self.assertEqual(sum(item[2] == stage for item in session.moves), 1)

    def test_invalid_or_indistinguishable_targets_fail_before_connecting(self):
        cases = [("open_positions_rad", [-10.0]), ("closed_positions_rad", [float("nan")]),
                 ("open_positions_rad", []), ("open_positions_rad", [True]),
                 ("open_positions_rad", [0.6]), ("open_positions_rad", [0.59]),
                 ("closed_positions_rad", [-0.65]), ("arm_duration_sim_sec", 0.0),
                 ("gripper_duration_sim_sec", float("inf")), ("pause_wall_sec", -0.1)]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                config = copy.deepcopy(self.config)
                config["gestures"]["hold"][key] = value
                session = RecordingSession(config, 0.0)
                with self.assertRaises(MotionError):
                    hold(session, config)
                self.assertFalse(session.prepared)
                self.assertFalse(session.moves)
        config = copy.deepcopy(self.config)
        del config["gestures"]["hold"]
        session = RecordingSession(config, 0.0)
        with self.assertRaises(MotionError):
            hold(session, config)
        self.assertFalse(session.prepared)


if __name__ == "__main__":
    unittest.main()
