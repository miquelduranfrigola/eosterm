"""Entry point: no args → launch the dashboard; subcommands → the bash engine."""

import os
import sys
from importlib.resources import files


def engine_path() -> str:
    return str(files("eosterm").joinpath("engine.sh"))


def main() -> None:
    args = sys.argv[1:]
    if not args:
        from .app import run

        run()
        return
    # Forward everything else (new/awake/init/doctor + internal __ commands) to
    # the bash engine. EOSTERM_BIN tells the engine its public name, so sessions
    # it spawns into new Ghostty tabs re-invoke `eosterm` correctly.
    env = {**os.environ, "EOSTERM_BIN": "eosterm"}
    os.execvpe("bash", ["bash", engine_path(), *args], env)
