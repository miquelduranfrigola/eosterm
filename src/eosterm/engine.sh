#!/usr/bin/env bash
#
# eosterm (Ersilia Open Source Terminals) — a terminal GUI to open, reach, and
# keep awake tmux sessions across your tailnet over Tailscale SSH.
#
# Usage:
#   eosterm                    Launch the dashboard (Textual UI)
#   eosterm new <host> [name]  Create (or attach) a tmux session on a host
#   eosterm awake [host]       Toggle keep-awake on a host (no host = list states)
#   eosterm init <host>        Make a host auto-tmux on SSH login (opt-in, asks first)
#   eosterm doctor             Check local deps + per-host reachability and remote tmux
#   eosterm -h|--help          This help
#
# The dashboard front-end lives in eosterm-tui.py (Python/Textual); this script
# is the engine it calls for discovery, probing, and actions.
#
# Config (optional): ~/.config/eosterm/config  — see config.example
#   EOSTERM_HOSTS, EOSTERM_LOGIN, EOSTERM_DEFAULT_SESSION, EOSTERM_SSH_TIMEOUT, EOSTERM_REFRESH
#
set -uo pipefail

# Public command name used when we re-invoke ourselves into a new terminal
# (set by the `eosterm` entry point); ENGINE_FILE is this script, for usage text.
SELF="${EOSTERM_BIN:-eosterm}"
ENGINE_FILE="$0"

# ----- defaults / config -----------------------------------------------------
EOSTERM_HOSTS="${EOSTERM_HOSTS:-}"
EOSTERM_LOGIN="${EOSTERM_LOGIN:-$USER}"
EOSTERM_DEFAULT_SESSION="${EOSTERM_DEFAULT_SESSION:-main}"
EOSTERM_SSH_TIMEOUT="${EOSTERM_SSH_TIMEOUT:-5}"
EOSTERM_REFRESH="${EOSTERM_REFRESH:-3}"          # panel auto-refresh interval (seconds)

CONFIG_FILE="${EOSTERM_CONFIG:-$HOME/.config/eosterm/config}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

NEW_SENTINEL="__NEW__"
NONE_SENTINEL="__NONE__"
AWAKE_SESSION="keep-awake"   # dedicated tmux session that holds the keep-awake lock

SSH_OPTS=(-o ConnectTimeout="$EOSTERM_SSH_TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# ----- helpers ---------------------------------------------------------------
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
note() { printf '\033[2m%s\033[0m\n'  "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '3,18p' "$ENGINE_FILE" | sed 's/^# \{0,1\}//'; }

# This machine's tailnet hostname (memoized).
SELF_HOST=""
self_host() {
  [ -n "$SELF_HOST" ] && { printf '%s' "$SELF_HOST"; return; }
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -1)"
  SELF_HOST="$(tailscale status 2>/dev/null | awk -v ip="$ip" '$1==ip {print $2; exit}')"
  [ -n "$SELF_HOST" ] || SELF_HOST="$(hostname -s 2>/dev/null)"
  printf '%s' "$SELF_HOST"
}
is_local() { [ "$1" = "$(self_host)" ]; }

# Docker-style random name:  <adjective>-<scientist>  (e.g. happy-curie).
docker_name() {
  local adj=(happy boring elegant nostalgic vibrant clever silly gentle bold cosmic
             eager fierce jolly keen lucid mellow quirky serene witty zen)
  local sci=(curie tesla turing hopper galileo darwin newton einstein lovelace bohr
             franklin hawking noether ramanujan feynman mendel pasteur faraday euler fermi)
  printf '%s-%s' "${adj[RANDOM % ${#adj[@]}]}" "${sci[RANDOM % ${#sci[@]}]}"
}

# Run a command string on a host — locally if it's this machine, else over SSH.
rssh() {
  local host="$1"; shift
  if is_local "$host"; then sh -c "$*"; else ssh "${SSH_OPTS[@]}" "$EOSTERM_LOGIN@$host" "$*"; fi
}

# Abort unless $1 is one of your currently-reachable machines.
require_reachable_host() {
  local only="$1" hosts
  [ -n "$only" ] || return 1
  hosts="$(discover_hosts)" || exit 1
  printf '%s\n' "$hosts" | grep -qx "$only" && return 0
  err "host '$only' is not in your reachable set:"; printf '%s\n' "$hosts" >&2; exit 1
}

# Discover this machine's tailnet owner and reachable same-owner peers.
discover_hosts() {
  if [ -n "$EOSTERM_HOSTS" ]; then
    printf '%s\n' $EOSTERM_HOSTS
    return
  fi
  have tailscale || { err "tailscale not found"; return 1; }
  local self_ip owner
  self_ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$self_ip" ] || { err "could not determine this machine's tailscale IP"; return 1; }
  owner="$(tailscale status 2>/dev/null | awk -v ip="$self_ip" '$1==ip {print $3; exit}')"
  [ -n "$owner" ] || { err "could not determine your tailnet owner from 'tailscale status'"; return 1; }
  printf '%s\n' "$(self_host)"           # this machine first — always reachable
  tailscale status 2>/dev/null | awk -v ip="$self_ip" -v owner="$owner" '
    $1!=ip && $3==owner {
      if ($0 ~ /offline/) next      # skip machines that are not currently up
      print $2
    }'
}

# ----- session probe ---------------------------------------------------------
# Remote probe: list sessions (S|…) plus which sessions are running Claude (C|…).
# Claude shows up as a `claude` process under a pane's shell, so we scan pane
# children — folded into one SSH round-trip.
REMOTE_PROBE='command -v tmux >/dev/null 2>&1 || { echo __NOTMUX__; exit 0; }
tmux list-sessions -F "S|#{session_name}|#{?session_attached,1,0}|#{session_windows}|#{pane_current_path}|#{pane_current_command}|#{session_created}" 2>/dev/null
tmux list-windows -a -F "W|#{session_name}|#{window_index}|#{window_name}|#{?window_active,1,0}" 2>/dev/null
tmux list-clients -F "L|#{client_session}|#{client_termname}" 2>/dev/null
tmux list-panes -a -F "#{session_name} #{pane_id} #{pane_pid}" 2>/dev/null | while read s pane ppid; do
  for ch in $(pgrep -P "$ppid" 2>/dev/null); do
    case "$(ps -p "$ch" -o comm= 2>/dev/null)" in
      *claude*)
        echo "C|$s"
        # "esc to interrupt" shows only while Claude is generating → working; else waiting
        if tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qi "esc to interrupt"; then
          echo "A|$s|working"
        else
          echo "A|$s|waiting"
        fi
        break ;;
    esac
  done
done
true'

# ----- machine-readable backend for the Textual UI ---------------------------
# List reachable hosts as:  host \t islocal(0/1)
hosts_data() {
  local h hosts
  hosts="$(discover_hosts)" || return 1
  for h in $hosts; do is_local "$h" && printf '%s\t1\n' "$h" || printf '%s\t0\n' "$h"; done
}

# Raw probe output for one host (S|/W|/L|/A|/C| lines); first line OK or UNREACHABLE.
probe_host() {
  local out
  if out="$(rssh "$1" "$REMOTE_PROBE" 2>/dev/null)"; then printf 'OK\n%s\n' "$out"; else echo UNREACHABLE; fi
}

# ----- attach / new ----------------------------------------------------------
# Run an action; when $4 = exec, replace the process (CLI). Otherwise return
# control to the caller after the SSH session ends (TUI home loop).
do_attach() {
  local host="$1" session="$2" action="$3" mode="${4:-return}" cmd nm
  case "$action" in
    attach) note "attaching to $session on $host …"
            cmd="tmux set -g set-titles on; tmux set -g set-titles-string '#S · #W'; tmux attach -t '$session'" ;;
    new)    nm="$session"; [ "$nm" = "$NEW_SENTINEL" ] && nm="$(docker_name)"
            note "opening session '$nm' on $host …"
            cmd="tmux set -g set-titles on; tmux set -g set-titles-string '#S · #W'; tmux new -A -s '$nm' -c \"\$HOME\"" ;;
    none)   err "$host is unreachable."; return 1 ;;
    *)      return 0 ;;
  esac
  if is_local "$host"; then
    if [ "$mode" = exec ]; then exec sh -c "$cmd"; else sh -c "$cmd"; fi
  else
    if [ "$mode" = exec ]; then exec ssh -t "${SSH_OPTS[@]}" "$EOSTERM_LOGIN@$host" "$cmd"
    else ssh -t "${SSH_OPTS[@]}" "$EOSTERM_LOGIN@$host" "$cmd"; fi
  fi
}

new_session() {
  local host="${1:-}" name="${2:-$(docker_name)}"
  [ -n "$host" ] || { err "usage: eosterm new <host> [session-name]"; exit 1; }
  require_reachable_host "$host"
  note "opening session '$name' on $host …"
  if is_local "$host"; then exec sh -c "tmux new -A -s '$name'"
  else exec ssh -t "${SSH_OPTS[@]}" "$EOSTERM_LOGIN@$host" "tmux new -A -s '$name'"; fi
}

# Detach a session: drop any attached clients so its tab closes, but keep it
# running in the background.
detach_session() {
  local host="$1" session="$2"
  case "$session" in "$NEW_SENTINEL"|"$NONE_SENTINEL") return 0 ;; esac
  rssh "$host" "tmux detach-client -s '$session' 2>/dev/null"
}

# tmux's own interactive control panel (choose-tree): the live session/window
# tree where arrows navigate, enter switches, x kills, etc.
tmux_browse() {            # runs inside the spawned tab; takes it over into tmux
  local host="$1" cmd
  # attach to a real session (not the keep-awake helper), then open the tree
  cmd='t=$(tmux ls -F "#{session_name}" 2>/dev/null | grep -vx "'"$AWAKE_SESSION"'" | head -n1)
if [ -n "$t" ]; then exec tmux attach -t "$t" \; choose-tree -Zs; else exec tmux attach \; choose-tree -Zs; fi'
  if is_local "$host"; then exec sh -c "$cmd"
  else exec ssh -t "${SSH_OPTS[@]}" "$EOSTERM_LOGIN@$host" "$cmd"; fi
}

open_browse() {            # open a Ghostty tab that drops into tmux's control panel
  local host="$1"
  osascript >/dev/null 2>&1 \
    -e 'tell application "Ghostty" to activate' \
    -e 'delay 0.2' \
    -e 'tell application "System Events" to keystroke "t" using command down' \
    -e 'delay 0.35' \
    -e "tell application \"System Events\" to keystroke \"exec $SELF __browse $host\"" \
    -e 'tell application "System Events" to key code 36' \
    || open -na Ghostty.app --args -e "$SELF" __browse "$host"
}

# Open a session in a new terminal surface. The new surface runs `eosterm
# __attach …`, which execs straight into ssh+tmux.
# Try to focus an existing Ghostty tab whose title matches the session name
# (tabs are titled after the tmux session via set-titles). Returns 0 if focused.
focus_tab() {
  local n="$1"
  [ ${#n} -ge 3 ] || return 1   # too-short names (0,1) are ambiguous — don't guess
  osascript >/dev/null 2>&1 <<OSA
tell application "System Events" to tell process "ghostty"
  set hit to false
  repeat with w in windows
    try
      repeat with r in radio buttons of tab group 1 of w
        if (name of r) contains "$n" then
          click r
          set hit to true
          exit repeat
        end if
      end repeat
    end try
    if hit then exit repeat
  end repeat
  if hit then
    set frontmost to true
  else
    error "not found"
  end if
end tell
OSA
}

open_surface() {
  local mode="$1" host="$2" session="$3" action="$4"
  case "$action" in attach|new) ;; *) return 0 ;; esac   # ignore headers/spacers
  case "$mode" in
    auto)
      # already open in a tab? jump to it. otherwise open a fresh tab.
      if [ "$action" = "attach" ] && focus_tab "$session"; then return 0; fi
      open_surface tab "$host" "$session" "$action" ;;
    window)
      open -na Ghostty.app --args -e "$SELF" __attach "$host" "$session" "$action" ;;
    tab)
      # Ghostty on macOS can't open a tab from the CLI, so drive its own new-tab
      # keybind via AppleScript, then type the command. Needs Accessibility
      # permission for the terminal; falls back to a new window.
      osascript >/dev/null 2>&1 \
        -e 'tell application "Ghostty" to activate' \
        -e 'delay 0.2' \
        -e 'tell application "System Events" to keystroke "t" using command down' \
        -e 'delay 0.35' \
        -e "tell application \"System Events\" to keystroke \"exec $SELF __attach $host $session $action\"" \
        -e 'tell application "System Events" to key code 36' \
        || open -na Ghostty.app --args -e "$SELF" __attach "$host" "$session" "$action" ;;
  esac
}

# ----- keep-awake ------------------------------------------------------------
# prints: on | off | "" (unreachable)
awake_state() {
  rssh "$1" "tmux has-session -t '$AWAKE_SESSION' 2>/dev/null && echo on || echo off" 2>/dev/null
}

# Turn keep-awake on for a host (OS-appropriate keeper inside a tmux session).
awake_on() {
  local host="$1" out
  out="$(rssh "$host" '
    os=$(uname)
    if [ "$os" = Darwin ]; then
      keeper="caffeinate -dimsu"
    elif command -v systemd-inhibit >/dev/null 2>&1; then
      keeper="systemd-inhibit --what=sleep:idle --who=eosterm --why=keep-awake sleep infinity"
    else
      echo __UNSUPPORTED__; exit 0
    fi
    tmux new -d -s '"'$AWAKE_SESSION'"' $keeper 2>/dev/null && echo __ON__ || echo __FAIL__
  ' 2>/dev/null)"
  case "$out" in
    *__ON__*)          note "$host: keep-awake ON" ;;
    *__UNSUPPORTED__*) err  "$host: no supported keep-awake method (need caffeinate or systemd-inhibit)" ;;
    *)                 err  "$host: failed to enable keep-awake" ;;
  esac
}

awake_off() {
  rssh "$1" "tmux kill-session -t '$AWAKE_SESSION' 2>/dev/null" && note "$1: keep-awake OFF"
}

toggle_awake() {
  local host="$1" st
  st="$(awake_state "$host")"
  case "$st" in
    on)  awake_off "$host" ;;
    off) awake_on  "$host" ;;
    *)   err "$host is unreachable." ;;
  esac
}

awake_table() {
  local hosts h st tag
  hosts="$(discover_hosts)" || return 1
  for h in $hosts; do
    st="$(awake_state "$h")"; tag=""; is_local "$h" && tag="   (this machine)"
    case "$st" in
      on)  printf '  %-15s awake%s\n' "$h" "$tag" ;;
      off) printf '  %-15s normal%s\n' "$h" "$tag" ;;
      *)   printf '  %-15s unreachable%s\n' "$h" "$tag" ;;
    esac
  done
}

# ----- init (auto-tmux on login) ---------------------------------------------
autotmux_snippet() {
cat <<SNIP
# >>> eosterm auto-tmux >>>
# Auto-attach interactive SSH logins to a persistent tmux session, so every
# terminal opened here is discoverable / re-attachable via eosterm.
# Skip for one connection with:  EOSTERM_NO_AUTOTMUX=1 ssh <host>
if [ -n "\$SSH_CONNECTION" ] && [ -z "\$TMUX" ] && [ -z "\$EOSTERM_NO_AUTOTMUX" ] && command -v tmux >/dev/null 2>&1; then
  case \$- in *i*) tmux new -A -s '$EOSTERM_DEFAULT_SESSION' ;; esac
fi
# <<< eosterm auto-tmux <<<
SNIP
}

init_host() {
  local host="${1:-}" rc snippet ans
  [ -n "$host" ] || { err "usage: eosterm init <host>"; exit 1; }
  require_reachable_host "$host"
  rc="$(rssh "$host" 'case "$SHELL" in *zsh) echo "$HOME/.zshrc";; *bash) echo "$HOME/.bashrc";; *) echo "$HOME/.profile";; esac')"
  [ -n "$rc" ] || { err "could not determine remote shell rc on $host"; exit 1; }
  if rssh "$host" "grep -q 'eosterm auto-tmux' '$rc' 2>/dev/null"; then
    note "$host already initialized ($rc) — nothing to do."; return 0
  fi
  snippet="$(autotmux_snippet)"
  printf '\nWill append to %s:%s\n\n%s\n\n' "$host" "$rc" "$snippet"
  printf 'Proceed? [y/N] '; read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) note "aborted — nothing changed."; return 1 ;; esac
  if printf '%s\n' "$snippet" | rssh "$host" "cat >> '$rc'"; then
    note "done — new SSH logins to $host will auto-attach to tmux '$EOSTERM_DEFAULT_SESSION'."
    note "skip it for one session with:  EOSTERM_NO_AUTOTMUX=1 ssh $EOSTERM_LOGIN@$host"
  else
    err "failed to write $rc on $host"; exit 1
  fi
}

# ----- doctor ----------------------------------------------------------------
doctor() {
  printf 'eosterm doctor\n==============\n'
  for dep in tailscale ssh tmux; do
    if have "$dep"; then printf '  [ok]   %s\n' "$dep"
    else printf '  [MISS] %s\n' "$dep"; fi
  done
  echo
  local self_ip owner hosts h
  self_ip="$(tailscale ip -4 2>/dev/null | head -1)"
  owner="$(tailscale status 2>/dev/null | awk -v ip="$self_ip" '$1==ip {print $3; exit}')"
  printf 'this machine: %s  (owner %s)\n' "${self_ip:-?}" "${owner:-?}"
  printf 'login user:   %s\n\n' "$EOSTERM_LOGIN"
  hosts="$(discover_hosts)" || return 1
  printf 'machines:\n'
  for h in $hosts; do
    local probe
    if is_local "$h"; then
      if have tmux; then printf '  [ok]   %-15s this machine (local)\n' "$h"
      else printf '  [warn] %-15s this machine — tmux NOT installed\n' "$h"; fi
      continue
    fi
    probe="$(rssh "$h" 'command -v tmux >/dev/null 2>&1 && echo tmux-ok || echo tmux-missing' 2>/dev/null)"
    case "$probe" in
      tmux-ok)      printf '  [ok]   %-15s ssh + tmux\n' "$h" ;;
      tmux-missing) printf '  [warn] %-15s ssh ok, tmux NOT installed\n' "$h" ;;
      *)            printf '  [FAIL] %-15s no Tailscale SSH (run "sudo tailscale up --ssh" there + check ACLs)\n' "$h" ;;
    esac
  done
}

# ----- dispatch --------------------------------------------------------------
case "${1:-}" in
  new           ) shift; new_session "${1:-}" "${2:-}" ;;
  awake         ) shift; if [ -n "${1:-}" ]; then require_reachable_host "$1"; toggle_awake "$1"; else awake_table; fi ;;
  init          ) shift; init_host "${1:-}" ;;
  doctor        ) doctor ;;
  # ----- backend called by the Textual UI -----
  __hosts       ) hosts_data ;;
  __probe       ) shift; probe_host "${1:-}" ;;
  __login       ) printf '%s\n' "$EOSTERM_LOGIN" ;;
  __attach      ) shift; do_attach "${1:-}" "${2:-}" "${3:-}" exec ;;
  __open        ) shift; open_surface "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  __detach      ) shift; detach_session "${1:-}" "${2:-}" ;;
  __killraw     ) shift; rssh "${1:-}" "tmux kill-session -t '${2:-}' 2>/dev/null" ;;
  __renameto    ) shift; rssh "${1:-}" "tmux rename-session -t '${2:-}' '${3:-}'" ;;
  __browse      ) shift; tmux_browse "${1:-}" ;;
  __openbrowse  ) shift; open_browse "${1:-}" ;;
  __awaketoggle ) shift; toggle_awake "${1:-}" >/dev/null 2>&1 ;;
  -h|--help|"" ) usage ;;
  *             ) usage; exit 1 ;;
esac
