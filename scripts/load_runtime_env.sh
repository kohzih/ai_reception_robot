# Source this file from Bash in the lecture container.
# It configures Ruby and ROS for the simulator and application processes.
# Example: source scripts/load_runtime_env.sh

PAI_RUNTIME_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1

for PAI_RUNTIME_SETUP in \
    "$PAI_RUNTIME_SCRIPT_DIR/load_ruby_env.sh" \
    /opt/ros/humble/setup.bash \
    /home/ubuntu/airobot_ws/install/setup.bash
do
    if [ ! -r "$PAI_RUNTIME_SETUP" ]; then
        printf 'Required environment setup not found: %s\n' "$PAI_RUNTIME_SETUP" >&2
        unset PAI_RUNTIME_SCRIPT_DIR PAI_RUNTIME_SETUP
        return 1
    fi
done

source "$PAI_RUNTIME_SCRIPT_DIR/load_ruby_env.sh" || {
    unset PAI_RUNTIME_SCRIPT_DIR PAI_RUNTIME_SETUP
    return 1
}
source /opt/ros/humble/setup.bash || {
    unset PAI_RUNTIME_SCRIPT_DIR PAI_RUNTIME_SETUP
    return 1
}
source /home/ubuntu/airobot_ws/install/setup.bash || {
    unset PAI_RUNTIME_SCRIPT_DIR PAI_RUNTIME_SETUP
    return 1
}

export ROBOT_PYTHON=/usr/bin/python3
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-0}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

unset PAI_RUNTIME_SCRIPT_DIR PAI_RUNTIME_SETUP
