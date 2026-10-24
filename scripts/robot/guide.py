"""Turn toward a destination, bow, and return upright before facing front."""

from robot_common import MotionError, number, validate_positions


def guide(session, config, destination):
    if destination not in ("reception", "hall"):
        raise MotionError("invalid_target", "Unknown guide destination")
    settings = config["gestures"][destination]
    bow = config["gestures"]["bow"]
    front = validate_positions(config, "arm", config["reference_pose"]["arm_positions_rad"])
    turned = front.copy()
    base = config["controllers"]["arm"]["joints"].index("crane_plus_joint1")
    turned[base] = number(settings["base_yaw_rad"], "base_yaw_rad")
    turned = validate_positions(config, "arm", turned)
    bent = validate_positions(config, "arm", bow["positions_rad"])
    bent[base] = turned[base]
    bent = validate_positions(config, "arm", bent)
    duration = number(settings["duration_sim_sec"], "duration_sim_sec", positive=True)
    bow_duration = number(bow["duration_sim_sec"], "bow duration_sim_sec", positive=True)
    pause = number(bow["pause_wall_sec"], "pause_wall_sec", positive=True)

    session.prepare("arm")
    session.move("arm", front, duration, "front")
    session.move("arm", turned, duration, "turn")
    session.move("arm", bent, bow_duration, "bow")
    session.dwell(pause)
    session.move("arm", turned, bow_duration, "upright")
    session.move("arm", front, duration, "return")
