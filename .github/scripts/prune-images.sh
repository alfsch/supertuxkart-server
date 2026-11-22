#!/usr/bin/env bash
# Removes old versions of the published image (ghcr.io/<owner>/supertuxkart-server), used by prune.yaml. Adapted from
# prune-base-images.sh of github.com/alfsch/ai-agent-pods.
#
# A published tag is several package versions, not one: the index (tagged `latest`, the STK version and a dated tag such
# as 1.5-20261122) and, per architecture, an image manifest and an attestation manifest (untagged children of the index).
# A rule such as "delete the untagged versions" would remove the children of images that are still in use, so whole images
# are kept or removed:
#
#   keep   the KEEP_TAGS newest dated tags (by when the version was last pushed: the later of created_at and updated_at,
#          so a tag moved to an old digest is not taken for an old one) and every dated tag pushed within KEEP_DAYS
#          days, each with its children (read from the index); KEEP_TAGS is at least 1, so the newest tag stays whatever
#          its age
#   keep   versions with a tag that is not a dated one (`latest`, `1.5`, or something somebody pushed on purpose), whole:
#          with their children. The newest publish carries all of them, an older one loses them to the next publish.
#   keep   untagged versions younger than GRACE_HOURS: they may be the children of a publish that is still running
#   delete older dated tags and the untagged versions no kept image refers to
#
# Signature tags (sha256-<hex>, cosign) are understood too, though nothing signs this image: they stay for as long as the
# version they sign stays.
#
# It refuses to decide anything when no dated version is found or when the manifest list of a kept image could not be
# read: then a child could be taken for an orphan. DRY_RUN is true unless it is exactly "false"; a dry run prints the plan,
# one line per version with its full digest and tags, and deletes nothing. MAX_DELETES (empty: no limit) caps the
# deletions of a run, indexes first: what is left over is unreferenced by then and goes in the next run.
#
# Usage: prune-images.sh            lists the versions and the children of each index, prints the plan, deletes
#        prune-images.sh decide     the plan from JSON on stdin: {"versions": [<package versions as the API
#                                   returns them>], "children": {"<index digest>": ["<child digest>", ...]}}
# Needs gh (GH_TOKEN), jq and docker buildx; GITHUB_REPOSITORY_OWNER names the owner of the package. Bash 3.2 compatible.
# NOW (epoch seconds) replaces the clock for tests.
set -euo pipefail

KEEP_TAGS="${KEEP_TAGS:-5}"
KEEP_DAYS="${KEEP_DAYS:-30}"
GRACE_HOURS="${GRACE_HOURS:-24}"
DRY_RUN="${DRY_RUN:-true}"
MAX_DELETES="${MAX_DELETES:-}"
PACKAGE="${PACKAGE:-supertuxkart-server}"

for v in KEEP_TAGS KEEP_DAYS GRACE_HOURS; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$v must be a number, got '${!v}'" >&2; exit 2; }
done
[ -z "$MAX_DELETES" ] || [[ "$MAX_DELETES" =~ ^[0-9]+$ ]] || { echo "MAX_DELETES must be a number or empty, got '$MAX_DELETES'" >&2; exit 2; }

# Pure: versions and children in, one line per version out: action, id, digest, kind (index, signature, untagged, other),
# reason, tags (tab separated).
decide() {
  jq -r --argjson now "${NOW:-$(date +%s)}" --argjson keep_tags "$KEEP_TAGS" --argjson keep_days "$KEEP_DAYS" \
    --argjson grace_hours "$GRACE_HOURS" '
    def tags: (.metadata.container.tags // []);
    def ts: ([.created_at, (.updated_at // .created_at)] | map(fromdateiso8601) | max);
    def hashtag: test("^[0-9][0-9A-Za-z.]*-[0-9]{8}$");
    def sigtag: test("^sha256-[0-9a-f]{64}(\\.sig)?$");
    def sigkey: sub("\\.sig$"; "");
    if $keep_tags < 1 then error("KEEP_TAGS must be at least 1") else . end
    | (.children // {}) as $ch
    | .versions as $v
    | [$v[] | select(tags | any(hashtag))] as $hashed
    | if ($hashed | length) == 0 then error("no dated version found, refusing to decide anything") else . end
    | ($now - $keep_days * 86400) as $cutoff
    | ($now - $grace_hours * 3600) as $grace
    | ($hashed | sort_by(ts) | reverse | to_entries
       | map(select(.key < $keep_tags or (.value | ts) >= $cutoff)) | map(.value)) as $kept
    | [$v[] | select(tags | any((hashtag or sigtag) | not))] as $others
    | ([$kept[], $others[]] | map(select($ch[.name] == null) | .name)) as $unknown
    | if ($unknown | length) > 0 then error("the manifests of a kept index could not be read: " + ($unknown | join(" "))) else . end
    | ($kept | map(.name)) as $kept_names
    | ([$kept[], $others[]] | map($ch[.name][]?)) as $below
    | ([$v[] | select((tags | length) == 0 and ts >= $grace) | .name]) as $young
    | ($kept_names + ($others | map(.name)) + $below + $young) as $retained
    | [$v[] | select(tags | any(. as $s | sigtag and ($retained | any(. == ("sha256:" + ($s | ltrimstr("sha256-") | sigkey))))))] as $kept_sig_versions
    | ([$kept_sig_versions[] | select($ch[.name] == null) | .name]) as $unknown_sigs
    | if ($unknown_sigs | length) > 0 then error("the manifests of a kept signature could not be read: " + ($unknown_sigs | join(" "))) else . end
    | ($below + ($kept_sig_versions | map($ch[.name][]?))) as $protected
    | $v | sort_by(ts) | reverse | .[]
    | . as $x | tags as $t
    | (if ($protected | any(. == $x.name)) then ["keep", "untagged", "part of a kept image"]
       elif ($t | any((hashtag or sigtag) | not)) then ["keep", "other", "tag that is not a dated one: " + ($t | join(","))]
       elif ($t | any(hashtag)) then
         (if ($kept_names | any(. == $x.name))
          then ["keep", "index", "one of the newest " + ($keep_tags | tostring) + " dated tags or pushed within " + ($keep_days | tostring) + " days"]
          else ["delete", "index", "older tag beyond the limits"] end)
       elif ($t | any(sigtag)) then
         (if ($kept_sig_versions | any(.name == $x.name))
          then ["keep", "signature", "signature of a kept image"] else ["delete", "signature", "signature of a removed image"] end)
       elif ts >= $grace then ["keep", "untagged", "younger than the grace period"]
       else ["delete", "untagged", "untagged and not part of a kept image"] end)
    | [.[0], ($x.id | tostring), $x.name, .[1], .[2], ($t | join(","))] | @tsv'
}

if [ "${1:-}" = decide ]; then decide; exit; fi

OWNER="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER names the owner of the package}"
API="/users/$OWNER/packages/container/$PACKAGE"
IMAGE="ghcr.io/$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')/$PACKAGE"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

gh api --paginate "$API/versions?per_page=100" | jq -s 'add // []' > "$tmp/versions.json"
jq -e 'length > 0' "$tmp/versions.json" >/dev/null || { echo "no package versions found for $IMAGE: refusing to prune" >&2; exit 1; }
echo "$(jq 'length' "$tmp/versions.json") versions of $IMAGE"

# Every digest below an image (an index lists images, which may be indexes themselves), depth first. Fails when a manifest
# on the way cannot be read: a descendant that is not known would be taken for an orphan.
descend() {
  local raw kids k
  raw="$(docker buildx imagetools inspect --raw "$IMAGE@$1" 2>/dev/null)" || return 1
  kids="$(printf '%s' "$raw" | jq -r '(.manifests // [])[].digest' 2>/dev/null)" || return 1
  for k in $kids; do echo "$k"; descend "$k" || return 1; done
}

# What is below every tagged version: the indexes of the dated tags, the images somebody tagged otherwise (kept whole too),
# and the signatures, whose referrers index lists the Sigstore bundle (a single manifest has nothing below it). One that
# cannot be read is left out; decide refuses when a kept one is the one that is missing.
echo '{}' > "$tmp/children.json"
for digest in $(jq -r '.[] | select((.metadata.container.tags // []) | length > 0) | .name' "$tmp/versions.json"); do
  if list="$(descend "$digest")"; then
    kids="$(printf '%s\n' "$list" | jq -Rnc '[inputs | select(length > 0)]')"
    jq -c --arg d "$digest" --argjson k "$kids" '. + {($d): $k}' "$tmp/children.json" > "$tmp/children.next" && mv "$tmp/children.next" "$tmp/children.json"
  else
    echo "could not read the manifests below $digest" >&2
  fi
done

jq -n --slurpfile v "$tmp/versions.json" --slurpfile c "$tmp/children.json" '{versions: $v[0], children: $c[0]}' | decide > "$tmp/plan.tsv"

awk -F'\t' '{ printf "%-6s %-12s %-9s %s  %s  [%s]\n", $1, $2, $4, $3, $5, $6 }' "$tmp/plan.tsv"
total="$(wc -l < "$tmp/plan.tsv" | tr -d ' ')"
doomed="$(awk -F'\t' '$1 == "delete"' "$tmp/plan.tsv" | wc -l | tr -d ' ')"
echo "$doomed of $total versions to delete, $((total - doomed)) kept"

if [ "$DRY_RUN" != false ]; then echo "dry run: nothing deleted"; exit 0; fi

# Indexes first, then signatures, then the untagged manifests: an index or a signature that cannot be deleted must not
# lose what it points at, so a failure stops the run before its dependencies are touched (the next run tries again).
failed=0; attempts=0; limited=
for kind in index signature untagged; do
  while IFS=$'\t' read -r action id digest k _; do
    [ "$action" = delete ] && [ "$k" = "$kind" ] || continue
    if [ -n "$MAX_DELETES" ] && [ "$attempts" -ge "$MAX_DELETES" ]; then limited=1; continue; fi
    attempts=$((attempts + 1))
    if gh api -X DELETE "$API/versions/$id" >/dev/null; then echo "deleted $id"; else echo "could not delete $id ($digest)" >&2; failed=$((failed + 1)); fi
  done < "$tmp/plan.tsv"
  if [ "$kind" != untagged ] && [ "$failed" != 0 ]; then echo "an index or signature could not be deleted: what is below it is left alone" >&2; exit 1; fi
done
[ -z "$limited" ] || echo "stopped after $MAX_DELETES deletions (MAX_DELETES): the rest follows in a later run"
[ "$failed" = 0 ] || { echo "$failed deletions failed" >&2; exit 1; }
