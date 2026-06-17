"""Entry point: no args → launch the dashboard; subcommands → the bash engine."""

import os
import shutil
import sys
from importlib.resources import files


def engine_path() -> str:
    return str(files("tuimux").joinpath("engine.sh"))


def tuimux_bin() -> str:
    """Absolute path to this tuimux executable.

    Engine-spawned terminals re-invoke tuimux (``exec $TUIMUX_BIN __attach …``)
    in a fresh login shell. If tuimux lives in a venv/conda env that isn't on
    the default PATH, the bare name ``tuimux`` won't resolve there and opening a
    session silently fails. Resolving to an absolute path makes it work anywhere.
    """
    cand = sys.argv[0] or ""
    if (
        os.path.basename(cand) == "tuimux"
        and os.path.isabs(cand)
        and os.path.exists(cand)
    ):
        return cand
    # Console scripts sit next to the interpreter that runs them.
    guess = os.path.join(os.path.dirname(sys.executable), "tuimux")
    if os.path.exists(guess):
        return guess
    return shutil.which("tuimux") or "tuimux"


def main() -> None:
    args = sys.argv[1:]
    if not args:
        from .app import run

        run()
        return
    # Forward everything else (new/awake/init/doctor + internal __ commands) to
    # the bash engine. TUIMUX_BIN tells the engine its own absolute path, so
    # sessions it spawns into new terminal tabs re-invoke tuimux correctly.
    env = {**os.environ, "TUIMUX_BIN": tuimux_bin()}
    os.execvpe("bash", ["bash", engine_path(), *args], env)
