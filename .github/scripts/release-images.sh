#!/usr/bin/env bash
# Lists the platform images behind every release-numbered tag (`1.5.0`, `1.5.1`, ...) that is still in the registry, for
# scan-releases.yaml. Releases that share a platform image (`1.5.0` to `1.5.4` do) are one entry, so each image is scanned once.
#
# Prints a JSON array, oldest first, one object per platform image:
#   {"platform": "linux/amd64", "digest": "sha256:...", "tags": ["1.5.0", ..., "1.5.4"], "id": "amd64-34d4221d9be7"}
# Anything but an answer from the registry fails instead of guessing: a missing image would be missing from the report. The package
# is public, so the registry is read anonymously.
#
# Usage: release-images.sh IMAGE          e.g. ghcr.io/alfsch/supertuxkart-server
#        release-images.sh group          the grouping from lines "<tag> <arch> <digest>" on stdin (for tests)
# Needs curl and jq.
set -euo pipefail

group() {
  jq -Rsc '
    def vkey: split(".") | map(tonumber);
    split("\n") | map(select(length > 0) | split(" ") | {tag: .[0], arch: .[1], digest: .[2]})
    | group_by([.arch, .digest])
    | map({platform: ("linux/" + .[0].arch), digest: .[0].digest, tags: (map(.tag) | sort_by(vkey)),
           id: (.[0].arch + "-" + (.[0].digest | .[7:19]))})
    | sort_by([(.tags[0] | vkey), .platform])'
}

if [ "${1:-}" = group ]; then group; exit; fi

image="${1:?usage: release-images.sh IMAGE}"
repo="${image#ghcr.io/}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"

code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" "https://ghcr.io/v2/$repo/tags/list?n=1000")"
[ "$code" = 200 ] || { echo "cannot list the tags of $image: HTTP $code" >&2; exit 1; }
[ "$(jq '.tags | length' "$tmp")" -lt 1000 ] || { echo "1000 tags or more: the list is paged, prune first" >&2; exit 1; }
tags="$(jq -r '.tags[]' "$tmp" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)"
[ -n "$tags" ] || { echo "no release-numbered tag found for $image" >&2; exit 1; }

for tag in $tags; do
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$repo/manifests/$tag")"
  [ "$code" = 200 ] || { echo "cannot read $image:$tag: HTTP $code" >&2; exit 1; }
  jq -e 'has("manifests")' "$tmp" >/dev/null || { echo "$image:$tag is not an image index" >&2; exit 1; }
  jq -r --arg t "$tag" '.manifests[]
    | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest")
    | select(.platform.architecture != "unknown")
    | "\($t) \(.platform.architecture) \(.digest)"' "$tmp"
done | group
