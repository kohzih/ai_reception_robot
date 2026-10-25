"""Local ROS failure fixture; not used by normal application execution."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def server(scenario):
    import rclpy
    from rclpy.action import ActionServer, GoalResponse
    from rclpy.qos import qos_profile_sensor_data
    from builtin_interfaces.msg import Time
    from control_msgs.action import FollowJointTrajectory
    from controller_manager_msgs.msg import ControllerState
    from controller_manager_msgs.srv import ListControllers
    from rosgraph_msgs.msg import Clock
    from sensor_msgs.msg import JointState
    rclpy.init()
    node = rclpy.create_node("recovery_failure_fixture")
    config = __import__("yaml").safe_load((ROOT / "config/robot_motion.yml").read_text())
    names = config["controllers"]["arm"]["joints"] + config["controllers"]["gripper"]["joints"]
    joints = node.create_publisher(JointState, "/joint_states", qos_profile_sensor_data)
    clock = node.create_publisher(Clock, "/clock", 10)
    elapsed = [0.0]
    def publish():
        elapsed[0] += 0.02
        clock.publish(Clock(clock=Time(sec=int(elapsed[0]), nanosec=int((elapsed[0] % 1) * 1e9))))
        joints.publish(JointState(name=names, position=[0.] * len(names), velocity=[0.] * len(names)))
    def controllers(request, response):
        response.controller = [ControllerState(name=item["node"].lstrip("/"), state="active") for item in config["controllers"].values()]
        return response
    def execute(goal):
        goal.abort()
        return FollowJointTrajectory.Result(error_code=-5, error_string="Injected abort")
    node.create_timer(0.02, publish)
    node.create_service(ListControllers, "/controller_manager/list_controllers", controllers)
    servers = [ActionServer(node, FollowJointTrajectory, item["action"], execute_callback=execute,
        goal_callback=lambda request: GoalResponse.REJECT if scenario == "reject" else GoalResponse.ACCEPT)
        for item in config["controllers"].values()]
    print("FIXTURE_READY", flush=True)
    try:
        rclpy.spin(node)
    finally:
        for action_server in servers:
            action_server.destroy()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


def gesture(kind, directory):
    sys.path.insert(0, str(ROOT / "scripts/robot"))
    import robot_common as common
    from bow import bow
    if directory != "-":
        common.APP_ROOT = Path(directory)
        (common.APP_ROOT / "tmp").mkdir(exist_ok=True)
    def slow(session, config):
        if kind == "orphan":
            config["timeouts"]["per_goal_wall_sec"] = 25.0
        session.prepare("arm")
        session.move("arm", config["reference_pose"]["arm_positions_rad"], 2.0, "front")
        session.move("arm", config["gestures"]["bow"]["positions_rad"], 18.0 if kind == "orphan" else 8.0, "bow")
        session.dwell(0.5)
        session.move("arm", config["reference_pose"]["arm_positions_rad"], 2.0, "return")
    raise SystemExit(common.run_gesture("bow", slow if kind in ("slow", "orphan") else bow))


if __name__ == "__main__":
    if sys.argv[1] == "server":
        server(sys.argv[2])
    else:
        gesture(sys.argv[2], sys.argv[3])
