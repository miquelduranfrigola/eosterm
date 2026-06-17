# tuimux — a TUI for tmux across your tailnet

See and jump into every tmux session on every machine on your
[Tailscale](https://tailscale.com) tailnet, from one dashboard — over Tailscale SSH.

```
┌─ ✦ tuimux ──────────────────────────────────────────────────────────────┐
  NAME                STATUS   STATE    UPTIME  FOLDER          TABS       OPEN IN       AGENT
  ● miquel-macbook-pro  local    ☕ awake
    boring-hopper                waiting  3m      ~/code/ersilia  1 claude   this window   claude
    fierce-noether               idle     6h      ~               1 zsh      other window
    ＋ new session
  ● miquel-macmini      ssh
  ◐ raluy               no ssh           tailscale up --ssh
  ○ splunk-server       offline  2h ago
└────────────────────────────────────────────────────────────────────────────┘
  enter open tab · space menu · w new window · n rename · d detach · x close · t tmux tree · c tailscale · r refresh · a keep-awake · q quit
```

`●` this machine / a reachable remote (each its own colour, echoed in the
session's tmux status bar) · `◐` on the tailnet but no SSH (or too busy) · `○`
offline. Slow hosts are probed in the background and never block the UI.

## Install

```sh
pipx install .          # or: pip install .
```

Needs `tmux`, `ssh`, `tailscale`, and a terminal (Ghostty recommended). On each
remote machine: `sudo tailscale up --ssh` and install `tmux`.

## Use

```sh
tuimux                  # the dashboard — all you normally need
tuimux here [name]      # drop THIS terminal into a tmux session
tuimux init <host>      # auto-tmux a remote's SSH logins
tuimux doctor           # check setup
```

Open / rename / detach / close / keep-awake all happen in the dashboard (footer
lists the keys). Any tmux session shows up regardless of how it was started.

## Config

Optional `~/.config/tuimux/config` — `TUIMUX_*` vars, see `config.example`.
Hosts auto-derive from `tailscale status`.

## Dev

```sh
pip install -e '.[dev]' && pytest
```
