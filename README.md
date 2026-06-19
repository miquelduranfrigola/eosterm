# A TUI for tmux across tailnet

See and jump into every tmux session on every machine on your
[Tailscale](https://tailscale.com) tailnet, from one dashboard — over Tailscale SSH.

## Install

```sh
pip install .          # or: pipx install .
```

Needs `tmux`, `ssh`, `tailscale`, and a terminal. Opening sessions in new
tabs/windows is supported on:

- **macOS** — **Ghostty** (recommended) and **Apple Terminal.app**; any other
  terminal falls back to Terminal.app.
- **Linux** — **GNOME Terminal** (real tabs + windows), or **any** terminal via a
  `TUIMUX_TERM_CMD` template (e.g. `kitty -e sh -c {cmd}`). Jumping to an
  already-open session and the "OPEN IN" column additionally need **X11** with
  `wmctrl` (or `xdotool`) installed — on Wayland every open is a new surface.

Force a driver with `TUIMUX_TERM` and override platform detection with `TUIMUX_OS`
if needed. Run `tuimux doctor` to see what's detected. On each remote machine:
`sudo tailscale up --ssh` and install `tmux`.

## Use

```sh
tuimux                  # the dashboard — all you normally need
tuimux attach [name]    # put this terminal into a tmux session (attach or create)
tuimux detach           # detach this terminal; the session keeps running
tuimux init <host>      # auto-tmux a remote's SSH logins
tuimux doctor           # check setup
```

Open / rename / detach / close / keep-awake all happen in the dashboard (footer
lists the keys). Any tmux session shows up regardless of how it was started.
