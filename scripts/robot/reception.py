"""Guide visitors to the reception sign on the right of the fixed camera."""

from guide import guide
from robot_common import run_gesture


def reception(session, config):
    guide(session, config, "reception")


if __name__ == "__main__":
    raise SystemExit(run_gesture("reception", reception))
