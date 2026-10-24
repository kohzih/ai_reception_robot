"""Face forward and signal uncertainty with two complete gripper cycles."""

from robot_common import MotionError, number, run_gesture, validate_positions


def hold(session, config):
    try:
        settings = config["gestures"]["hold"]
        front = validate_positions(config, "arm", config["reference_pose"]["arm_positions_rad"])
        opened = validate_positions(config, "gripper", settings["open_positions_rad"])
        closed = validate_positions(config, "gripper", settings["closed_positions_rad"])
        if config["controllers"]["gripper"]["joints"] != ["crane_plus_joint_hand"]:
            raise MotionError("invalid_config", "Unsupported gripper joint configuration")
        if closed[0] - opened[0] <= 2 * config["completion"]["position_tolerance_rad"]:
            raise MotionError("invalid_config", "Open and closed targets must be distinct and correctly ordered")
        arm_duration = number(settings["arm_duration_sim_sec"], "hold arm duration", positive=True)
        gripper_duration = number(settings["gripper_duration_sim_sec"], "hold gripper duration", positive=True)
        pause = number(settings["pause_wall_sec"], "hold pause", positive=True)
    except (KeyError, TypeError) as error:
        raise MotionError("invalid_config", "Hold targets are not configured") from error

    # Both controllers must be available and stopped before the first command.
    session.prepare("arm")
    session.prepare("gripper")
    session.move("arm", front, arm_duration, "front")
    # Establish an open start so both cycles remain visible after any prior pose.
    session.move("gripper", opened, gripper_duration, "open_ready")
    session.dwell(pause)
    for cycle in (1, 2):
        session.move("gripper", closed, gripper_duration, f"close_{cycle}")
        session.dwell(pause)
        session.move("gripper", opened, gripper_duration, f"open_{cycle}")
        session.dwell(pause)


if __name__ == "__main__":
    raise SystemExit(run_gesture("hold", hold))
