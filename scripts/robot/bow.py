"""Face forward, bow, and return to the upright reference pose."""

from robot_common import MotionError, number, run_gesture, validate_positions


def bow(session, config):
    try:
        settings = config["gestures"]["bow"]
        target = validate_positions(config, "arm", settings["positions_rad"])
        duration = number(settings["duration_sim_sec"], "bow duration", positive=True)
        pause = number(settings["pause_wall_sec"], "bow pause", positive=True)
    except (KeyError, TypeError) as error:
        raise MotionError("invalid_config", "Bow targets are not configured") from error
    session.prepare("arm")
    session.move("arm", config["reference_pose"]["arm_positions_rad"], duration, "front")
    session.move("arm", target, duration, "bow")
    session.dwell(pause)
    session.move("arm", config["reference_pose"]["arm_positions_rad"], duration, "return")


if __name__ == "__main__":
    raise SystemExit(run_gesture("bow", bow))
