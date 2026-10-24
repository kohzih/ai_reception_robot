"""Bounded ROS trajectory execution and a JSON-lines process interface."""

from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import sys
import time
import uuid

import yaml


APP_ROOT = Path(__file__).resolve().parents[2]


class MotionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def number(value, name, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MotionError("invalid_config", f"{name} must be a number")
    if not math.isfinite(value) or (positive and value <= 0):
        raise MotionError("invalid_config", f"Invalid {name}")
    return float(value)


def validate_positions(config, controller, positions):
    joints = config["controllers"][controller]["joints"]
    if len(positions) != len(joints):
        raise MotionError("invalid_target", "Target must include every controller joint")
    result = []
    for name, value in zip(joints, positions):
        value = number(value, name)
        limit = config["joint_limits"][name]
        if not limit["lower"] <= value <= limit["upper"]:
            raise MotionError("invalid_target", f"Target outside limits: {name}")
        result.append(value)
    return result


def load_config(path=APP_ROOT / "config/robot_motion.yml"):
    def require(condition):
        if not condition:
            raise MotionError("invalid_config", "Unsupported motion policy")
    try:
        config = yaml.safe_load(Path(path).read_text())
        require(config["schema_version"] == 1)
        require(config["simulation_only"] is True)
        control = config["control"]
        require(control["interface"] == "follow_joint_trajectory")
        require(control["use_sim_time"] is True)
        require(control["joint_state_lookup"] == "name")
        require(control["allow_partial_joints_goal"] is False)
        completion = config["completion"]
        require(completion["required_action_status"] == "SUCCEEDED")
        require(completion["required_result_error_code"] == 0)
        require(completion["require_sample_after_goal"] is True)
        require(completion["require_progressing_clock"] is True)
        require(type(completion["minimum_settle_samples"]) is int)
        require(completion["minimum_settle_samples"] >= 2)
        for key in ("position_tolerance_rad", "stopped_velocity_rad_s", "settle_wall_sec", "joint_state_max_age_wall_sec"):
            number(completion[key], key, positive=True)
        for key, value in config["timeouts"].items():
            number(value, key, positive=True)
        for key, value in config["goal_constraints"].items():
            number(value, key, positive=True)
        cancel = config["cancellation"]
        require(cancel["scope"] == "current_goal_uuid")
        require(cancel["required_terminal_status"] == "CANCELED")
        require(cancel["require_stopped_joint_states"] is True)
        require(cancel["recovery_required_if_unconfirmed"] is True)
        require(cancel["automatic_return_home"] is False)
        require(cancel["automatic_retry"] is False)
        for controller in config["controllers"].values():
            names = controller["joints"]
            require(names and len(names) == len(set(names)))
            for name in names:
                limits = config["joint_limits"][name]
                require(number(limits["lower"], name) < number(limits["upper"], name))
                number(limits["max_velocity"], name, positive=True)
        validate_positions(config, "arm", config["reference_pose"]["arm_positions_rad"])
        return config
    except MotionError:
        raise
    except (AssertionError, KeyError, TypeError, ValueError, OSError, yaml.YAMLError) as error:
        raise MotionError("invalid_config", f"Invalid motion configuration: {error}") from error


@dataclass
class JointSample:
    positions: dict
    velocities: dict
    received: float

    @classmethod
    def from_arrays(cls, names, positions, velocities, received):
        if (not names or len(names) != len(set(names)) or
                len(names) != len(positions) or len(names) != len(velocities)):
            raise MotionError("invalid_joint_state", "Missing or duplicate joint data")
        if not all(math.isfinite(value) for value in [*positions, *velocities]):
            raise MotionError("invalid_joint_state", "Non-finite joint state")
        return cls(dict(zip(names, positions)), dict(zip(names, velocities)), received)


class Settler:
    def __init__(self, policy, names, target, after):
        self.policy, self.names, self.target, self.after = policy, names, target, after
        self.first = None
        self.last = None
        self.count = 0

    def update(self, sample, now):
        if sample is None or now - sample.received > self.policy["joint_state_max_age_wall_sec"]:
            self.first, self.count = None, 0
            return False
        if sample.received <= self.after or sample.received == self.last:
            return False
        if self.last is not None and sample.received - self.last > self.policy["joint_state_max_age_wall_sec"]:
            self.first, self.count = None, 0
        self.last = sample.received
        try:
            valid = all(
                abs(sample.velocities[name]) <= self.policy["stopped_velocity_rad_s"] and
                (self.target is None or abs(sample.positions[name] - target) <= self.policy["position_tolerance_rad"])
                for name, target in zip(self.names, self.target or [0.0] * len(self.names))
            )
        except KeyError as error:
            raise MotionError("invalid_joint_state", f"Missing controlled joint: {error}") from error
        if not valid:
            self.first, self.count = None, 0
            return False
        if self.first is None:
            self.first = sample.received
        self.count += 1
        return (sample.received - self.first >= self.policy["settle_wall_sec"] and
                self.count >= self.policy["minimum_settle_samples"])


def require_success(status, error_code, error_string=""):
    if status != 4 or error_code != 0:
        raise MotionError("action_failed", f"Action status={status}, error_code={error_code}: {error_string}")


class RobotSession:
    def __init__(self, config, emit):
        # Lazy imports keep policy tests runnable without a ROS installation.
        import rclpy
        from rclpy.action import ActionClient
        from rclpy.parameter import Parameter
        from rclpy.qos import QoSProfile, DurabilityPolicy, qos_profile_sensor_data
        from rclpy.signals import SignalHandlerOptions
        from control_msgs.action import FollowJointTrajectory
        from controller_manager_msgs.srv import ListControllers
        from action_msgs.msg import GoalStatusArray
        from action_msgs.srv import CancelGoal
        from sensor_msgs.msg import JointState
        from rosgraph_msgs.msg import Clock

        self.rclpy, self.config, self.emit = rclpy, config, emit
        self.started = time.monotonic()
        self.motion_deadline = self.started + config["timeouts"]["motion_wall_sec"]
        self.interrupted = False
        self.latest = None
        self.observation_error = None
        self.clock = None
        self.clock_progress = None
        self.foreign_goals = set()
        self.pending = None
        self.owned_goals = set()
        self.sent_any = False
        self._signals = {}
        rclpy.init(args=[], signal_handler_options=SignalHandlerOptions.NO)
        self.node = rclpy.create_node(
            f"reception_motion_{os.getpid()}",
            parameter_overrides=[Parameter("use_sim_time", value=True)],
        )
        for signum in (signal.SIGINT, signal.SIGTERM):
            self._signals[signum] = signal.signal(signum, self._interrupt)
        self.node.create_subscription(JointState, config["control"]["joint_states_topic"], self._joint_state, qos_profile_sensor_data)
        self.node.create_subscription(Clock, config["control"]["clock_topic"], self._clock, qos_profile_sensor_data)
        self.clients, self.cancel_clients = {}, {}
        for name, controller in config["controllers"].items():
            self.clients[name] = ActionClient(self.node, FollowJointTrajectory, controller["action"])
            self.cancel_clients[name] = self.node.create_client(CancelGoal, controller["action"] + "/_action/cancel_goal")
            self.node.create_subscription(
                GoalStatusArray, controller["action"] + "/_action/status", self._status,
                QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL),
            )
        self.manager = self.node.create_client(ListControllers, "/controller_manager/list_controllers")

    def _interrupt(self, signum, frame):
        self.interrupted = True

    def _joint_state(self, message):
        try:
            self.latest = JointSample.from_arrays(message.name, message.position, message.velocity, time.monotonic())
        except MotionError as error:
            self.observation_error = error

    def _clock(self, message):
        value = message.clock.sec + message.clock.nanosec / 1e9
        if self.clock is not None and value < self.clock:
            self.observation_error = MotionError("clock_reset", "Simulation clock moved backwards")
        if self.clock is not None and value > self.clock:
            self.clock_progress = time.monotonic()
        self.clock = value

    def _status(self, message):
        for item in message.status_list:
            goal_id = bytes(item.goal_info.goal_id.uuid).hex()
            if goal_id in self.owned_goals:
                continue
            if item.status in (1, 2, 3):
                self.foreign_goals.add(goal_id)
            else:
                self.foreign_goals.discard(goal_id)

    def _guard(self, observations=True):
        now = time.monotonic()
        if self.interrupted:
            raise MotionError("interrupted", "Motion interrupted")
        if now >= self.motion_deadline:
            raise MotionError("motion_timeout", "Overall motion deadline exceeded")
        if self.observation_error:
            raise self.observation_error
        if self.foreign_goals:
            raise MotionError("robot_busy", "Another action goal is active")
        self._check_publishers()
        if observations:
            if self.latest is None or now - self.latest.received > self.config["completion"]["joint_state_max_age_wall_sec"]:
                raise MotionError("stale_joint_state", "Joint state is missing or stale")
            if self.clock_progress is None or now - self.clock_progress > self.config["timeouts"]["clock_stall_wall_sec"]:
                raise MotionError("clock_stalled", "Simulation clock is not progressing")

    def _wait(self, predicate, seconds, code, observations=True, cleanup=False):
        end = time.monotonic() + seconds
        while True:
            if not cleanup:
                self._guard(observations)
            if time.monotonic() >= end:
                raise MotionError(code, f"Deadline exceeded: {code}")
            if predicate():
                return
            self.rclpy.spin_once(self.node, timeout_sec=min(0.02, max(0.0, end - time.monotonic())))

    def prepare(self, controller):
        from controller_manager_msgs.srv import ListControllers
        t = self.config["timeouts"]
        self._wait(lambda: self.clients[controller].server_is_ready() and self.manager.service_is_ready(),
                   t["server_discovery_wall_sec"], "server_unavailable", observations=False)
        future = self.manager.call_async(ListControllers.Request())
        self._wait(future.done, t["server_discovery_wall_sec"], "controller_unavailable", observations=False)
        expected = self.config["controllers"][controller]["node"].lstrip("/")
        if not any(item.name == expected and item.state == "active" for item in future.result().controller):
            raise MotionError("controller_inactive", f"Controller is not active: {expected}")
        self._wait(lambda: self.latest is not None and self.clock_progress is not None and
                   time.monotonic() - self.latest.received <= self.config["completion"]["joint_state_max_age_wall_sec"],
                   t["joint_state_wait_wall_sec"], "state_unavailable", observations=False)
        names = self.config["controllers"][controller]["joints"]
        stopped = Settler(self.config["completion"], names, None, time.monotonic())
        self._wait(lambda: stopped.update(self.latest, time.monotonic()), t["joint_state_wait_wall_sec"], "robot_not_stopped")
        self._check_publishers()

    def _check_publishers(self):
        if any(self.node.count_publishers(item["command_topic"]) for item in self.config["controllers"].values()):
            raise MotionError("robot_busy", "Another trajectory topic publisher is present")

    def move(self, controller, positions, duration, stage):
        from builtin_interfaces.msg import Duration
        from control_msgs.action import FollowJointTrajectory
        from control_msgs.msg import JointTolerance
        from trajectory_msgs.msg import JointTrajectoryPoint
        from unique_identifier_msgs.msg import UUID

        self._guard()
        self._check_publishers()
        positions = validate_positions(self.config, controller, positions)
        duration = number(duration, "duration", positive=True)
        names = self.config["controllers"][controller]["joints"]
        current = validate_positions(self.config, controller, [self.latest.positions[name] for name in names])
        for name, start, end in zip(names, current, positions):
            # Zero endpoint velocity/acceleration yields quintic interpolation.
            if 1.875 * abs(end - start) / duration > self.config["joint_limits"][name]["max_velocity"]:
                raise MotionError("velocity_limit", f"Trajectory too fast: {name}")
        goal = FollowJointTrajectory.Goal()
        goal.trajectory.joint_names = names
        for values, seconds in [(current, 0.0), (positions, duration)]:
            point = JointTrajectoryPoint(positions=values, velocities=[0.0] * len(names), accelerations=[0.0] * len(names))
            point.time_from_start = Duration(sec=int(seconds), nanosec=int((seconds % 1) * 1e9))
            goal.trajectory.points.append(point)
        constraints = self.config["goal_constraints"]
        goal.path_tolerance = [JointTolerance(name=name, position=constraints["path_position_tolerance_rad"]) for name in names]
        goal.goal_tolerance = [JointTolerance(name=name, position=constraints["goal_position_tolerance_rad"]) for name in names]
        seconds = constraints["goal_time_tolerance_sim_sec"]
        goal.goal_time_tolerance = Duration(sec=int(seconds), nanosec=int((seconds % 1) * 1e9))
        goal_id = UUID(uuid=list(uuid.uuid4().bytes))
        self.owned_goals.add(bytes(goal_id.uuid).hex())
        sent_at = time.monotonic()
        self.pending = {"uuid": bytes(goal_id.uuid).hex(), "goal_id": goal_id, "controller": controller,
                        "accept": None, "handle": None, "result": None, "terminal": None}
        self.sent_any = True
        # Persist intent before dispatch so a killed process cannot silently retry.
        (APP_ROOT / "tmp/robot_recovery_required.json").write_text(json.dumps({
            "code": "in_flight", "controller": controller,
            "goal_id": self.pending["uuid"], "stop_confirmed": False,
        }) + "\n")
        self.pending["accept"] = self.clients[controller].send_goal_async(goal, goal_uuid=goal_id)
        self._wait(self.pending["accept"].done, self.config["timeouts"]["goal_response_wall_sec"], "goal_response_timeout")
        handle = self.pending["accept"].result()
        if not handle.accepted:
            self.pending = None
            raise MotionError("goal_rejected", "Trajectory goal rejected")
        self.pending["handle"] = handle
        self.pending["result"] = handle.get_result_async()
        self.emit("command_sent", stage=stage, controller=controller, goal_id=self.pending["uuid"], positions_rad=positions)
        goal_deadline = sent_at + self.config["timeouts"]["per_goal_wall_sec"]
        self._wait(self.pending["result"].done, max(0.0, goal_deadline - time.monotonic()), "goal_timeout")
        response = self.pending["result"].result()
        self.pending["terminal"] = response.status
        require_success(response.status, response.result.error_code, response.result.error_string)
        settled = Settler(self.config["completion"], names, positions, time.monotonic())
        self._wait(lambda: settled.update(self.latest, time.monotonic()),
                   max(0.0, goal_deadline - time.monotonic()), "settle_timeout")
        self.pending = None
        self.emit("stage_completed", stage=stage, action_status=response.status, result_error_code=response.result.error_code,
                  positions_rad=[self.latest.positions[name] for name in names])

    def dwell(self, seconds):
        end = time.monotonic() + number(seconds, "dwell", positive=True)
        while time.monotonic() < end:
            self._guard()
            self.rclpy.spin_once(self.node, timeout_sec=0.02)

    def cancel_and_confirm_stop(self):
        if self.pending is None:
            return False
        from action_msgs.srv import CancelGoal
        pending = self.pending
        try:
            if pending["result"] is not None and pending["result"].done():
                pending["terminal"] = pending["result"].result().status
            if pending["terminal"] not in (4, 5, 6):
                request = CancelGoal.Request()
                request.goal_info.goal_id = pending["goal_id"]
                future = self.cancel_clients[pending["controller"]].call_async(request)
                self.emit("cancel_requested", goal_id=pending["uuid"])
                self._wait(future.done, self.config["timeouts"]["cancel_response_wall_sec"], "cancel_response_timeout", cleanup=True)
                response = future.result()
                if response.return_code != CancelGoal.Response.ERROR_NONE or not any(
                        bytes(item.goal_id.uuid).hex() == pending["uuid"] for item in response.goals_canceling):
                    raise MotionError("cancel_unconfirmed", "Cancellation was not acknowledged for this goal")
                def terminal():
                    if pending["handle"] is None and pending["accept"] is not None and pending["accept"].done():
                        handle = pending["accept"].result()
                        if handle.accepted:
                            pending["handle"], pending["result"] = handle, handle.get_result_async()
                    return pending["result"] is not None and pending["result"].done()
                self._wait(terminal, self.config["timeouts"]["cancel_result_wall_sec"], "cancel_result_timeout", cleanup=True)
                pending["terminal"] = pending["result"].result().status
                if pending["terminal"] != 5:
                    raise MotionError("cancel_unconfirmed", "Action did not finish as CANCELED")
            names = self.config["controllers"][pending["controller"]]["joints"]
            stopped = Settler(self.config["completion"], names, None, time.monotonic())
            self._wait(lambda: stopped.update(self.latest, time.monotonic()),
                       self.config["timeouts"]["stop_observation_wall_sec"], "stop_unconfirmed", cleanup=True)
            self.emit("stop_confirmed", goal_id=pending["uuid"], action_status=pending["terminal"])
            return True
        except Exception as error:
            print(f"Cancellation/stop could not be confirmed: {error}", file=sys.stderr, flush=True)
            return False

    def close(self):
        for signum, handler in self._signals.items():
            signal.signal(signum, handler)
        self.node.destroy_node()
        if self.rclpy.ok():
            self.rclpy.shutdown()


def run_gesture(name, execute):
    started = time.monotonic()
    def emit(event, **fields):
        print(json.dumps({"event": event, "motion": name, "elapsed_sec": round(time.monotonic() - started, 3), **fields},
                         ensure_ascii=False, allow_nan=False), flush=True)
    session = None
    lock = None
    try:
        config = load_config()
        lock_path = APP_ROOT / "tmp/robot_motion.lock"
        lock_path.parent.mkdir(exist_ok=True)
        lock = lock_path.open("a")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MotionError("robot_busy", "Another motion process holds the robot lock") from error
        if (APP_ROOT / "tmp/robot_recovery_required.json").exists():
            raise MotionError("recovery_required", "Previous motion requires explicit recovery before another run")
        os.environ.setdefault("RCUTILS_LOGGING_USE_STDOUT", "0")
        emit("started")
        session = RobotSession(config, emit)
        execute(session, config)
        session._guard()
        (APP_ROOT / "tmp/robot_recovery_required.json").unlink(missing_ok=True)
        emit("completed")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        stop_confirmed = session.cancel_and_confirm_stop() if session else False
        dispatched = bool(session and session.sent_any)
        recovery = dispatched or getattr(error, "code", "") == "recovery_required"
        if dispatched:
            record = {"motion": name, "code": getattr(error, "code", "internal_error"),
                      "stop_confirmed": stop_confirmed, "goal_id": session.pending["uuid"] if session.pending else None}
            try:
                (APP_ROOT / "tmp/robot_recovery_required.json").write_text(json.dumps(record) + "\n")
            except OSError as record_error:
                print(f"Could not persist recovery state: {record_error}", file=sys.stderr, flush=True)
        print(str(error), file=sys.stderr, flush=True)
        emit("failed", code=getattr(error, "code", "internal_error"), message=str(error),
             requires_recovery=recovery, stop_confirmed=stop_confirmed)
        return 1
    finally:
        if session:
            session.close()
        if lock:
            lock.close()
