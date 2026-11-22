#!/usr/bin/env bash
# Prints the next patch number of the image for one STK version: one above the highest `<version>.<n>` tag the registry has
# (`1.5.0`, `1.5.1`, ...), or 0 when there is none yet. publish.yaml tags every publish with it, so the tags count the
# releases of one STK version, and a new STK version starts again at 0.
#
# The registry is the counter: nothing is committed or tagged in git for it. The package is public, so the tag list is read
# anonymously. Anything but a list (or "no such package" before the very first publish) fails instead of answering 0: a wrong
# 0 would hand out a number that is already taken. Publishes never run side by side (concurrency group `publish`) and the
# tags are only created at the end of a publish, so a failed run does not use up a number.
#
# Usage: next-patch.sh IMAGE VERSION       e.g. ghcr.io/alfsch/supertuxkart-server 1.5
#        next-patch.sh decide VERSION      the same from {"tags": [...]} on stdin (for tests)
# Needs curl and jq.
set -euo pipefail

# {"tags": [...]} in, the next number out: tags that are exactly <version>.<digits> count, everything else is ignored
decide() {
  jq -r --arg v "$1" '[(.tags // [])[] | select(test("^" + ($v | gsub("\\."; "\\.")) + "\\.[0-9]+$")) | split(".")[-1] | tonumber]
    | (max // -1) + 1'
}

if [ "${1:-}" = decide ]; then decide "${2:?usage: next-patch.sh decide VERSION}"; exit; fi

image="${1:?usage: next-patch.sh IMAGE VERSION}"
version="${2:?usage: next-patch.sh IMAGE VERSION}"
repo="${image#ghcr.io/}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" "https://ghcr.io/v2/$repo/tags/list?n=1000")"
case "$code" in
  200) [ "$(jq '.tags | length' "$tmp")" -lt 1000 ] || { echo "1000 tags or more: the list is paged, prune first" >&2; exit 1; } ;;
  404) echo '{"tags": []}' > "$tmp" ;;
  *) echo "cannot list the tags of $image: HTTP $code" >&2; exit 1 ;;
esac
decide "$version" < "$tmp"
