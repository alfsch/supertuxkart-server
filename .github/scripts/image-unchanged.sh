#!/usr/bin/env bash
# Tells publish.yaml whether the build changed the image at all: whether the platform images that were just built are exactly
# the platform images of the index that `latest` points at. If so there is nothing to release: no new tags, signature or GitHub
# release. A build that hits the cache produces the same image digests again; a change to the sources or the base image, or a
# build without cache (timestamps), produces new ones.
#
# What the build jobs export (one file per platform in a directory, the name being the hex of the digest) is not the image:
# with attestations on, a push by digest is a small index of the platform image and its attestation manifest, and that index,
# like the attestation, differs on every build. So each exported digest is resolved to the platform image in it first, and
# attestation manifests are ignored on both sides.
#
# Prints, for $GITHUB_OUTPUT:  unchanged=true|false   and   current=<digest of the index `latest` points at, or empty>
# Anything but an answer from the registry (a list, or "no such package" before the very first publish) fails instead of
# guessing: a wrong "unchanged" would skip a release that was needed.
#
# Usage: image-unchanged.sh IMAGE DIGEST_DIR
#        image-unchanged.sh decide IMAGE_DIGEST...   the verdict (true or false) from the index JSON of `latest` on stdin (for tests)
#        image-unchanged.sh resolve DIGEST           the platform image digest(s) in the manifest JSON on stdin (for tests)
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

# manifest JSON in, the digests of the platform images out: an index gives its children except the attestation manifests, a
# plain image manifest gives itself (the digest in $1)
resolve() {
  jq -r --arg self "$1" 'if has("manifests") then (.manifests[] | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest") | .digest) else $self end'
}

if [ "${1:-}" = decide ]; then shift; decide "$@"; exit; fi
if [ "${1:-}" = resolve ]; then resolve "${2:?usage: image-unchanged.sh resolve DIGEST}"; exit; fi

image="${1:?usage: image-unchanged.sh IMAGE DIGEST_DIR}"
dir="${2:?usage: image-unchanged.sh IMAGE DIGEST_DIR}"
repo="${image#ghcr.io/}"

exported=()
for f in "$dir"/*; do [ -e "$f" ] && exported+=("sha256:$(basename "$f")"); done
[ "${#exported[@]}" -gt 0 ] || { echo "no built digests in $dir" >&2; exit 1; }

tmp="$(mktemp)"; hdr="$(mktemp)"; trap 'rm -f "$tmp" "$hdr"' EXIT
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

# the platform image behind every exported digest (they were just pushed, so the registry has them)
built=()
for digest in "${exported[@]}"; do
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $token" -H "Accept: $accept" "https://ghcr.io/v2/$repo/manifests/$digest")"
  [ "$code" = 200 ] || { echo "cannot read $image@$digest: HTTP $code" >&2; exit 1; }
  while read -r image_digest; do built+=("$image_digest"); done < <(resolve "$digest" < "$tmp")
done
[ "${#built[@]}" -gt 0 ] || { echo "no platform image found behind the built digests" >&2; exit 1; }

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
