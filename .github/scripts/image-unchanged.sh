#!/usr/bin/env bash
# Tells publish.yaml whether the build changed the image at all: whether the platform images that were just built (by digest,
# one file per image in a directory, the name being the hex of the digest, as the build jobs export them) are exactly the
# platform images of the index that `latest` points at. If so there is nothing to release: no new tags, signature or GitHub
# release. A build that hits the cache produces the same image digests again; a change to the sources or the base image, or a
# build without cache (timestamps), produces new ones. Attestation manifests are ignored, they differ per build.
#
# Prints, for $GITHUB_OUTPUT:  unchanged=true|false   and   current=<digest of the index `latest` points at, or empty>
# Anything but an answer from the registry (a list, or "no such package" before the very first publish) fails instead of
# guessing: a wrong "unchanged" would skip a release that was needed.
#
# Usage: image-unchanged.sh IMAGE DIGEST_DIR
#        image-unchanged.sh decide NEW_DIGEST...   the verdict (true or false) from an index JSON on stdin (for tests)
# Needs curl and jq.
set -euo pipefail

# index JSON in, "true" when its platform images are exactly the digests given, else "false"
decide() {
  local new
  new="$(printf '%s\n' "$@" | jq -R . | jq -sc 'sort')"
  jq -r --argjson new "$new" '
    ([(.manifests // [])[] | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest") | .digest] | sort) as $have
    | ($have | length) > 0 and $have == $new'
}

if [ "${1:-}" = decide ]; then shift; decide "$@"; exit; fi

image="${1:?usage: image-unchanged.sh IMAGE DIGEST_DIR}"
dir="${2:?usage: image-unchanged.sh IMAGE DIGEST_DIR}"
repo="${image#ghcr.io/}"

built=()
for f in "$dir"/*; do [ -e "$f" ] && built+=("sha256:$(basename "$f")"); done
[ "${#built[@]}" -gt 0 ] || { echo "no built digests in $dir" >&2; exit 1; }

tmp="$(mktemp)"; hdr="$(mktemp)"; trap 'rm -f "$tmp" "$hdr"' EXIT
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
code="$(curl -sS -o "$tmp" -D "$hdr" -w '%{http_code}' -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/$repo/manifests/latest")"
case "$code" in
  200)
    current="$(grep -i '^docker-content-digest:' "$hdr" | tr -d '\r' | awk '{print $2}')"
    echo "unchanged=$(decide "${built[@]}" < "$tmp")"
    echo "current=$current"
    ;;
  404)
    echo "unchanged=false"
    echo "current="
    ;;
  *) echo "cannot read $image:latest: HTTP $code" >&2; exit 1 ;;
esac
