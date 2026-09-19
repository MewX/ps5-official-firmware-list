#!/bin/bash
# Tests for the README editing helpers: adding rows to an existing "### N.x"
# section, and creating a new section when a release bumps the major version.
set -uo pipefail

# shellcheck source=tests/lib/assert.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# shellcheck source=lib/ps5fw.sh
source "$REPO_ROOT/lib/ps5fw.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

HEADER='| Firmware Version (Long)        | Version (Short) | Type     | Build Date      | sha256                                                           | md5 checksum                     | size   |'
SEPARATOR='| ------------------------------ | --------------- | -------- | --------------- | ---------------------------------------------------------------- | -------------------------------- | ------ |'

# A miniature README with the same shape as the real one: an intro, the
# firmware list with two sections, and a trailing heading.
make_readme() {
  local path="$1" eol="${2:-lf}"
  cat > "$path" <<EOF
# PlayStation 5 Official Firmware List

## Update List files
Format: something.

## The Full List

To download the latest firmware, go to: https://example.invalid/.

### 14.x
$HEADER
$SEPARATOR
| 26.06-14.00.00.39-00.00.00.0.1 | 14.00.00        | 🆙 Update   | 2026_0909       | aaaa000000000000000000000000000000000000000000000000000000000001 | 1111111111111111111111111111aaaa | 1260600832 B |
| 26.06-14.00.00.39-00.00.00.0.1 | 14.00.00        | ❤️‍🩹 Recovery | 2026_0909       | aaaa000000000000000000000000000000000000000000000000000000000002 | 2222222222222222222222222222aaaa | 1418082816 B |

### 13.x
$HEADER
$SEPARATOR
| 26.05-13.60.00.07-00.00.00.0.1 | 13.60.00        | 🆙 Update   | 2026_0717       | bbbb000000000000000000000000000000000000000000000000000000000001 | 3333333333333333333333333333bbbb | 1247471104 B |

## Contribution Guide

Send a PR.
EOF
  if [[ "$eol" == "crlf" ]]; then
    sed -i -e 's/$/\r/' "$path"
  fi
}

# Print the body of a "### <major>.x" section, i.e. everything up to the next
# heading.
section_body() {
  local readme="$1" major="$2"
  awk -v want="### $major.x" '
    $0 == want { inside = 1; next }
    inside && /^#/ { exit }
    inside { print }
  ' "$readme"
}

rows_file() {
  local path="$workdir/rows.$RANDOM.md"
  printf '%s\n' "$@" > "$path"
  echo "$path"
}

echo "== section and hash lookups"

readme="$workdir/lookup.md"
make_readme "$readme"

it "an existing section is found"
assert_ok "14.x exists" ps5fw_readme_has_section "$readme" 14

it "a missing section is not found"
assert_not_ok "15.x must not exist" ps5fw_readme_has_section "$readme" 15

it "a section is not matched by a prefix"
assert_not_ok "1.x must not match 14.x" ps5fw_readme_has_section "$readme" 1

it "an existing checksum is found"
assert_ok "checksum lookup" ps5fw_readme_has_hash "$readme" aaaa000000000000000000000000000000000000000000000000000000000001

it "an unknown checksum is not found"
assert_not_ok "unknown checksum" ps5fw_readme_has_hash "$readme" cccc000000000000000000000000000000000000000000000000000000000009

it "the table header is read out of the README"
assert_eq "$HEADER" "$(ps5fw_table_header "$readme")"

it "the table separator is read out of the README"
assert_eq "$SEPARATOR" "$(ps5fw_table_separator "$readme")"

it "an unrelated markdown table does not hijack the separator lookup"
decoy="$workdir/decoy.md"
make_readme "$decoy"
cat >> "$decoy" <<'EOF'

## Automation

| Workflow | Trigger |
| -------- | ------- |
| tests    | push    |
EOF
assert_eq "$SEPARATOR" "$(ps5fw_table_separator "$decoy")"

it "an unrelated markdown table does not hijack the header lookup"
assert_eq "$HEADER" "$(ps5fw_table_header "$decoy")"

it "a README without a table falls back to the built in header"
empty="$workdir/empty.md"
echo "# nothing here" > "$empty"
assert_eq "$PS5FW_FALLBACK_TABLE_HEADER" "$(ps5fw_table_header "$empty")"

it "a README without a table falls back to the built in separator"
assert_eq "$PS5FW_FALLBACK_TABLE_SEPARATOR" "$(ps5fw_table_separator "$empty")"

echo ""
echo "== adding rows to an existing section"

readme="$workdir/existing.md"
make_readme "$readme"
new_row="$(ps5fw_format_row 26.07-14.20.00.01-00.00.00.0.1 14.20.00 sys 2026_1021 \
  dddd000000000000000000000000000000000000000000000000000000000001 4444444444444444444444444444dddd 1270000000)"
rows="$(rows_file "$new_row")"

it "inserting into an existing section succeeds"
assert_ok "insert 14.20.00" ps5fw_readme_insert_rows "$readme" 14 "$rows"

it "the row lands directly under the 14.x table header, because rows are newest first"
assert_eq "$new_row" "$(awk '/^### 14\.x/{f=1} f && /^\| -+ \|/{getline; print; exit}' "$readme")"

it "no new section was created"
assert_eq "2" "$(grep -c '^### ' "$readme")"

it "the existing rows are still there"
assert_file_contains "$readme" "aaaa000000000000000000000000000000000000000000000000000000000001"

it "the 13.x section still has exactly its original row"
assert_eq "| 26.05-13.60.00.07-00.00.00.0.1 | 13.60.00        | 🆙 Update   | 2026_0717       | bbbb000000000000000000000000000000000000000000000000000000000001 | 3333333333333333333333333333bbbb | 1247471104 B |" \
  "$(section_body "$readme" 13 | grep '^| 2')"

it "the new row went into 14.x"
assert_eq "1" "$(section_body "$readme" 14 | grep -c 'dddd0000')"

it "the new row did not leak into 13.x"
assert_eq "0" "$(section_body "$readme" 13 | grep -c 'dddd0000' || true)"

it "an empty set of rows is rejected"
empty_rows="$workdir/empty-rows.md"
: > "$empty_rows"
assert_not_ok "empty rows must be rejected" ps5fw_readme_insert_rows "$readme" 14 "$empty_rows"

echo ""
echo "== a major version bump creates a new section"

readme="$workdir/newmajor.md"
make_readme "$readme"
sys_row="$(ps5fw_format_row 27.01-15.00.00.10-00.00.00.0.1 15.00.00 sys 2027_0210 \
  eeee000000000000000000000000000000000000000000000000000000000001 5555555555555555555555555555eeee 1300000000)"
rec_row="$(ps5fw_format_row 27.01-15.00.00.10-00.00.00.0.1 15.00.00 rec 2027_0210 \
  eeee000000000000000000000000000000000000000000000000000000000002 6666666666666666666666666666eeee 1450000000)"
rows="$(rows_file "$sys_row" "$rec_row")"

it "inserting a brand new major version succeeds"
assert_ok "insert 15.x" ps5fw_readme_insert_rows "$readme" 15 "$rows"

it "a 15.x section now exists"
assert_ok "15.x exists" ps5fw_readme_has_section "$readme" 15

it "the new section is the first one in the list"
assert_eq "### 15.x" "$(grep -m 1 '^### ' "$readme")"

it "the sections stay in descending order"
assert_eq "### 15.x
### 14.x
### 13.x" "$(grep '^### ' "$readme")"

it "the new section carries the table header"
assert_eq "$HEADER" "$(grep -A 1 '^### 15\.x' "$readme" | tail -1)"

it "the new section carries the table separator"
assert_eq "$SEPARATOR" "$(grep -A 2 '^### 15\.x' "$readme" | tail -1)"

it "both rows are in the new section, update first"
assert_eq "$sys_row
$rec_row" "$(grep -A 4 '^### 15\.x' "$readme" | tail -2)"

it "the new section is separated from the next one by a blank line"
assert_eq "" "$(grep -A 5 '^### 15\.x' "$readme" | tail -1)"

it "the 14.x section is still intact"
assert_file_contains "$readme" "aaaa000000000000000000000000000000000000000000000000000000000002"

echo ""
echo "== a new section older than everything else goes last"

readme="$workdir/oldmajor.md"
make_readme "$readme"
old_row="$(ps5fw_format_row 22.01-05.00.00.01-00.00.00.0.0 05.00.00 sys 2022_0101 \
  ffff000000000000000000000000000000000000000000000000000000000001 7777777777777777777777777777ffff 1000000000)"
rows="$(rows_file "$old_row")"

it "inserting an older major version succeeds"
assert_ok "insert 05.x" ps5fw_readme_insert_rows "$readme" 05 "$rows"

it "it is appended after the existing sections"
assert_eq "### 14.x
### 13.x
### 05.x" "$(grep '^### ' "$readme")"

it "it stays inside The Full List, ahead of the next heading"
assert_eq "### 05.x" "$(awk '/^## Contribution Guide/{exit} /^### /{last=$0} END{print last}' "$readme")"

it "the zero padded major is used for the heading"
assert_file_contains "$readme" "### 05.x"

echo ""
echo "== a README whose firmware list runs to the end of the file"

readme="$workdir/nofooter.md"
make_readme "$readme"
python3 - "$readme" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
open(path, 'w', encoding='utf-8').write(text.split('## Contribution Guide')[0].rstrip('\n') + '\n')
PY
rows="$(rows_file "$old_row")"

it "a trailing section is appended at the end of the file"
assert_ok "insert 05.x at EOF" ps5fw_readme_insert_rows "$readme" 05 "$rows"

it "the section really is last"
assert_eq "### 05.x" "$(grep '^### ' "$readme" | tail -1)"

it "its row made it into the file"
assert_file_contains "$readme" "ffff000000000000000000000000000000000000000000000000000000000001"

echo ""
echo "== backfilling a recovery row next to its update row"

readme="$workdir/backfill.md"
make_readme "$readme"
backfill_row="$(ps5fw_format_row 26.05-13.60.00.07-00.00.00.0.1 13.60.00 rec 2026_0717 \
  bbbb000000000000000000000000000000000000000000000000000000000002 8888888888888888888888888888bbbb 1404953088)"
rows="$(rows_file "$backfill_row")"

it "the recovery row is inserted after the matching update row"
assert_ok "backfill 13.60.00 recovery" \
  ps5fw_readme_insert_after_hash "$readme" bbbb000000000000000000000000000000000000000000000000000000000001 "$rows"

it "it sits immediately below its update row"
assert_eq "$backfill_row" \
  "$(grep -A 1 -F 'bbbb000000000000000000000000000000000000000000000000000000000001' "$readme" | tail -1)"

it "it did not jump to the top of the table"
assert_not_contains "$(grep -A 3 '^### 13\.x' "$readme" | sed -n '3p')" "8888888888888888888888888888bbbb"

it "backfilling against an unknown checksum fails loudly"
assert_not_ok "unknown anchor must fail" \
  ps5fw_readme_insert_after_hash "$readme" 0000000000000000000000000000000000000000000000000000000000009999 "$rows"

echo ""
echo "== CRLF line endings are preserved"

readme="$workdir/crlf.md"
make_readme "$readme" crlf
rows="$(rows_file "$sys_row" "$rec_row")"

it "inserting into a CRLF README succeeds"
assert_ok "insert into CRLF README" ps5fw_readme_insert_rows "$readme" 15 "$rows"

it "every line still ends with CRLF"
assert_eq "0" "$(grep -cv $'\r$' "$readme" || true)"

it "no row picked up a doubled carriage return"
assert_eq "0" "$(grep -c $'\r\r' "$readme" || true)"

it "the inserted rows are present"
assert_file_contains "$readme" "eeee000000000000000000000000000000000000000000000000000000000002"

it "backfilling into a CRLF README keeps CRLF"
readme="$workdir/crlf-backfill.md"
make_readme "$readme" crlf
rows="$(rows_file "$backfill_row")"
ps5fw_readme_insert_after_hash "$readme" bbbb000000000000000000000000000000000000000000000000000000000001 "$rows"
assert_eq "0" "$(grep -cv $'\r$' "$readme" || true)"

it "an LF README stays LF"
readme="$workdir/lf.md"
make_readme "$readme"
rows="$(rows_file "$sys_row")"
ps5fw_readme_insert_rows "$readme" 15 "$rows"
assert_eq "0" "$(grep -c $'\r' "$readme" || true)"

test_summary
