#!/usr/bin/env bash
# Builds the vulnerability report of scan-releases.yaml from Trivy's JSON output, and puts it into GitHub release notes.
#
#   scan-report.sh build MATRIX_JSON SCAN_DIR OUT_DIR [DATE]
#       MATRIX_JSON  the output of release-images.sh
#       SCAN_DIR     one `<id>.json` per matrix entry: `trivy image --format json` of that platform image
#       OUT_DIR      gets README.md (the index), details/<id>.md (one page per image) and release-blocks/<tag>.md (the block for the
#                    notes of the GitHub release of that tag)
#   scan-report.sh merge BLOCK_FILE     reads release notes on stdin, writes them with the block replaced (or appended)
#
# The report counts what Trivy was asked for: fixable HIGH and CRITICAL vulnerabilities of the Debian packages. Strings that come from
# the vulnerability database are stripped of the characters that would break the Markdown (pipes, backticks, angle brackets, newlines).
# A matrix entry without a scan result fails the build instead of showing up as clean.
# Needs jq. GITHUB_REPOSITORY and IMAGE name the repository and the image (defaults: alfsch/supertuxkart-server).
set -euo pipefail

START='<!-- vulnerabilities:start -->'
END='<!-- vulnerabilities:end -->'
repo="${GITHUB_REPOSITORY:-alfsch/supertuxkart-server}"
image="${IMAGE:-ghcr.io/$repo}"
branch_url="https://github.com/$repo/blob/scan-reports"

# Markdown-safe text from the vulnerability database
JQ_SAFE='def s: tostring | gsub("[|<>`\\r\\n]"; " ");'
JQ_LABEL='def rels: if length > 1 then "\(.[0]) to \(.[-1])" else .[0] end;'

merge() {
  local block="${1:?usage: scan-report.sh merge BLOCK_FILE}" body
  body="$(cat)"
  if grep -qF "$START" <<<"$body" && grep -qF "$END" <<<"$body"; then
    awk -v blockfile="$block" -v start="$START" -v end="$END" '
      BEGIN { while ((getline l < blockfile) > 0) blk = blk l "\n" }
      index($0, start) { printf "%s", blk; skip = 1; next }
      index($0, end)   { skip = 0; next }
      !skip { print }' <<<"$body"
  else
    printf '%s\n\n' "$body"
    cat "$block"
  fi
}

build() {
  local matrix="${1:?usage: scan-report.sh build MATRIX_JSON SCAN_DIR OUT_DIR [DATE]}" scans="${2:?}" out="${3:?}" date="${4:-$(date -u +%F)}"
  mkdir -p "$out/details" "$out/release-blocks"
  local n i id
  n="$(jq length "$matrix")"
  [ "$n" -gt 0 ] || { echo "the matrix is empty" >&2; exit 1; }
  for i in $(seq 0 $((n - 1))); do
    id="$(jq -r ".[$i].id" "$matrix")"
    [ -s "$scans/$id.json" ] || { echo "no scan result for $id" >&2; exit 1; }
    jq -e 'has("Results") or has("ArtifactName")' "$scans/$id.json" >/dev/null || { echo "$scans/$id.json is not a Trivy report" >&2; exit 1; }
  done

  # one detail page per image
  for i in $(seq 0 $((n - 1))); do
    id="$(jq -r ".[$i].id" "$matrix")"
    jq -r --slurpfile m "$matrix" --argjson i "$i" --arg date "$date" --arg image "$image" "$JQ_SAFE $JQ_LABEL"'
      ($m[0][$i]) as $e
      | ([.Results[]?.Vulnerabilities[]?]) as $v
      | "# Vulnerabilities of \($e.tags | rels) (\($e.platform))\n\n"
        + "Image: `\($image)@\($e.digest)`\n\n"
        + "Releases with this image: \($e.tags | map("`" + . + "`") | join(", "))\n\n"
        + "Scanned \($date) UTC: **\($v | map(select(.Severity == "CRITICAL")) | length) critical, \($v | map(select(.Severity == "HIGH")) | length) high** "
        + "(fixable vulnerabilities of the Debian packages; the libraries compiled into the STK binary and the game data are not covered).\n\n"
        + (if ($v | length) == 0 then "No findings.\n" else
            "| Package | Installed | Fixed in | Severity | CVEs |\n|---|---|---|---|---|\n"
            + ($v | group_by([.PkgName, .InstalledVersion, .FixedVersion])
               | map({pkg: (.[0].PkgName | s), inst: (.[0].InstalledVersion | s), fix: ((.[0].FixedVersion // "") | s),
                      sev: (if any(.[]; .Severity == "CRITICAL") then "CRITICAL" else "HIGH" end),
                      cves: (map(.VulnerabilityID | s) | unique)})
               | sort_by([(if .sev == "CRITICAL" then 0 else 1 end), .pkg])
               | map("| `\(.pkg)` | `\(.inst)` | `\(.fix)` | \(.sev) | \(.cves | length): \(.cves[:6] | join(", "))\(if (.cves | length) > 6 then ", ..." else "" end) |")
               | join("\n")) + "\n" end)' \
      "$scans/$id.json" > "$out/details/$id.md"
  done

  # the index
  {
    echo "# Vulnerability report of the published images"
    echo
    echo "Scanned **$date** (UTC) by [\`scan-releases.yaml\`](https://github.com/$repo/blob/main/.github/workflows/scan-releases.yaml), every day,"
    echo "for every release image that is still in the registry. Trivy counts the **fixable HIGH and CRITICAL** vulnerabilities of the **Debian"
    echo "packages**. The libraries compiled into the STK binary (bullet, enet, mcpp, ...) and the game data are not covered."
    echo
    echo "## Which image do I run?"
    echo
    echo "Find your release in the table. If you use \`:1.5\` or \`:latest\`, that is the **newest** release at the time you pulled. To see the"
    echo "digest of the image you run:"
    echo
    echo '```sh'
    echo "docker image inspect $image:1.5 --format '{{index .RepoDigests 0}}'"
    echo '```'
    echo
    echo "## Releases, newest first"
    echo
    echo "| Release | Platform | Critical | High | Image digest | Details |"
    echo "|---|---|---|---|---|---|"
    for i in $(jq -r 'to_entries | sort_by([(.value.tags[0] | split(".") | map(tonumber | -.)), .value.platform]) | .[].key' "$matrix"); do
      id="$(jq -r ".[$i].id" "$matrix")"
      jq -r --slurpfile m "$matrix" --argjson i "$i" --arg id "$id" "$JQ_LABEL"'
        ($m[0][$i]) as $e
        | ([.Results[]?.Vulnerabilities[]?]) as $v
        | "| \($e.tags | rels) | \($e.platform) | \($v | map(select(.Severity == "CRITICAL")) | length) | \($v | map(select(.Severity == "HIGH")) | length) | `\($e.digest[:19])…` | [details](details/\($id).md) |"' \
        "$scans/$id.json"
    done
  } > "$out/README.md"

  # the block for the notes of each release
  local tag
  for tag in $(jq -r '[.[].tags[]] | unique | .[]' "$matrix"); do
    {
      echo "$START"
      echo "### Vulnerabilities, scanned $date"
      echo
      echo "| Platform | Critical | High | Details |"
      echo "|---|---|---|---|"
      for i in $(jq -r --arg t "$tag" 'to_entries | map(select(.value.tags | index($t))) | .[].key' "$matrix"); do
        id="$(jq -r ".[$i].id" "$matrix")"
        jq -r --slurpfile m "$matrix" --argjson i "$i" --arg id "$id" --arg url "$branch_url" '
          ($m[0][$i]) as $e
          | ([.Results[]?.Vulnerabilities[]?]) as $v
          | "| \($e.platform) | \($v | map(select(.Severity == "CRITICAL")) | length) | \($v | map(select(.Severity == "HIGH")) | length) | [details](\($url)/details/\($id).md) |"' \
          "$scans/$id.json"
      done
      echo
      echo "Fixable HIGH and CRITICAL vulnerabilities of the Debian packages, rescanned every day; the numbers above are from the date given. [All releases]($branch_url/README.md)."
      echo "$END"
    } > "$out/release-blocks/$tag.md"
  done
}

case "${1:-}" in
  build) shift; build "$@" ;;
  merge) shift; merge "$@" ;;
  *) echo "usage: scan-report.sh build MATRIX_JSON SCAN_DIR OUT_DIR [DATE] | merge BLOCK_FILE" >&2; exit 2 ;;
esac
