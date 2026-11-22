#!/usr/bin/env bash
# Offline tests of image-unchanged.sh on the shapes the registry really has. The first version of that script compared the
# digests the build jobs export with the platform images in `latest`, and those are not the same kind of digest: a push by
# digest is a small index of the platform image and its attestation manifest, and only the image is the same from build to
# build. These fixtures keep that shape. Needs jq.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/image-unchanged.sh"

IMG_AMD=sha256:1111111111111111111111111111111111111111111111111111111111111111
IMG_ARM=sha256:2222222222222222222222222222222222222222222222222222222222222222
ATT_OLD=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ATT_NEW=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# what a build job pushes by digest: the platform image and its attestation manifest
per_platform() { # image digest, attestation digest, arch
  cat <<JSON
{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
 {"digest":"$1","platform":{"os":"linux","architecture":"$3"}},
 {"digest":"$2","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}}]}
JSON
}
# what latest points at: both platform images and one attestation manifest each
latest=$(cat <<JSON
{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
 {"digest":"$IMG_AMD","platform":{"os":"linux","architecture":"amd64"}},
 {"digest":"$ATT_OLD","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}},
 {"digest":"$IMG_ARM","platform":{"os":"linux","architecture":"arm64"}},
 {"digest":"$ATT_OLD","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}}]}
JSON
)

failed=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected '$2', got '$3')" >&2; failed=1; fi
}

check "a per-platform index resolves to its platform image, not the attestation" "$IMG_AMD" \
  "$(per_platform "$IMG_AMD" "$ATT_NEW" amd64 | "$script" resolve sha256:index)"
check "a plain image manifest resolves to itself" "sha256:plain" \
  "$(echo '{"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}' | "$script" resolve sha256:plain)"

built=("$(per_platform "$IMG_AMD" "$ATT_NEW" amd64 | "$script" resolve x)" "$(per_platform "$IMG_ARM" "$ATT_NEW" arm64 | "$script" resolve x)")
check "same platform images, new attestations: unchanged" true "$(echo "$latest" | "$script" decide "${built[@]}")"
check "one platform image rebuilt: changed" false "$(echo "$latest" | "$script" decide "$IMG_AMD" sha256:3333333333333333333333333333333333333333333333333333333333333333)"
check "a platform missing: changed" false "$(echo "$latest" | "$script" decide "$IMG_AMD")"
check "an extra platform: changed" false "$(echo "$latest" | "$script" decide "${built[@]}" sha256:4444444444444444444444444444444444444444444444444444444444444444)"
check "the export digest itself is not an image of latest" false "$(echo "$latest" | "$script" decide sha256:index-amd sha256:index-arm)"
check "an index without platform images: changed" false "$(echo '{"manifests":[]}' | "$script" decide "$IMG_AMD")"

exit "$failed"
