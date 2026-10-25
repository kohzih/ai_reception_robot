"""Explicit administrator recovery; never clears the latch on its own."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time

from robot_common import APP_ROOT, MotionError, RobotSession, load_config


def recorded_goal(record):
    goal = record.get("goal_id")
    if goal is None:
        return None
    if (not isinstance(goal, str) or not re.fullmatch(r"[0-9a-f]{32}", goal) or
            goal == "0" * 32 or record.get("controller") not in ("arm", "gripper")):
        raise MotionError("invalid_recovery_record", "The recorded goal is invalid")
    return record["controller"], goal


def front_confirmed(config, positions):
    names = config["controllers"]["arm"]["joints"]
    targets = config["reference_pose"]["arm_positions_rad"]
    tolerance = config["completion"]["position_tolerance_rad"]
    return all(name in positions and abs(positions[name] - target) <= tolerance for name, target in zip(names, targets))


def load_record(path, after_restart=False):
    try:
        if not path.exists():
            return {}
        if path.stat().st_size > 16_384:
            raise MotionError("invalid_recovery_record", "Recovery record exceeds its limit")
        record = json.loads(path.read_text())
        if not isinstance(record, dict):
            raise MotionError("invalid_recovery_record", "Recovery record must be an object")
        recorded_goal(record)
        return record
    except (json.JSONDecodeError, UnicodeError, MotionError) as error:
        if after_restart:
            return {"previous_record_ignored_after_restart": True}
        raise MotionError("invalid_recovery_record", "Recovery record is invalid; restart the simulator before recovery") from error


class RecoverySession(RobotSession):
    def __init__(self, config, emit):
        self.recovery_statuses = {}
        self.status_sources = set()
        super().__init__(config, emit)
        from action_msgs.msg import GoalStatusArray
        from rclpy.qos import QoSProfile, DurabilityPolicy
        for name, controller in config["controllers"].items():
            self.node.create_subscription(
                GoalStatusArray, controller["action"] + "/_action/status",
                lambda message, source=name: self.observe_status(source, message),
                QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL))

    def observe_status(self, source, message):
        self.status_sources.add(source)
        for item in message.status_list:
            self.recovery_statuses[bytes(item.goal_info.goal_id.uuid).hex()] = item.status

    def cancel_recorded(self, record, after_restart):
        from action_msgs.srv import CancelGoal
        target = recorded_goal(record)
        # Allow discovery and transient-local status delivery before deciding.
        end = time.monotonic() + 2.0
        while time.monotonic() < end:
            self.rclpy.spin_once(self.node, timeout_sec=0.02)
        if self.status_sources != set(self.config["controllers"]) and not after_restart:
            raise MotionError("status_unavailable", "Restart the simulator if action states cannot be confirmed")
        if not target:
            return {"requested": False}
        controller, goal = target
        status = self.recovery_statuses.get(goal)
        if status is None:
            if not after_restart:
                raise MotionError("goal_state_unknown", "The previous goal cannot be confirmed; restart the simulator")
            return {"requested": False, "previous_goal_unknown_after_restart": True, "goal_id": goal, "controller": controller}
        if status in (4, 5, 6):
            return {"requested": False, "terminal_status": status, "goal_id": goal, "controller": controller}
        self.owned_goals.add(goal)
        self.foreign_goals.discard(goal)
        client = self.cancel_clients[controller]
        self._wait(client.service_is_ready, 3, "cancel_service_unavailable", cleanup=True)
        request = CancelGoal.Request()
        request.goal_info.goal_id.uuid = list(bytes.fromhex(goal))
        future = client.call_async(request)
        self.emit("cancel_requested", goal_id=goal)
        self._wait(future.done, 2, "cancel_response_timeout", cleanup=True)
        response = future.result()
        if response.return_code == CancelGoal.Response.ERROR_NONE:
            if not any(bytes(item.goal_id.uuid).hex() == goal for item in response.goals_canceling):
                raise MotionError("cancel_unconfirmed", "The requested goal was not acknowledged")
        elif response.return_code != CancelGoal.Response.ERROR_GOAL_TERMINATED:
            raise MotionError("cancel_unconfirmed", "The recorded goal could not be canceled")
        self._wait(lambda: self.recovery_statuses.get(goal) in (4, 5, 6), 3, "cancel_result_timeout", cleanup=True)
        return {"requested": True, "response_code": response.return_code, "terminal_status": self.recovery_statuses[goal],
                "goal_id": goal, "controller": controller}


def verify(session, config, record, home=False, after_restart=False):
    cancellation = session.cancel_recorded(record, after_restart)
    session.prepare("arm")
    session.prepare("gripper")
    if home:
        tolerance = config["completion"]["position_tolerance_rad"]
        if not front_confirmed(config, session.latest.positions):
            session.move("arm", config["reference_pose"]["arm_positions_rad"], 2.0, "recovery_front")
        names = config["controllers"]["gripper"]["joints"]
        opened = config["gestures"]["hold"]["open_positions_rad"]
        if any(abs(session.latest.positions[name] - value) > tolerance for name, value in zip(names, opened)):
            session.move("gripper", opened, 1.5, "recovery_open")
    session._guard()
    if not front_confirmed(config, session.latest.positions):
        raise MotionError("not_front", "Use explicit --home recovery after confirming the stop")
    return {"ready": True, "front": True, "stopped": True, "cancellation": cancellation,
            "positions": session.latest.positions, "velocities": session.latest.velocities,
            "simulation_time": session.clock, "after_simulator_restart": after_restart}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", action="store_true")
    parser.add_argument("--after-simulator-restart", action="store_true")
    parser.add_argument("--lock-fd", type=int)
    parser.add_argument("--nonce", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.nonce):
        parser.error("invalid nonce")
    session = lock = None
    def emit(event, **fields):
        print(json.dumps({"event": event, **fields}, allow_nan=False), flush=True)
    try:
        path = APP_ROOT / "tmp/robot_motion.lock"
        lock = os.fdopen(os.dup(args.lock_fd), "a") if args.lock_fd is not None else path.open("a")
        if (os.fstat(lock.fileno()).st_ino, os.fstat(lock.fileno()).st_dev) != (path.stat().st_ino, path.stat().st_dev):
            raise MotionError("invalid_lock", "Unexpected motion lock descriptor")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MotionError("robot_busy", "A motion process still owns the lock") from error
        latch = APP_ROOT / "tmp/robot_recovery_required.json"
        record = load_record(latch, args.after_simulator_restart)
        session = RecoverySession(load_config(), emit)
        details = verify(session, session.config, record, args.home, args.after_simulator_restart)
        details["previous_record_ignored_after_restart"] = record.get("previous_record_ignored_after_restart", False)
        emit("recovery_verified", nonce=args.nonce, **details)
        return 0
    except (Exception, KeyboardInterrupt) as error:
        if session:
            session.cancel_and_confirm_stop()
        emit("failed", code=getattr(error, "code", "recovery_failed"))
        print(str(error), file=sys.stderr, flush=True)
        return 1
    finally:
        if session:
            session.close()
        if lock:
            lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
