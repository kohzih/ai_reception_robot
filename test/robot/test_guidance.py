"""Destination direction and failure propagation without a ROS installation."""

import copy
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/robot"))
from hall import hall
from reception import reception
from robot_common import MotionError, load_config


class RecordingSession:
    def __init__(self, fail_at=None):
        self.moves = []
        self.fail_at = fail_at
        self.prepared = False

    def prepare(self, controller):
        self.prepared = True

    def move(self, controller, positions, duration, stage):
        self.moves.append((stage, positions.copy()))
        if stage == self.fail_at:
            raise MotionError("action_failed", "Injected failed stage")

    def dwell(self, seconds):
        pass


class GuidanceTests(unittest.TestCase):
    def setUp(self):
        self.config = load_config()

    def test_bows_toward_opposite_signs_and_finishes_at_reference(self):
        for gesture, direction in [(reception, 1), (hall, -1)]:
            with self.subTest(gesture=gesture.__name__):
                session = RecordingSession()
                gesture(session, self.config)
                stages = dict(session.moves)
                yaw, pitch, _, _ = stages["bow"]
                # For the fixed +X camera, bow displacement toward +Y is right.
                self.assertGreater(direction * math.sin(yaw) * math.sin(pitch), 0.3)
                self.assertAlmostEqual(math.cos(yaw), 0.0, places=5)
                self.assertEqual(stages["turn"], stages["upright"])
                self.assertEqual(stages["return"], self.config["reference_pose"]["arm_positions_rad"])

    def test_returns_upright_before_turning_back_to_front(self):
        for gesture in (reception, hall):
            with self.subTest(gesture=gesture.__name__):
                session = RecordingSession()
                gesture(session, self.config)
                self.assertEqual([stage for stage, _ in session.moves],
                                 ["front", "turn", "bow", "upright", "return"])
                self.assertEqual(session.moves[-2][1][1:], session.moves[0][1][1:])
                self.assertNotEqual(session.moves[-2][1][0], session.moves[-1][1][0])

    def test_failed_stage_never_attempts_next_stage_or_automatic_return(self):
        for gesture in (reception, hall):
            for stage in ("front", "turn", "bow", "upright"):
                with self.subTest(gesture=gesture.__name__, stage=stage):
                    session = RecordingSession(fail_at=stage)
                    with self.assertRaises(MotionError):
                        gesture(session, self.config)
                    self.assertEqual(session.moves[-1][0], stage)
                    self.assertNotIn("return", [name for name, _ in session.moves])

    def test_invalid_motion_configuration_is_rejected_before_prepare(self):
        for gesture in (reception, hall):
            for section, key, value in [(gesture.__name__, "base_yaw_rad", 10.0),
                                        (gesture.__name__, "duration_sim_sec", 0.0),
                                        ("bow", "positions_rad", [0.0, float("nan"), 0.0, 0.0]),
                                        ("bow", "pause_wall_sec", -1.0)]:
                with self.subTest(gesture=gesture.__name__, key=key):
                    config = copy.deepcopy(self.config)
                    config["gestures"][section][key] = value
                    session = RecordingSession()
                    with self.assertRaises(MotionError):
                        gesture(session, config)
                    self.assertFalse(session.prepared)
                    self.assertFalse(session.moves)


if __name__ == "__main__":
    unittest.main()
