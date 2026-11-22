#!/usr/bin/env bash
# Checks the image given as $1 against the interface in README.md: user, labels and license files, a server that listens
# and passes healthcheck.sh, the start delay and the bots' exit when no server is there, bots that join a server, and a clean
# stop on SIGTERM. Used by test.yaml and publish.yaml, and runs the same on a workstation.
#
# What it does not check: a race. With STK_AI_HANDLING=true (the default) a lobby of only bots waits for a human, and the
# SERVER_ONLY binary cannot be one. Races were tried by hand, see the README.
#
# The bots share the server's network namespace and connect to 127.0.0.1, as they do next to the server in
# compose.example.yaml. A user-defined Docker network is avoided on purpose: on a rootless Docker daemon starting a second
# container on one can block for minutes.
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh IMAGE}"
BOTS="${STK_BOTS:-4}"
TIMEOUT="${SMOKE_TIMEOUT:-90}"
SUFFIX="$$"
SERVER="stk-smoke-server-$SUFFIX"; BOTS_C="stk-smoke-bots-$SUFFIX"; ALONE="stk-smoke-alone-$SUFFIX"

cleanup() { docker rm -f "$SERVER" "$BOTS_C" "$ALONE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
logs() { docker logs "$1" 2>&1 | strip; }
fail() { echo "FAIL: $*" >&2; echo "--- server log (tail)" >&2; logs "$SERVER" | tail -25 >&2 || true; echo "--- bots log (tail)" >&2; logs "$BOTS_C" | tail -25 >&2 || true; exit 1; }
# wait until `grep -q PATTERN` finds it in the log of container $1. The log is captured first: `grep -q` leaving early
# would make the pipeline fail under pipefail (SIGPIPE) although it matched.
has() { local out; out="$(logs "$1")"; grep -q "$2" <<<"$out"; }
wait_for() {
  local c="$1" pattern="$2" what="$3" t=0
  until has "$c" "$pattern"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || fail "$c stopped while waiting for: $what"
    [ "$t" -lt "$TIMEOUT" ] || fail "timed out after ${TIMEOUT}s waiting for: $what"
    sleep 2; t=$((t + 2))
  done
  echo "ok: $what"
}
in_image() { docker run --rm --entrypoint "$1" "$IMAGE" "${@:2}"; }

[ "$(in_image id -un)" = stk ] || fail "the image does not run as the user stk"
echo "ok: runs as stk"
[ "$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.licenses"}}')" = GPL-3.0-or-later ] \
  || fail "the license label is not GPL-3.0-or-later"
echo "ok: license label"
in_image sh -c 'test -s /opt/stk/share/doc/supertuxkart/COPYING && test -s /opt/stk/share/doc/supertuxkart-server/LICENSE' \
  || fail "a license file is missing"
echo "ok: license files ($(in_image sh -c 'find /opt/stk/share/doc/supertuxkart -type f | wc -l') upstream)"
in_image sh -c '! ldd /opt/stk/bin/supertuxkart | grep -q "not found"' || fail "a shared library is missing"
echo "ok: all shared libraries resolve"
code=0; out="$(in_image healthcheck.sh 2>&1)" || code=$?
[ "$code" = 2 ] || fail "healthcheck.sh without ports exited $code, not 2"
code=0; out="$(in_image healthcheck.sh 9999 2>&1)" || code=$?
{ [ "$code" = 1 ] && [ "$out" = "UDP 9999 not owned by PID 1" ]; } || fail "healthcheck.sh on a closed port: exit $code, '$out'"
echo "ok: healthcheck.sh usage error and failure"

# a delayed server with nobody on the discovery port: the delay runs out and it starts anyway
docker run -d --name "$ALONE" -e STK_MODE=server -e STK_START_DELAY=3 "$IMAGE" >/dev/null
wait_for "$ALONE" "timeout after 3s, starting anyway" "start delay times out"
wait_for "$ALONE" "STKHost: Listening has been started" "the delayed server starts"
docker rm -f "$ALONE" >/dev/null

# bots with no server on this host give up and exit non-zero, so a restart policy retries
code=0; docker run --rm -e STK_MODE=bots -e STK_BOTS_WAIT=3 "$IMAGE" >/dev/null 2>&1 || code=$?
[ "$code" = 1 ] || fail "bots without a server exited $code, not 1"
echo "ok: bots exit 1 without a server"

docker run -d --name "$SERVER" -e STK_MODE=server "$IMAGE" >/dev/null
wait_for "$SERVER" "STKHost: Listening has been started" "server is listening"
docker exec "$SERVER" /usr/local/bin/healthcheck.sh 2757 2759 >/dev/null || fail "healthcheck.sh 2757 2759 fails on the server"
echo "ok: healthcheck.sh 2757 2759"

docker run -d --name "$BOTS_C" --network "container:$SERVER" -e STK_MODE=bots -e STK_SERVER=127.0.0.1:2759 -e STK_BOTS="$BOTS" "$IMAGE" >/dev/null
wait_for "$BOTS_C" "The server accepted the connection" "bots connected"
wait_for "$SERVER" "New player Bot $BOTS .*with AI" "$BOTS bots joined"

for c in "$BOTS_C" "$SERVER"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || fail "$c is not running"
  docker stop "$c" >/dev/null
  code="$(docker inspect -f '{{.State.ExitCode}}' "$c")"
  [ "$code" = 0 ] || fail "$c exited with $code on SIGTERM"
done
echo "ok: both containers stop cleanly"
echo "smoke test passed"
