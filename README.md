# eosterm — Ersilia Open Source Terminals

A terminal dashboard to **open, reach, and keep-awake tmux sessions across your
[Tailscale](https://tailscale.com) tailnet**. Sit at any machine, see every
session running on your other machines, and jump into one — over Tailscale SSH.

```
┌─ ✦ eosterm ──────────────────────────────────────────────────────────────┐
  NAME                STATUS    STATE    UPTIME  FOLDER          TABS       OPEN IN  AGENT
  ● miquel-macbook-pro  ☕ awake
    boring-hopper                waiting  3m      ~/code/ersilia  1 claude   ghostty  claude
    fierce-noether               idle     6h      ~               1 zsh      ghostty
    ＋ new session
  ○ macmini   offline
└────────────────────────────────────────────────────────────────────────────┘
  space menu · w new window · n rename · d detach · x close · t tmux tree · r refresh · a keep-awake · q quit
```

- **●** teal = this machine · **●** blue = remote · **○** dim = offline
- **STATUS** = machine condition (`☕ awake`, `offline`) · **STATE** = session activity (`idle`/`running`/`waiting`)
- **OPEN IN** = which terminal hosts it now (`ghostty`) or `detached` · **AGENT** = `claude` when a Claude session is detected

## How it works

Plain SSH only opens a *new* shell — you can't grab an arbitrary terminal
window. So eosterm uses the **tmux convention**: your work lives in tmux
sessions, which persist and can be re-attached from anywhere. eosterm =
**Tailscale** (network) + **Tailscale SSH** (auth) + **tmux** (persistent
sessions), with a Textual dashboard on top.

## Install

eosterm is a Python package with a bundled bash engine. Install it isolated
(recommended) with [pipx](https://pipx.pypa.io):

```sh
pipx install .
```

or into a virtualenv with pip:

```sh
python3 -m venv ~/.venvs/eosterm
~/.venvs/eosterm/bin/pip install .
```

Requirements on this machine: `tmux`, `ssh`, `tailscale`, a terminal (Ghostty
recommended — tab spawning is wired for it). On each remote machine: enable
Tailscale SSH (`sudo tailscale up --ssh`) and install `tmux`.

## Usage

```sh
eosterm                      # launch the dashboard
eosterm new <host> [name]    # create (or attach) a tmux session on a host
eosterm awake [host]         # toggle keep-awake on a host (no host = list states)
eosterm init <host>          # make a host auto-tmux on SSH login (opt-in, asks first)
eosterm doctor               # check deps + per-host reachability
```

In the dashboard: **enter** opens the highlighted session in a new tab (or jumps
to its tab if already open), **w** opens it in a new window, **space** opens an
actions menu (open / window / rename / detach / close), and the footer lists the
rest. Detach with the tmux prefix then `d`; the session keeps running.

## Configuration

Optional, at `~/.config/eosterm/config` (see `config.example`):
`EOSTERM_HOSTS`, `EOSTERM_LOGIN`, `EOSTERM_DEFAULT_SESSION`, `EOSTERM_SSH_TIMEOUT`,
`EOSTERM_REFRESH`. Hosts are otherwise auto-derived from `tailscale status`
(machines you own, plus this one).

## Layout

```
src/eosterm/
  __init__.py      package metadata
  cli.py           console entry point (`eosterm`)
  app.py           the Textual dashboard
  engine.sh        bash engine: discovery, probing, tmux/ssh/Ghostty actions
```
