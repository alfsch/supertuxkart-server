#!/usr/bin/env bash
# Offline test of release-images.sh (the grouping) and scan-report.sh (the report and the release notes block), with made-up
# data: no registry, no Trivy. Run by test.yaml in every pull request, and by hand.
# shellcheck disable=SC2015,SC2016  # the patterns are single-quoted on purpose, and A && B || fail is the intended shape
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# --- release-images.sh group
got="$(printf '%s\n' \
  '1.5.1 amd64 sha256:aaaaaaaaaaaa11' '1.5.0 amd64 sha256:aaaaaaaaaaaa11' '1.5.0 arm64 sha256:bbbbbbbbbbbb22' '1.5.1 arm64 sha256:bbbbbbbbbbbb22' \
  '1.5.10 amd64 sha256:cccccccccccc33' '1.5.2 amd64 sha256:dddddddddddd44' | ./release-images.sh group)"
[ "$(jq length <<<"$got")" = 4 ] || fail "four images expected: $got"
[ "$(jq -c '.[0].tags' <<<"$got")" = '["1.5.0","1.5.1"]' ] || fail "tags of the first image: $got"
[ "$(jq -r '.[0].id' <<<"$got")" = amd64-aaaaaaaaaaaa ] || fail "id: $got"
[ "$(jq -r '[.[].tags[0]] | join(" ")' <<<"$got")" = "1.5.0 1.5.0 1.5.2 1.5.10" ] || fail "order (1.5.10 after 1.5.2): $got"
ok "release images are grouped by digest and ordered by release number"

# --- scan-report.sh build
matrix="$tmp/matrix.json"
cat > "$matrix" <<'JSON'
[{"platform":"linux/amd64","digest":"sha256:aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111","tags":["1.5.0","1.5.1"],"id":"amd64-aaaaaaaaaaaa"},
 {"platform":"linux/arm64","digest":"sha256:bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222","tags":["1.5.0","1.5.1"],"id":"arm64-bbbbbbbbbbbb"},
 {"platform":"linux/amd64","digest":"sha256:cccccccccccc3333333333333333333333333333333333333333333333333333","tags":["1.5.2"],"id":"amd64-cccccccccccc"}]
JSON
mkdir "$tmp/scans"
vuln='{"Results":[{"Vulnerabilities":[
 {"VulnerabilityID":"CVE-1","PkgName":"libfoo","InstalledVersion":"1.0","FixedVersion":"1.1","Severity":"HIGH"},
 {"VulnerabilityID":"CVE-2","PkgName":"libfoo","InstalledVersion":"1.0","FixedVersion":"1.1","Severity":"CRITICAL"},
 {"VulnerabilityID":"CVE-3|<b>x</b>","PkgName":"lib`bar","InstalledVersion":"2","FixedVersion":"3","Severity":"HIGH"}]}]}'
echo "$vuln" > "$tmp/scans/amd64-aaaaaaaaaaaa.json"
echo "$vuln" > "$tmp/scans/arm64-bbbbbbbbbbbb.json"
echo '{"Results":[]}' > "$tmp/scans/amd64-cccccccccccc.json"
./scan-report.sh build "$matrix" "$tmp/scans" "$tmp/out" 2026-01-02
readme="$tmp/out/README.md"
grep -q '^| 1.5.2 | linux/amd64 | 0 | 0 |' "$readme" || fail "clean release row: $(cat "$readme")"
grep -q '^| 1.5.0 to 1.5.1 | linux/amd64 | 1 | 2 |' "$readme" || fail "shared image row: $(cat "$readme")"
[ "$(grep -n '^| 1.5.2 ' "$readme" | cut -d: -f1)" -lt "$(grep -n '^| 1.5.0 to' "$readme" | head -1 | cut -d: -f1)" ] || fail "newest release first"
ok "the index has one row per release image, newest first, with the counts"
d="$tmp/out/details/amd64-aaaaaaaaaaaa.md"
grep -q '^| `libfoo` | `1.0` | `1.1` | CRITICAL | 2: CVE-1, CVE-2 |' "$d" || fail "details row: $(cat "$d")"
grep -q 'No findings' "$tmp/out/details/amd64-cccccccccccc.md" || fail "clean details"
ok "a details page groups the CVEs by package and takes the worst severity"
! grep -qE '<b>|lib`bar' "$d" || fail "unsafe characters in the details: $(cat "$d")"
grep -q 'lib bar' "$d" || fail "sanitised package name missing"
ok "text from the vulnerability database cannot break the Markdown"
for t in 1.5.0 1.5.1 1.5.2; do [ -s "$tmp/out/release-blocks/$t.md" ] || fail "no block for $t"; done
grep -q 'linux/arm64 | 1 | 2' "$tmp/out/release-blocks/1.5.1.md" || fail "block of 1.5.1 has both platforms"
ok "every release gets a block"

# --- a missing or broken scan result fails
rm "$tmp/scans/arm64-bbbbbbbbbbbb.json"
if ./scan-report.sh build "$matrix" "$tmp/scans" "$tmp/out2" 2026-01-02 2>/dev/null; then fail "a missing scan result must fail"; fi
echo '{}' > "$tmp/scans/arm64-bbbbbbbbbbbb.json"
if ./scan-report.sh build "$matrix" "$tmp/scans" "$tmp/out2" 2026-01-02 2>/dev/null; then fail "a result that is not a Trivy report must fail"; fi
ok "a missing or invalid scan result fails instead of showing as clean"

# --- scan-report.sh merge
block="$tmp/out/release-blocks/1.5.2.md"
new="$(printf 'Notes\n\nmore\n' | ./scan-report.sh merge "$block")"
grep -q 'vulnerabilities:start' <<<"$new" && grep -q '^Notes$' <<<"$new" || fail "appended: $new"
old="$(printf 'Notes\n<!-- vulnerabilities:start -->\nOLD\n<!-- vulnerabilities:end -->\nTail\n')"
new="$(./scan-report.sh merge "$block" <<<"$old")"
! grep -q OLD <<<"$new" || fail "old block still there: $new"
grep -q '^Tail$' <<<"$new" && grep -q '^Notes$' <<<"$new" && [ "$(grep -c 'vulnerabilities:start' <<<"$new")" = 1 ] || fail "replaced: $new"
again="$(./scan-report.sh merge "$block" <<<"$new")"
[ "$again" = "$new" ] || fail "merging twice changes the notes"
ok "the block is appended once, replaced after that, and merging is idempotent"
echo "all passed"
