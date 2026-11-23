#!/bin/sh
# STK_MODE=server: dedicated SuperTuxKart server
# STK_MODE=bots:   AI karts that connect to a server as a client
# The interface (variables, ports, exit behaviour) is in README.md.
set -eu

STK=/opt/stk/bin/supertuxkart

die() { echo "entrypoint: $*" >&2; exit 1; }

# value of $1, or the content of the file named by $1_FILE (Docker secrets), else empty
env_or_file() {
  eval "_val=\${$1:-}"
  eval "_file=\${$1_FILE:-}"
  if [ -n "$_file" ]; then
    [ -r "$_file" ] || die "$1_FILE=$_file is not readable"
    _val=$(cat "$_file")
  fi
  printf '%s' "$_val"
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# -1 (the default: the track's own laps) or a number of at least 0 with an optional decimal part
is_ratio() { case "$1" in -1) return 0 ;; ''|.|*[!0-9.]*|*.*.*) return 1 ;; *) return 0 ;; esac; }
is_bool() { case "$1" in true|false) return 0 ;; *) return 1 ;; esac; }

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# true if some socket on this network namespace is bound to UDP port $1 (with host networking: any process on the host)
udp_bound() {
  _hex=$(printf '%04X' "$1")
  awk -v p=":$_hex" '$2 ~ (p "$") {f=1} END {exit !f}' /proc/net/udp /proc/net/udp6 2>/dev/null
}

# STK_EXTRA_ARGS is split on whitespace on purpose
# shellcheck disable=SC2086
run() { exec "$STK" "$@" ${STK_EXTRA_ARGS:-}; }

mode="${STK_MODE:-}"
[ -n "$mode" ] || die "STK_MODE is required (server or bots)"

case "$mode" in
  server)
    port="${STK_PORT:-2759}"
    is_uint "$port" || die "STK_PORT must be a number, got '$port'"
    discovery="${STK_DISCOVERY_PORT:-2757}"
    is_uint "$discovery" || die "STK_DISCOVERY_PORT must be a number, got '$discovery'"
    delay="${STK_START_DELAY:-0}"
    is_uint "$delay" || die "STK_START_DELAY must be a number, got '$delay'"

    config=/home/stk/server_config.xml
    if [ -f /config/server_config.xml ]; then
      # copy: STK rewrites its config file, and the mount is read-only
      cp /config/server_config.xml "$config"
      grep -q '<wan-server value="true"' "$config" && wan=true || wan=false
    else
      network="${STK_NETWORK:-lan}"
      case "$network" in lan) wan=false ;; wan) wan=true ;; *) die "STK_NETWORK must be lan or wan, got '$network'" ;; esac
      case "${STK_GAME_MODE:-normal-race}" in
        normal-race) mode_id=3 ;; time-trial) mode_id=4 ;; soccer) mode_id=6 ;; ffa) mode_id=7 ;; ctf) mode_id=8 ;;
        *) die "STK_GAME_MODE must be normal-race, time-trial, soccer, ffa or ctf, got '${STK_GAME_MODE}'" ;;
      esac
      case "${STK_DIFFICULTY:-intermediate}" in
        novice) diff_id=0 ;; intermediate) diff_id=1 ;; expert) diff_id=2 ;; supertux) diff_id=3 ;;
        *) die "STK_DIFFICULTY must be novice, intermediate, expert or supertux, got '${STK_DIFFICULTY}'" ;;
      esac
      max_players="${STK_MAX_PLAYERS:-8}"
      is_uint "$max_players" || die "STK_MAX_PLAYERS must be a number, got '$max_players'"
      ai_handling="${STK_AI_HANDLING:-true}"
      is_bool "$ai_handling" || die "STK_AI_HANDLING must be true or false, got '$ai_handling'"
      owner_less="${STK_OWNER_LESS:-true}"
      is_bool "$owner_less" || die "STK_OWNER_LESS must be true or false, got '$owner_less'"
      start_counter="${STK_START_COUNTER:-20}"
      is_uint "$start_counter" || die "STK_START_COUNTER must be a number, got '$start_counter'"
      min_players="${STK_MIN_PLAYERS:-1}"
      is_uint "$min_players" || die "STK_MIN_PLAYERS must be a number, got '$min_players'"
      laps_ratio="${STK_LAPS_RATIO:--1}"
      is_ratio "$laps_ratio" || die "STK_LAPS_RATIO must be -1 or a number of at least 0, got '$laps_ratio'"
      password=$(env_or_file STK_SERVER_PASSWORD)
      cat > "$config" <<XML
<?xml version="1.0"?>
<server-config version="6" >
    <server-name value="$(xml_escape "${STK_SERVER_NAME:-STK Server}")" />
    <server-port value="$port" />
    <server-mode value="$mode_id" />
    <server-difficulty value="$diff_id" />
    <wan-server value="$wan" />
    <server-max-players value="$max_players" />
    <private-server-password value="$(xml_escape "$password")" />
    <owner-less value="$owner_less" />
    <start-game-counter value="$start_counter" />
    <min-start-game-players value="$min_players" />
    <auto-game-time-ratio value="$laps_ratio" />
    <ai-handling value="$ai_handling" />
</server-config>
XML
    fi

    # Only one instance per host can own the LAN discovery port. A delayed instance waits until another one has bound it
    # (or the time is up), so the instance meant to be discoverable gets it whatever the start order. Before the exec
    # this container owns no sockets: any owner of the port is another instance.
    if [ "$delay" -gt 0 ]; then
      waited=0; bound=no
      while [ "$waited" -lt "$delay" ]; do
        if udp_bound "$discovery"; then bound=yes; break; fi
        sleep 1; waited=$((waited + 1))
      done
      if [ "$bound" = yes ]; then
        echo "discovery port $discovery bound after ${waited}s"
      else
        echo "timeout after ${delay}s, starting anyway"
      fi
    fi

    if [ "$wan" = true ]; then
      user="${STK_ONLINE_USER:-}"
      [ -n "$user" ] && [ -n "${STK_ONLINE_PASSWORD_FILE:-}" ] \
        || die "a WAN server needs STK_ONLINE_USER and STK_ONLINE_PASSWORD_FILE (the path of a Docker secret)"
      [ -r "$STK_ONLINE_PASSWORD_FILE" ] || die "STK_ONLINE_PASSWORD_FILE=$STK_ONLINE_PASSWORD_FILE is not readable"
      # saves the login for the server below; the password is on this command line only for the moment it takes
      "$STK" --init-user --login="$user" --password="$(cat "$STK_ONLINE_PASSWORD_FILE")" >/dev/null
    fi

    # STK's network console reads stdin: without a terminal (no `docker run -i`) it spins at 100% of a core
    run --server-config="$config" ${STK_CONSOLE:+--network-console}
    ;;

  bots)
    server="${STK_SERVER:-127.0.0.1:2759}"
    bots="${STK_BOTS:-4}"
    is_uint "$bots" && [ "$bots" -ge 1 ] || die "STK_BOTS must be a number >= 1, got '$bots'"
    wait_s="${STK_BOTS_WAIT:-60}"
    is_uint "$wait_s" || die "STK_BOTS_WAIT must be a number, got '$wait_s'"
    case "$server" in *:*) host="${server%:*}"; port="${server##*:}" ;; *) die "STK_SERVER must be host:port, got '$server'" ;; esac
    is_uint "$port" || die "the port in STK_SERVER must be a number, got '$server'"

    # STK does not leave when its server is not there (it retries four times and then idles) or goes away (it keeps
    # idling), so the restart policy would never reconnect the bots. For a server on this host the socket tells: wait for
    # it, exit if it does not show up in time, and stop the bots when it disappears. A remote server cannot be probed.
    case "$host" in 127.*|localhost|::1|\[::1\])
      waited=0
      until udp_bound "$port"; do
        [ "$waited" -lt "$wait_s" ] || die "nothing listens on UDP $port here after ${wait_s}s: exiting so the restart policy retries"
        sleep 1; waited=$((waited + 1))
      done
      (
        while udp_bound "$port"; do sleep 2; done
        echo "entrypoint: the server on UDP $port is gone, stopping the bots so the restart policy reconnects them" >&2
        kill -TERM 1
      ) &
      ;;
    esac
    run --connect-now="$server" --network-ai="$bots"
    ;;

  *) die "unknown STK_MODE '$mode' (server or bots)" ;;
esac
