#!/usr/bin/env bash
# Sets ARG STK_SHA256 in the Dockerfile to the sha256 GitHub lists for the source tarball of the release that ARG STK_VERSION
# names. Run it on the branch of a Renovate PR that bumps STK_VERSION (the build fails on the old checksum until then), and
# commit the result. Needs curl and jq.
#
# Usage: update-stk-sha.sh [DOCKERFILE]    (default: Dockerfile next to .github/)
#
# It fails when the release has no asset of that exact name with a digest: GitHub lists digests only for releases from 2025
# on, and the Dockerfile downloads the .tar.gz, so a release that ships something else needs the Dockerfile adjusted first.
#
# The digest comes from the same GitHub release the tarball is downloaded from. It catches a corrupted or swapped download
# after this point, but it is no independent proof of the release itself: compare it with the release page when it matters.
set -euo pipefail

dockerfile="${1:-$(dirname "$0")/../../Dockerfile}"
[ -f "$dockerfile" ] || { echo "no such file: $dockerfile" >&2; exit 2; }

version="$(sed -n 's/^ARG STK_VERSION=//p' "$dockerfile" | head -n1)"
[[ "$version" =~ ^[0-9][0-9A-Za-z.-]*$ ]] || { echo "no STK_VERSION default in $dockerfile (got '$version')" >&2; exit 1; }

asset="SuperTuxKart-$version-src.tar.gz"
release="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  "https://api.github.com/repos/supertuxkart/stk-code/releases/tags/$version")" \
  || { echo "no release $version found on GitHub (or the API refused the request)" >&2; exit 1; }
sha256="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest' <<<"$release" | sed 's/^sha256://')"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "GitHub lists no sha256 for $asset on release $version" >&2; exit 1; }

current="$(sed -n 's/^ARG STK_SHA256=//p' "$dockerfile" | head -n1)"
if [ "$current" = "$sha256" ]; then
  echo "STK_SHA256 already matches $asset ($sha256)"
  exit 0
fi
sed -i "s/^ARG STK_SHA256=.*/ARG STK_SHA256=$sha256/" "$dockerfile"
echo "STK_SHA256 for $asset: $current -> $sha256"
echo "Check it against https://github.com/supertuxkart/stk-code/releases/tag/$version, then commit the Dockerfile."
