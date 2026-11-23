#!/usr/bin/env bash
# Tests the validation and the generated config of entrypoint.sh in the image given as $1, without starting STK: the game binary
# is replaced by a stub (mounted over /opt/stk/bin/supertuxkart) that prints its arguments and the config file the entrypoint
# wrote. smoke-test.sh covers what needs a real server (start delay, bots, shutdown). Used by test.yaml; runs the same on a
# workstation.
set -euo pipefail

IMAGE="${1:?usage: test-entrypoint.sh IMAGE}"

# the stub goes into a folder of the project: a Docker daemon on another host or in a sidecar sees only that (and the runner's
# workspace), not /tmp
WORK="$(mktemp -d "$PWD/.entrypoint-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"
cat > "$WORK/stk" <<'STUB'
#!/bin/sh
echo "ARGS: $*"
[ ! -f /home/stk/server_config.xml ] || cat /home/stk/server_config.xml
STUB
chmod 755 "$WORK/stk"
printf 'file secret\n' > "$WORK/password"
chmod 644 "$WORK/password"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# run the entrypoint with the given variables (VAR=value arguments); sets $code and $out
run() {
  local args=() v
  for v in "$@"; do args+=(-e "$v"); done
  code=0
  out="$(docker run --rm -v "$WORK/stk:/opt/stk/bin/supertuxkart:ro" -v "$WORK/password:/run/password:ro" \
    "${args[@]}" "$IMAGE" 2>&1)" || code=$?
}

# expect_error "message part" VAR=value ...: exit code 1 and the message on stderr
expect_error() {
  local msg="$1"; shift
  run "$@"
  if [ "$code" != 1 ] || ! grep -qF -- "entrypoint: " <<<"$out" || ! grep -qF -- "$msg" <<<"$out"; then
    fail "$* : expected exit 1 and '$msg', got exit $code: $out"
  else
    echo "ok: rejected $*"
  fi
}

# after run: exit code 0 and every text in the output
expect_in_output() {
  local what="$1" t; shift
  [ "$code" = 0 ] || { fail "$what: exit $code: $out"; return; }
  for t in "$@"; do
    grep -qF -- "$t" <<<"$out" || { fail "$what: '$t' missing in: $out"; return; }
  done
  echo "ok: $what"
}

# --- mode
expect_error "STK_MODE is required"
expect_error "unknown STK_MODE 'x'" STK_MODE=x

# --- server: every variable that is validated
expect_error "STK_PORT must be a number" STK_MODE=server STK_PORT=abc
expect_error "STK_DISCOVERY_PORT must be a number" STK_MODE=server STK_DISCOVERY_PORT=-1
expect_error "STK_START_DELAY must be a number" STK_MODE=server STK_START_DELAY=1.5
expect_error "STK_NETWORK must be lan or wan" STK_MODE=server STK_NETWORK=internet
expect_error "STK_GAME_MODE must be" STK_MODE=server STK_GAME_MODE=race
expect_error "STK_DIFFICULTY must be" STK_MODE=server STK_DIFFICULTY=hard
expect_error "STK_MAX_PLAYERS must be a number" STK_MODE=server STK_MAX_PLAYERS=many
expect_error "STK_AI_HANDLING must be true or false" STK_MODE=server STK_AI_HANDLING=yes
expect_error "STK_OWNER_LESS must be true or false" STK_MODE=server STK_OWNER_LESS=1
expect_error "STK_START_COUNTER must be a number" STK_MODE=server STK_START_COUNTER=1.5
expect_error "STK_START_COUNTER must be a number" STK_MODE=server STK_START_COUNTER=-5
expect_error "STK_MIN_PLAYERS must be a number" STK_MODE=server STK_MIN_PLAYERS=-2
expect_error "STK_MIN_PLAYERS must be a number" STK_MODE=server STK_MIN_PLAYERS=two
for ratio in abc -2 -0.5 1.2.3 . - 1e3; do
  expect_error "STK_LAPS_RATIO must be -1 or a number" STK_MODE=server STK_LAPS_RATIO=$ratio
done
expect_error "STK_SERVER_PASSWORD_FILE=/nonexistent is not readable" STK_MODE=server STK_SERVER_PASSWORD_FILE=/nonexistent
expect_error "a WAN server needs STK_ONLINE_USER" STK_MODE=server STK_NETWORK=wan
expect_error "STK_ONLINE_PASSWORD_FILE=/nonexistent is not readable" STK_MODE=server STK_NETWORK=wan STK_ONLINE_USER=u \
  STK_ONLINE_PASSWORD_FILE=/nonexistent

# --- server: the generated config
run STK_MODE=server
expect_in_output "defaults" 'server-port value="2759"' 'server-mode value="3"' 'server-difficulty value="1"' 'wan-server value="false"' \
  'server-max-players value="8"' 'owner-less value="true"' 'start-game-counter value="20"' 'min-start-game-players value="2"' \
  'auto-game-time-ratio value="-1"' 'ai-handling value="true"' 'server-name value="STK Server"' \
  "--server-config=/home/stk/server_config.xml"

run STK_MODE=server STK_PORT=2760 STK_GAME_MODE=soccer STK_DIFFICULTY=supertux STK_MAX_PLAYERS=12 STK_AI_HANDLING=false \
  STK_OWNER_LESS=false STK_START_COUNTER=45 STK_MIN_PLAYERS=4 STK_LAPS_RATIO=0.5 STK_SERVER_NAME=Cup
expect_in_output "custom values" 'server-port value="2760"' 'server-mode value="6"' 'server-difficulty value="3"' \
  'server-max-players value="12"' 'ai-handling value="false"' 'owner-less value="false"' 'start-game-counter value="45"' \
  'min-start-game-players value="4"' 'auto-game-time-ratio value="0.5"' 'server-name value="Cup"'

for pair in normal-race:3 time-trial:4 soccer:6 ffa:7 ctf:8; do
  run STK_MODE=server STK_GAME_MODE="${pair%:*}"
  expect_in_output "game mode ${pair%:*}" "server-mode value=\"${pair#*:}\""
done
for pair in novice:0 intermediate:1 expert:2 supertux:3; do
  run STK_MODE=server STK_DIFFICULTY="${pair%:*}"
  expect_in_output "difficulty ${pair%:*}" "server-difficulty value=\"${pair#*:}\""
done
for ratio in -1 0 2 0.25 .5; do
  run STK_MODE=server STK_LAPS_RATIO=$ratio
  expect_in_output "laps ratio $ratio" "auto-game-time-ratio value=\"$ratio\""
done
run STK_MODE=server STK_LAPS_RATIO=
expect_in_output "an empty laps ratio is the default" 'auto-game-time-ratio value="-1"'

run STK_MODE=server STK_PORT=
expect_in_output "an empty port is the default" 'server-port value="2759"'

# text that would break the XML
run STK_MODE=server 'STK_SERVER_NAME=A&B <"x">' 'STK_SERVER_PASSWORD=p&"<>'
expect_in_output "XML escaping" 'server-name value="A&amp;B &lt;&quot;x&quot;&gt;"' \
  'private-server-password value="p&amp;&quot;&lt;&gt;"'

run STK_MODE=server STK_SERVER_PASSWORD_FILE=/run/password
expect_in_output "password from a file" 'private-server-password value="file secret"'

run STK_MODE=server "STK_EXTRA_ARGS=--no-console-log --verbose"
expect_in_output "extra arguments" "--no-console-log --verbose"

# a config the operator mounts replaces the variables
mkdir "$WORK/config"
chmod 755 "$WORK/config"
printf '<?xml version="1.0"?>\n<server-config version="6" >\n    <server-name value="mounted" />\n    <wan-server value="false" />\n</server-config>\n' \
  > "$WORK/config/server_config.xml"
chmod 644 "$WORK/config/server_config.xml"
code=0
out="$(docker run --rm -v "$WORK/stk:/opt/stk/bin/supertuxkart:ro" -v "$WORK/config:/config:ro" -e STK_MODE=server -e STK_GAME_MODE=soccer \
  "$IMAGE" 2>&1)" || code=$?
expect_in_output "a mounted config is used as it is" 'server-name value="mounted"'

# --- bots
expect_error "STK_BOTS must be a number >= 1" STK_MODE=bots STK_BOTS=0
expect_error "STK_BOTS must be a number >= 1" STK_MODE=bots STK_BOTS=few
expect_error "STK_BOTS_WAIT must be a number" STK_MODE=bots STK_BOTS_WAIT=x
expect_error "STK_SERVER must be host:port" STK_MODE=bots STK_SERVER=localhost
expect_error "the port in STK_SERVER must be a number" STK_MODE=bots STK_SERVER=192.0.2.1:http
expect_error "nothing listens on UDP 2759 here after 1s" STK_MODE=bots STK_BOTS_WAIT=1

# a remote server cannot be probed: the bots start at once
run STK_MODE=bots STK_SERVER=192.0.2.1:2770 STK_BOTS=3
expect_in_output "bots for a remote server" "ARGS: --connect-now=192.0.2.1:2770 --network-ai=3"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all entrypoint checks passed"
