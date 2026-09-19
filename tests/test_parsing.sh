#!/bin/bash
# Parsing tests for lib/ps5fw.sh, run against the updatelist.xml files that are
# already committed to this repository. Every one of them corresponds to a row
# that is already in README.md, so these double as a regression test that the
# parser and the row formatter still agree with the real data.
set -uo pipefail

# shellcheck source=tests/lib/assert.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# shellcheck source=lib/ps5fw.sh
source "$REPO_ROOT/lib/ps5fw.sh"

echo "== version helpers"

it "short version drops the fourth component"
assert_eq "14.00.00" "$(ps5fw_short_version 14.00.00.00)"

it "short version of a padded release"
assert_eq "09.60.00" "$(ps5fw_short_version 09.60.00.00)"

it "major version keeps the zero padding used by the section headers"
assert_eq "09" "$(ps5fw_major_version 09.60.00)"

it "major version of a two digit release"
assert_eq "14" "$(ps5fw_major_version 14.00.00)"

echo ""
echo "== URL helpers"

sys_url='http://dus01.ps5.update.playstation.net/update/ps5/official/tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/image/2026_0909/sys_1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc/PS5UPDATE.PUP?dest=us'
rec_url='http://dus01.ps5.update.playstation.net/update/ps5/official/tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/image/2026_0909/rec_7ec8dd8a6f518370422844d2c9d670316774d3dc9d52d78a676a3452ff63c556/PS5UPDATE.PUP'

it "build date comes from the path segment after /image/"
assert_eq "2026_0909" "$(ps5fw_url_build_date "$sys_url")"

it "sha256 comes from the sys_ path segment"
assert_eq "1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc" "$(ps5fw_url_sha256 "$sys_url")"

it "sha256 comes from the rec_ path segment"
assert_eq "7ec8dd8a6f518370422844d2c9d670316774d3dc9d52d78a676a3452ff63c556" "$(ps5fw_url_sha256 "$rec_url")"

it "an update URL is recognised as sys"
assert_eq "sys" "$(ps5fw_url_kind "$sys_url")"

it "a recovery URL is recognised as rec"
assert_eq "rec" "$(ps5fw_url_kind "$rec_url")"

it "a query string does not leak into the build date"
assert_eq "2026_0909" "$(ps5fw_url_build_date "$sys_url")"

echo ""
echo "== support page scraping"

page="$REPO_ROOT/tests/fixtures/support_page.html"

it "every PUP link on the page is found"
assert_eq "4" "$(ps5fw_extract_pup_urls "$page" | wc -l | tr -d ' ')"

it "duplicate links are collapsed"
assert_eq "1" "$(ps5fw_extract_pup_urls "$page" | grep -c 'rec_7ec8dd8a6f518370422844d2c9d670316774d3dc9d52d78a676a3452ff63c556')"

it "the recovery image for the requested build is returned"
assert_eq "$rec_url" "$(ps5fw_find_recovery_url "$page" 2026_0909)"

it "a recovery image from an older build is not returned for a newer build"
assert_not_contains "$(ps5fw_find_recovery_url "$page" 2026_0909)" "2026_0717"

it "an unknown build date yields no recovery image"
assert_not_ok "unknown build date must fail" ps5fw_find_recovery_url "$page" 2099_0101

echo ""
echo "== updatelist.xml parsing"

it "parsing a malformed updatelist fails instead of emitting empty values"
not_xml="$(mktemp)"
echo "this is not an updatelist" > "$not_xml"
assert_not_ok "malformed updatelist must fail" ps5fw_parse_updatelist "$not_xml"
rm -f "$not_xml"

it "parsing a missing updatelist fails"
assert_not_ok "missing updatelist must fail" ps5fw_parse_updatelist "$REPO_ROOT/tests/fixtures/does-not-exist.xml"

# The caller evals ps5fw_parse_updatelist's output, and the updatelist it
# parses comes off the network, so the values have to survive the round trip
# as literals.
echo ""
echo "== parsed values are safe to eval"

evil="$(mktemp)"
canary="$(mktemp -u)"
cat > "$evil" <<EOF
<?xml version="1.0" ?>
<update_data_list><region id="us">
<system_pup auto_update_version="00.00" label="27.01-15.00.00.10\$(touch $canary)-\`touch $canary\`; touch $canary" sdk_version="x" upd_version="15.00.00.00">
<update_data update_type="full"><image size="1">http://example.invalid/update/ps5/official/OBF/image/2027_0210/sys_0000000000000000000000000000000000000000000000000000000000000001/PS5UPDATE.PUP</image></update_data>
</system_pup></region></update_data_list>
EOF

label="" upd_version=""
metadata="$(ps5fw_parse_updatelist "$evil")"
eval "$metadata"

it "a label full of shell metacharacters does not execute anything"
if [[ -e "$canary" ]]; then
  fail "eval of the parsed metadata ran a command from the updatelist"
else
  pass_note
fi

it "the label survives eval as a literal string"
# The single quotes are the point: $(...) and `...` must stay literal text.
# shellcheck disable=SC2016
assert_eq '27.01-15.00.00.10$(touch '"$canary"')-`touch '"$canary"'`; touch '"$canary" "$label"

it "the rest of the metadata is still parsed"
assert_eq "15.00.00" "$upd_version"

rm -f "$evil" "$canary"

# Round trip every committed updatelist against README.md. The file name
# encodes the build date and the short version, and the README must already
# carry a row that ps5fw_format_row reproduces byte for byte.
for xml in "$REPO_ROOT"/updatelists/updatelist.*.xml; do
  name="$(basename "$xml")"
  [[ "$name" == "updatelist.latest.xml" ]] && continue

  # updatelist.<build_date>.<short_version>.xml
  expected_build_date="$(echo "$name" | cut -d. -f2)"
  expected_version="$(echo "$name" | cut -d. -f3-5)"

  label="" upd_version_full="" upd_version="" major_version=""
  build_date="" sys_url="" sys_size="" sys_sha256=""
  metadata="$(ps5fw_parse_updatelist "$xml")" || {
    it "$name parses"
    fail "ps5fw_parse_updatelist failed"
    continue
  }
  eval "$metadata"

  it "$name: build date matches the file name"
  assert_eq "$expected_build_date" "$build_date"

  it "$name: short version matches the file name"
  assert_eq "$expected_version" "$upd_version"

  it "$name: the short version is a prefix of the full upd_version"
  assert_eq "$upd_version" "${upd_version_full%.*}"

  it "$name: the major version matches the README section it belongs to"
  assert_ok "section ### $major_version.x must exist" \
    ps5fw_readme_has_section "$REPO_ROOT/README.md" "$major_version"

  it "$name: the update sha256 is already in README.md"
  assert_ok "sha256 $sys_sha256 must be in the README" \
    ps5fw_readme_has_hash "$REPO_ROOT/README.md" "$sys_sha256"

  readme_row="$(grep -F "$sys_sha256" "$REPO_ROOT/README.md" | head -n 1)"
  readme_row="${readme_row%$'\r'}"
  readme_md5="$(echo "$readme_row" | awk -F'|' '{gsub(/ /, "", $7); print $7}')"

  it "$name: ps5fw_format_row reproduces the README row exactly"
  assert_eq "$readme_row" \
    "$(ps5fw_format_row "$label" "$upd_version" sys "$build_date" "$sys_sha256" "$readme_md5" "$sys_size")"
done

echo ""
echo "== row formatting against every generated README row"

# Re-render every README row that was produced by the current template (byte
# sizes, no uncertain "?" markers) and require an exact match. This is what
# catches a change in the column padding.
rendered=0
while IFS= read -r row; do
  row="${row%$'\r'}"
  label="$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $2); print $2}')"
  version="$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}')"
  type_cell="$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $4); print $4}')"
  build="$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $5); print $5}')"
  sha="$(echo "$row" | awk -F'|' '{gsub(/ /, "", $6); print $6}')"
  md5="$(echo "$row" | awk -F'|' '{gsub(/ /, "", $7); print $7}')"
  size="$(echo "$row" | awk -F'|' '{gsub(/[^0-9]/, "", $8); print $8}')"

  case "$type_cell" in
    "🆙 Update") kind=sys ;;
    "❤️‍🩹 Recovery") kind=rec ;;
    *) continue ;;
  esac

  it "README row for $label / $type_cell round trips"
  assert_eq "$row" "$(ps5fw_format_row "$label" "$version" "$kind" "$build" "$sha" "$md5" "$size")"
  rendered=$((rendered + 1))
done < <(grep -E '^\| [0-9]{2}\.[0-9]{2}-[0-9.]+-[0-9.]+ \|' "$REPO_ROOT/README.md" |
  grep -E '\| [0-9]+ B \|[[:space:]]*$')

it "a meaningful number of README rows were round tripped"
if [[ $rendered -ge 20 ]]; then
  pass_note
else
  fail "only $rendered rows were checked, expected at least 20"
fi

test_summary
