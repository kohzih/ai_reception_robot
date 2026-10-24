"""Guide visitors to the hall sign on the left of the fixed camera."""

from guide import guide
from robot_common import run_gesture


def hall(session, config):
    guide(session, config, "hall")


if __name__ == "__main__":
    raise SystemExit(run_gesture("hall", hall))
