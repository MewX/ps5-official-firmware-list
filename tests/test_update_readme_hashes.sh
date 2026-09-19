#!/bin/bash
# End to end tests for update_readme_hashes.sh.
#
# The script's three inputs - the updatelist, the support page and the
# firmware images - are all fetched with curl, so the tests point them at
# file:// fixtures built in a temp directory. That exercises the real download,
# hashing, verification and README editing code paths in a few milliseconds,
# without any network access and without downloading 2GB of firmware.
set -uo pipefail

# shellcheck source=tests/lib/assert.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# shellcheck source=lib/ps5fw.sh
source "$REPO_ROOT/lib/ps5fw.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

sha_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
md5_of() { printf '%s' "$1" | md5sum | awk '{print $1}'; }
size_of() { printf '%s' "$1" | wc -c | tr -d ' '; }

# Lay out a fake firmware image the way Sony does: the directory is named
# after the sha256 of the file it contains. Prints the resulting URL.
publish_image() {
  local root="$1" build_date="$2" kind="$3" content="$4" dir_hash="${5:-}"
  local dir
  [[ -n "$dir_hash" ]] || dir_hash="$(sha_of "$content")"
  dir="$root/update/ps5/official/OBFUSCATED/image/$build_date/${kind}_${dir_hash}"
  mkdir -p "$dir"
  printf '%s' "$content" > "$dir/PS5UPDATE.PUP"
  echo "file://$dir/PS5UPDATE.PUP"
}

write_updatelist() {
  local path="$1" label="$2" upd_version="$3" url="$4" size="$5"
  cat > "$path" <<EOF
<?xml version="1.0" ?>
<update_data_list>
	<region id="us">
		<system_pup auto_update_version="00.00" label="$label" sdk_version="$label" upd_version="$upd_version">
			<update_data update_type="full">
				<image size="$size">$url</image>
			</update_data>
		</system_pup>
	</region>
</update_data_list>
EOF
}

write_support_page() {
  local path="$1"
  shift
  {
    echo "<html><body>"
    for url in "$@"; do
      echo "<a href=\"$url\">download</a>"
    done
    echo "</body></html>"
  } > "$path"
}

# Run update_readme_hashes.sh against a case directory. Sets RUN_STATUS,
# RUN_OUTPUT, RUN_README, RUN_SUMMARY and RUN_OUTPUTS.
run_updater() {
  local case_dir="$1" updatelist="$2" support="$3"
  RUN_README="$case_dir/README.md"
  RUN_SUMMARY="$case_dir/summary.md"
  RUN_OUTPUTS="$case_dir/outputs.txt"
  : > "$RUN_OUTPUTS"
  RUN_OUTPUT="$(
    PS5FW_UPDATELIST_URL="$updatelist" \
    PS5FW_SUPPORT_URL="$support" \
    PS5FW_README="$RUN_README" \
    PS5FW_SUMMARY_FILE="$RUN_SUMMARY" \
    PS5FW_CURL_RETRY=0 \
    PS5FW_CURL_RETRY_DELAY=0 \
    GITHUB_OUTPUT="$RUN_OUTPUTS" \
    bash "$REPO_ROOT/update_readme_hashes.sh" 2>&1
  )" && RUN_STATUS=0 || RUN_STATUS=$?
}

output_value() {
  grep -m 1 "^$1=" "$RUN_OUTPUTS" | cut -d= -f2-
}

# Every case starts from a copy of the real README.md.
new_case() {
  local name="$1"
  local dir="$workdir/$name"
  mkdir -p "$dir"
  cp "$REPO_ROOT/README.md" "$dir/README.md"
  echo "$dir"
}

echo "== a new major version"

case_dir="$(new_case major-bump)"
sys_content="fake PS5 15.00.00 update image"
rec_content="fake PS5 15.00.00 recovery image"
sys_url="$(publish_image "$case_dir" 2027_0210 sys "$sys_content")"
rec_url="$(publish_image "$case_dir" 2027_0210 rec "$rec_content")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
write_support_page "$case_dir/support.html" "$sys_url" "$rec_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it reports that the README changed"
assert_eq "true" "$(output_value changed)"

it "it reports the new version"
assert_eq "15.00.00" "$(output_value version)"

it "it reports the build date"
assert_eq "2027_0210" "$(output_value build_date)"

it "it reports that a new section was created"
assert_eq "true" "$(output_value new_section)"

it "a 15.x section was added"
assert_ok "15.x section" ps5fw_readme_has_section "$RUN_README" 15

it "15.x is now the newest section"
assert_eq "### 15.x" "$(grep -m 1 '^### ' "$RUN_README" | tr -d '\r')"

it "14.x is still right below it"
assert_eq "### 14.x" "$(grep '^### ' "$RUN_README" | sed -n 2p | tr -d '\r')"

it "the update row carries the real sha256 of the downloaded image"
assert_file_contains "$RUN_README" "$(sha_of "$sys_content")"

it "the update row carries the real md5 of the downloaded image"
assert_file_contains "$RUN_README" "$(md5_of "$sys_content")"

it "the recovery row carries the real sha256 of the downloaded image"
assert_file_contains "$RUN_README" "$(sha_of "$rec_content")"

it "the recovery row carries the real md5 of the downloaded image"
assert_file_contains "$RUN_README" "$(md5_of "$rec_content")"

it "the rows are formatted the same way as the rest of the table"
assert_file_contains "$RUN_README" \
  "$(ps5fw_format_row "27.01-15.00.00.10-00.00.00.0.1" 15.00.00 sys 2027_0210 \
    "$(sha_of "$sys_content")" "$(md5_of "$sys_content")" "$(size_of "$sys_content")")"

it "the update row comes before the recovery row"
assert_eq "$(sha_of "$sys_content")
$(sha_of "$rec_content")" \
  "$(grep -oE '[a-f0-9]{64}' "$RUN_README" | head -2)"

it "the README keeps its CRLF line endings"
assert_eq "0" "$(grep -cv $'\r$' "$RUN_README" || true)"

it "nothing outside the new section changed"
assert_eq "6" "$(diff <(tr -d '\r' < "$REPO_ROOT/README.md") <(tr -d '\r' < "$RUN_README") | grep -c '^>')"

it "the summary names the firmware"
assert_file_contains "$RUN_SUMMARY" "27.01-15.00.00.10-00.00.00.0.1"

it "the summary calls out the new section"
assert_file_contains "$RUN_SUMMARY" "new \`### 15.x\` section"

it "no firmware image is left on disk"
assert_eq "0" "$(find "$case_dir" -name 'sys_PS5UPDATE.PUP' -o -name 'rec_PS5UPDATE.PUP' | wc -l | tr -d ' ')"

echo ""
echo "== running again changes nothing"

before="$(md5sum < "$RUN_README")"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the second run succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it reports no change"
assert_eq "false" "$(output_value changed)"

it "the README is byte for byte identical"
assert_eq "$before" "$(md5sum < "$RUN_README")"

it "it says why there was nothing to do"
assert_contains "$RUN_OUTPUT" "already lists"

echo ""
echo "== a minor release joins the existing section"

case_dir="$(new_case minor-release)"
sys_content="fake PS5 14.20.00 update image"
rec_content="fake PS5 14.20.00 recovery image"
sys_url="$(publish_image "$case_dir" 2026_1021 sys "$sys_content")"
rec_url="$(publish_image "$case_dir" 2026_1021 rec "$rec_content")"
write_updatelist "$case_dir/updatelist.xml" "26.07-14.20.00.01-00.00.00.0.1" "14.20.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
write_support_page "$case_dir/support.html" "$sys_url" "$rec_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "no new section was created"
assert_eq "false" "$(output_value new_section)"

it "the section count is unchanged"
assert_eq "$(grep -c '^### ' "$REPO_ROOT/README.md")" "$(grep -c '^### ' "$RUN_README")"

it "the new rows are at the top of the 14.x table"
assert_eq "$(sha_of "$sys_content")" "$(grep -oE '[a-f0-9]{64}' "$RUN_README" | head -1)"

it "the previous 14.00.00 rows are still below them"
assert_file_contains "$RUN_README" "1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc"

echo ""
echo "== a corrupted download is rejected"

case_dir="$(new_case corrupt)"
sys_content="fake PS5 15.00.00 update image"
# The directory is named after a different checksum than the file it holds,
# which is what a truncated or tampered download looks like.
sys_url="$(publish_image "$case_dir" 2027_0210 sys "totally different bytes" "$(sha_of "$sys_content")")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
write_support_page "$case_dir/support.html" "$sys_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater fails"
if [[ "$RUN_STATUS" -ne 0 ]]; then pass_note; else fail "expected a non-zero exit" "$RUN_OUTPUT"; fi

it "it explains that the checksum did not match"
assert_contains "$RUN_OUTPUT" "but its URL claims"

it "the README was left alone"
assert_eq "$(md5sum < "$REPO_ROOT/README.md")" "$(md5sum < "$RUN_README")"

it "it did not claim a change"
assert_eq "" "$(output_value changed)"

echo ""
echo "== a missing recovery image only blocks the recovery row"

case_dir="$(new_case no-recovery)"
sys_content="fake PS5 15.00.00 update image"
sys_url="$(publish_image "$case_dir" 2027_0210 sys "$sys_content")"
# The support page still advertises the previous release's recovery image.
stale_rec_url="$(publish_image "$case_dir" 2026_0909 rec "older recovery image")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
write_support_page "$case_dir/support.html" "$sys_url" "$stale_rec_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater still succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it warns about the missing recovery image"
assert_contains "$RUN_OUTPUT" "no recovery image for build 2027_0210"

it "the update row was added"
assert_file_contains "$RUN_README" "$(sha_of "$sys_content")"

it "the stale recovery image was not used"
assert_file_not_contains "$RUN_README" "$(sha_of "older recovery image")"

it "the summary flags the missing recovery row"
assert_file_contains "$RUN_SUMMARY" "still needs to be filled in"

echo ""
echo "== an unreachable support page is not fatal"

case_dir="$(new_case no-support-page)"
sys_content="fake PS5 15.00.00 update image"
sys_url="$(publish_image "$case_dir" 2027_0210 sys "$sys_content")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/definitely-missing.html"

it "the updater still succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it warns that the page could not be fetched"
assert_contains "$RUN_OUTPUT" "could not fetch the support page"

it "the update row was still added"
assert_file_contains "$RUN_README" "$(sha_of "$sys_content")"

echo ""
echo "== a recovery image is backfilled next to its update row"

case_dir="$(new_case backfill)"
sys_content="fake PS5 15.00.00 update image"
rec_content="fake PS5 15.00.00 recovery image"
sys_url="$(publish_image "$case_dir" 2027_0210 sys "$sys_content")"
rec_url="$(publish_image "$case_dir" 2027_0210 rec "$rec_content")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "$(size_of "$sys_content")"
# First run without the recovery link, then again once it shows up.
write_support_page "$case_dir/support.html" "$sys_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"
write_support_page "$case_dir/support.html" "$sys_url" "$rec_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the backfill run succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it reports a change"
assert_eq "true" "$(output_value changed)"

it "it says it is backfilling"
assert_contains "$RUN_OUTPUT" "Backfilling the recovery row"

it "the recovery row sits directly below the update row"
assert_eq "$(sha_of "$rec_content")" \
  "$(grep -A 1 -F "$(sha_of "$sys_content")" "$RUN_README" | tail -1 | grep -oE '[a-f0-9]{64}')"

it "no second 15.x section was created"
assert_eq "1" "$(grep -c '^### 15\.x' "$RUN_README")"

echo ""
echo "== a size mismatch warns but does not block"

case_dir="$(new_case size-mismatch)"
sys_content="fake PS5 15.00.00 update image"
sys_url="$(publish_image "$case_dir" 2027_0210 sys "$sys_content")"
write_updatelist "$case_dir/updatelist.xml" "27.01-15.00.00.10-00.00.00.0.1" "15.00.00.00" \
  "$sys_url" "999999999"
write_support_page "$case_dir/support.html" "$sys_url"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater succeeds"
assert_eq "0" "$RUN_STATUS" "$RUN_OUTPUT"

it "it warns about the size difference"
assert_contains "$RUN_OUTPUT" "updatelist.xml says 999999999 B"

it "the row records the real size, not the advertised one"
assert_file_contains "$RUN_README" "| $(size_of "$sys_content") B |"

echo ""
echo "== a broken updatelist stops the run"

case_dir="$(new_case bad-updatelist)"
echo "<html>404</html>" > "$case_dir/updatelist.xml"
write_support_page "$case_dir/support.html"
run_updater "$case_dir" "file://$case_dir/updatelist.xml" "file://$case_dir/support.html"

it "the updater fails"
if [[ "$RUN_STATUS" -ne 0 ]]; then pass_note; else fail "expected a non-zero exit" "$RUN_OUTPUT"; fi

it "the README was left alone"
assert_eq "$(md5sum < "$REPO_ROOT/README.md")" "$(md5sum < "$RUN_README")"

test_summary
