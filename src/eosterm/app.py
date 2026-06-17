#!/usr/bin/env python3
"""eosterm — a Textual dashboard for tmux sessions across your tailnet.

The heavy lifting (Tailscale discovery, tmux/ssh probing, Ghostty tab spawning,
keep-awake, claude/state detection) lives in the bundled `engine.sh`; this is
purely the front-end, calling it for data and actions.
"""

import os
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from importlib.resources import files

from rich.text import Text
from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Header, Footer, DataTable, Label, Input, OptionList
from textual.widgets.option_list import Option

ENGINE = str(files("eosterm").joinpath("engine.sh"))
# EOSTERM_BIN tells the engine its public command name, so sessions it spawns
# into new Ghostty tabs re-invoke `eosterm` (the installed console script).
_ENV = {**os.environ, "EOSTERM_BIN": "eosterm"}
REFRESH = float(os.environ.get("EOSTERM_REFRESH", "3") or 3)
AWAKE = "keep-awake"
SHELLS = {
    "zsh",
    "bash",
    "sh",
    "fish",
    "-zsh",
    "-bash",
    "dash",
    "ksh",
    "tcsh",
    "login",
    "",
}

LOCAL = "#34d8b1"  # teal   (this machine)
REMOTE = "#7aa2f7"  # blue   (other machines)
CYAN = "#56cfe1"  # folders
VIOLET = "#b08cff"  # agent
AMBER = "#e0af68"  # awake / waiting


def _run(args):
    return subprocess.run(
        ["bash", ENGINE, *args], capture_output=True, text=True, env=_ENV
    )


def fetch_hosts():
    res = []
    for ln in _run(["__hosts"]).stdout.splitlines():
        if "\t" in ln:
            name, loc = ln.split("\t", 1)
            res.append((name, loc.strip() == "1"))
    return res


def _abbrev(path):
    return re.sub(r"^/home/[^/]+", "~", re.sub(r"^/Users/[^/]+", "~", path or ""))


def _uptime(created):
    try:
        secs = int(time.time()) - int(created)
    except (TypeError, ValueError):
        return ""
    secs = max(secs, 0)
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def _map_term(t):
    tl = (t or "").lower()
    for k in ("ghostty", "kitty", "alacritty", "wezterm"):
        if k in tl:
            return k
    if tl.startswith(("screen", "tmux")):
        return "tmux"
    if tl.startswith(("xterm", "vt")) or tl == "linux":
        return "term"
    return t or "-"


def _auto_name(name, dird, is_agent, cmd):
    if not name.isdigit():  # docker/manual name → keep it
        return name or "?"
    if dird not in ("~", "", "/"):  # bare tmux number in a real folder → folder
        return os.path.basename(dird)
    if is_agent:
        return "claude"
    if cmd and cmd not in SHELLS:
        return cmd
    return name


def probe(host):
    info = {"reachable": False, "notmux": False, "awake": False, "sessions": []}
    lines = _run(["__probe", host]).stdout.splitlines()
    if not lines or lines[0].strip() != "OK":
        return info
    info["reachable"] = True
    S, W, L, A, C = {}, {}, {}, {}, set()
    for ln in lines[1:]:
        if ln == "__NOTMUX__":
            info["notmux"] = True
            continue
        if "|" not in ln:
            continue
        p = ln.split("|")
        t = p[0]
        try:
            if t == "S":
                S[p[1]] = {
                    "attached": p[2] == "1",
                    "windows": int(p[3] or 0),
                    "dir": p[4] if len(p) > 4 else "",
                    "cmd": p[5] if len(p) > 5 else "",
                    "created": p[6] if len(p) > 6 else "",
                }
            elif t == "W":
                W.setdefault(p[1], []).append((p[2], p[3], p[4] == "1"))
            elif t == "L":
                L[p[1]] = p[2]
            elif t == "A":
                A[p[1]] = p[2]
            elif t == "C":
                C.add(p[1])
        except IndexError:
            continue
    info["awake"] = AWAKE in S
    for name, s in S.items():
        if name == AWAKE:
            continue
        is_agent = name in C
        dird = _abbrev(s["dir"]) or "~"
        wins = W.get(name, [])
        count = len(wins) or s["windows"] or 1
        active = next(
            (w[1] for w in wins if w[2]), wins[0][1] if wins else (s["cmd"] or "?")
        )
        if is_agent and re.match(r"^[0-9][0-9.]*$", active or ""):
            active = "claude"
        client = L.get(name)
        state = (
            (A.get(name) or "running")
            if is_agent
            else ("idle" if s["cmd"] in SHELLS else "running")
        )
        info["sessions"].append(
            {
                "name": name,
                "auto": _auto_name(name, dird, is_agent, s["cmd"]),
                "attached": s["attached"],
                "dir": dird,
                "tabs": f"{count}  {active}",
                "open_in": _map_term(client)
                if (s["attached"] and client)
                else "detached",
                "state": state,
                "uptime": _uptime(s["created"]),
                "agent": is_agent,
            }
        )
    info["sessions"].sort(key=lambda x: x["auto"].lower())
    return info


def gather():
    hosts = fetch_hosts()
    with ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(lambda hl: (hl, probe(hl[0])), hosts))


class Confirm(ModalScreen[bool]):
    BINDINGS = [("escape", "no"), ("n", "no"), ("y", "yes")]

    def __init__(self, message):
        super().__init__()
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.message, id="dialog-msg")
            yield OptionList(
                Option("↩   cancel", id="cancel"),
                Option("✕   yes, shut it down", id="ok"),
                id="menu-list",
            )

    def on_mount(self):
        self.query_one(OptionList).focus()

    def on_option_list_option_selected(self, e: OptionList.OptionSelected) -> None:
        self.dismiss(e.option.id == "ok")

    def action_yes(self):
        self.dismiss(True)

    def action_no(self):
        self.dismiss(False)


class Ask(ModalScreen[str]):
    BINDINGS = [("escape", "cancel")]

    def __init__(self, prompt, default=""):
        super().__init__()
        self.prompt = prompt
        self.default = default

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.prompt, id="dialog-msg")
            yield Input(value=self.default, id="dialog-input")

    def on_mount(self):
        self.query_one(Input).focus()

    def on_input_submitted(self, e: Input.Submitted) -> None:
        self.dismiss(e.value.strip())

    def action_cancel(self):
        self.dismiss("")


class Menu(ModalScreen[str]):
    BINDINGS = [("escape", "cancel")]

    def __init__(self, meta):
        super().__init__()
        self.meta = meta

    def compose(self) -> ComposeResult:
        attach = self.meta["action"] == "attach"
        title = self.meta["session"] if attach else "new session"
        if attach:
            opened = self.meta.get("open")
            opts = [
                ("↵  go to its tab" if opened else "↵  open in a new tab", "open"),
                ("⊕  open in a new window", "window"),
                ("✎  rename", "rename"),
            ]
            if opened:  # only meaningful when it's actually open
                opts.append(("⏏  detach (close its tab, keep running)", "detach"))
            opts.append(("✕  close (kill session)", "close"))
        else:
            opts = [
                ("↵  new tab", "open"),
                ("⊕  new window", "window"),
                ("✎  name & create", "rename"),
            ]
        with Vertical(id="dialog"):
            yield Label(title, id="dialog-msg")
            yield OptionList(*[Option(t, id=i) for t, i in opts], id="menu-list")

    def on_mount(self):
        self.query_one(OptionList).focus()

    def on_option_list_option_selected(self, e: OptionList.OptionSelected) -> None:
        self.dismiss(e.option.id)

    def action_cancel(self):
        self.dismiss(None)


class Eosterm(App):
    COMMAND_PALETTE_BINDING = "p"  # open the command palette with p (not ctrl+p)
    CSS = """
    Screen { background: $surface; }
    #table-wrap {
        border: round $primary 40%;
        border-title-color: $primary;
        border-title-style: bold;
        border-title-align: center;
        padding: 1 2;
        margin: 1 2;
        height: 1fr;
    }
    DataTable { height: 1fr; background: $surface; }
    DataTable > .datatable--cursor { background: $primary 20%; color: $text; }
    DataTable > .datatable--header {
        color: $text-muted; text-style: bold; background: $surface;
    }
    #dialog {
        width: 56; height: auto; padding: 1 2; margin: 1;
        background: $panel; border: round $primary;
    }
    #dialog-msg { width: 1fr; padding: 0 0 1 0; content-align: center middle; }
    #dialog-input { margin-top: 1; }
    #menu-list {
        height: auto; max-height: 14; border: none;
        background: $panel; padding: 0;
    }
    #menu-list > .option-list--option { padding: 0 1; }
    #menu-list > .option-list--option-highlighted { background: $primary 25%; }
    ModalScreen { align: center middle; background: $background 70%; }
    """

    # Footer order (as requested): space w n d x t r a q
    BINDINGS = [
        Binding("space", "menu", "menu"),
        Binding("w", "window", "new window"),
        Binding("n", "rename", "rename"),
        Binding("d", "detach", "detach"),
        Binding("x", "close", "close"),
        Binding("t", "tmux", "tmux tree"),
        Binding("r", "reload", "refresh"),
        Binding("a", "awake", "keep-awake"),
        Binding("q", "quit", "quit"),
        # hidden: enter opens (default action), m / → also open the menu
        Binding("enter", "open", "open", show=False),
        Binding("m", "menu", "menu", show=False),
        Binding("right", "menu", "menu", show=False),
    ]

    def __init__(self):
        super().__init__()
        self.row_meta = []

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical(id="table-wrap") as w:
            w.border_title = "✦ eosterm"
            yield DataTable(cursor_type="row", zebra_stripes=False)
        yield Footer()

    def on_mount(self):
        self.title = "eosterm"
        login = _run(["__login"]).stdout.strip() or os.environ.get("USER", "")
        term = os.environ.get("TERM_PROGRAM", "terminal").lower()
        self.sub_title = f"{login} · {term}" if login else term
        for theme in ("tokyo-night", "catppuccin-mocha", "nord"):
            try:
                self.theme = theme
                break
            except Exception:
                continue
        t = self.query_one(DataTable)
        for col, key, w in (
            ("NAME", "name", 22),
            ("STATUS", "status", 9),
            ("STATE", "state", 8),
            ("UPTIME", "uptime", 7),
            ("FOLDER", "folder", 20),
            ("TABS", "tabs", 12),
            ("OPEN IN", "open", 9),
            ("AGENT", "agent", 10),
        ):
            t.add_column(col, key=key, width=w)
        t.focus()
        self.reload()
        self.set_interval(REFRESH, self.reload)

    # ---- data ----
    def reload(self):
        self._load()

    @work(exclusive=True, thread=True)
    def _load(self):
        data = gather()
        self.call_from_thread(self._populate, data)

    def _populate(self, data):
        t = self.query_one(DataTable)
        prev = t.cursor_row
        t.clear()
        self.row_meta = []
        for (host, is_local), info in data:
            # --- machine header row: ● local (teal) · ● remote (blue) · ○ offline (dim) ---
            if not info["reachable"]:
                t.add_row(
                    Text("○ ", style="dim") + Text(host, style="dim"),
                    Text("offline", style="dim italic"),
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                )
                self.row_meta.append({"host": host, "session": None, "action": "none"})
                continue
            color = LOCAL if is_local else REMOTE
            nm = Text("● ", style=color) + Text(host, style=f"bold {color}")
            status = Text("☕ awake", style=AMBER) if info["awake"] else Text("")
            t.add_row(nm, status, "", "", "", "", "", "")
            self.row_meta.append({"host": host, "session": None, "action": "machine"})
            # --- its sessions, indented under the machine ---
            for s in info["sessions"]:
                name = Text("  ") + Text(
                    s["auto"], style="bold #9ece6a" if s["attached"] else ""
                )
                state_style = {
                    "waiting": f"bold {AMBER}",
                    "working": "#9ece6a",
                    "running": "#9ece6a",
                    "idle": "dim",
                }.get(s["state"], "")
                t.add_row(
                    name,
                    Text(""),  # STATUS is machine-level
                    Text(s["state"], style=state_style),
                    Text(s["uptime"], style="dim"),
                    Text(s["dir"], style=CYAN),
                    Text(s["tabs"], style="dim"),
                    Text(
                        s["open_in"],
                        style=REMOTE if s["open_in"] != "detached" else "dim",
                    ),
                    Text("claude", style=VIOLET) if s["agent"] else Text(""),
                )
                self.row_meta.append(
                    {
                        "host": host,
                        "session": s["name"],
                        "action": "attach",
                        "open": s["open_in"] != "detached",
                    }
                )
            t.add_row(
                Text("  ＋ new session", style="dim italic"), "", "", "", "", "", "", ""
            )
            self.row_meta.append({"host": host, "session": "__NEW__", "action": "new"})
        if t.row_count:
            t.move_cursor(row=min(prev, t.row_count - 1))

    def _cur(self):
        t = self.query_one(DataTable)
        if 0 <= t.cursor_row < len(self.row_meta):
            return self.row_meta[t.cursor_row]
        return None

    def _spawn(self, args):
        subprocess.Popen(["bash", ENGINE, *args], env=_ENV)

    # ---- actions ----
    def on_data_table_row_selected(self, _):
        self.action_open()

    def action_menu(self):
        m = self._cur()
        if not m or m["action"] not in ("attach", "new"):
            return
        handlers = {
            "window": self.action_window,
            "rename": self.action_rename,
            "detach": self.action_detach,
            "close": self.action_close,
            "open": self.action_open,
        }

        def chosen(act):
            if act in handlers:
                handlers[act]()

        self.push_screen(Menu(m), chosen)

    def action_open(self):
        m = self._cur()
        if m and m["action"] in ("attach", "new"):
            self._spawn(["__open", "auto", m["host"], m["session"], m["action"]])

    def action_window(self):
        m = self._cur()
        if m and m["action"] in ("attach", "new"):
            self._spawn(["__open", "window", m["host"], m["session"], m["action"]])

    def action_detach(self):
        m = self._cur()
        if m and m["action"] == "attach":
            _run(["__detach", m["host"], m["session"]])
            self.reload()

    def action_close(self):
        m = self._cur()
        if not m or m["action"] != "attach":
            return

        def done(ok):
            if ok:
                _run(["__killraw", m["host"], m["session"]])
                self.reload()

        self.push_screen(
            Confirm(
                f"Shut down “{m['session']}” on {m['host']}?\nEverything running in it is killed."
            ),
            done,
        )

    def action_rename(self):
        m = self._cur()
        if not m or m["action"] not in ("attach", "new"):
            return
        if m["action"] == "new":

            def made(name):
                if name:
                    self._spawn(["__open", "tab", m["host"], name, "new"])

            self.push_screen(Ask("Name for the new session:"), made)
        else:

            def renamed(name):
                if name:
                    _run(["__renameto", m["host"], m["session"], name])
                    self.reload()

            self.push_screen(Ask(f"Rename “{m['session']}” to:", m["session"]), renamed)

    def action_tmux(self):
        m = self._cur()
        if m and m["host"]:
            self._spawn(["__openbrowse", m["host"]])

    def action_awake(self):
        m = self._cur()
        if m and m["host"]:
            _run(["__awaketoggle", m["host"]])
            self.reload()


def run():
    """Entry point: refuse to nest inside tmux, then launch the dashboard."""
    if os.environ.get("TMUX"):
        raise SystemExit(
            "Don't run eosterm inside tmux — open it in a plain terminal tab."
        )
    Eosterm().run()


if __name__ == "__main__":
    run()
