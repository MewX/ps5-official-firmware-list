#!/bin/bash
# Shared helpers for parsing PS5 update metadata and editing the README table.
#
# This file only defines functions, so it is safe to source from scripts and
# from the tests under tests/. Everything here is pure text processing: no
# network access and no downloads, which keeps it cheap to unit test.

# --- updatelist.xml parsing -------------------------------------------------

# Print the first <system_pup ...> element of an updatelist.xml.
ps5fw_system_pup_line() {
  grep -o '<system_pup[^>]*>' "$1" | head -n 1
}

# Print the first <image ...>URL</image> element of an updatelist.xml.
ps5fw_image_line() {
  grep -o '<image[^>]*>[^<]*</image>' "$1" | head -n 1
}

# Read the value of an XML attribute out of a single element string on stdin.
# Usage: echo '<image size="42">' | ps5fw_attr size
ps5fw_attr() {
  grep -o "$1=\"[^\"]*\"" | head -n 1 | sed "s/^$1=\"//;s/\"$//"
}

# Trim the four-part upd_version down to the three-part short version used by
# the README, e.g. 14.00.00.00 -> 14.00.00.
ps5fw_short_version() {
  echo "$1" | awk -F. '{print $1"."$2"."$3}'
}

# Major version of a short version, keeping the zero padding used by the
# README section headers, e.g. 14.00.00 -> 14 and 09.60.00 -> 09.
ps5fw_major_version() {
  echo "${1%%.*}"
}

# The build date segment of a firmware URL, e.g. .../image/2026_0909/sys_...
ps5fw_url_build_date() {
  echo "$1" | awk -F/ '{for (i = 1; i <= NF; i++) if ($i == "image") {print $(i + 1); exit}}'
}

# The sha256 embedded in the sys_/rec_ segment of a firmware URL. Sony names
# the directory after the checksum of the PUP, so this is what a download is
# verified against.
ps5fw_url_sha256() {
  echo "$1" | grep -oE '/(sys|rec)_[a-fA-F0-9]{64}/' | head -n 1 | grep -oE '[a-fA-F0-9]{64}'
}

# "sys" (update image) or "rec" (recovery image) for a firmware URL.
ps5fw_url_kind() {
  echo "$1" | grep -oE '/(sys|rec)_[a-fA-F0-9]{64}/' | head -n 1 | sed 's|^/||;s|_.*$||'
}

# Parse an updatelist.xml into shell variable assignments. The caller is
# expected to eval the output:
#
#   eval "$(ps5fw_parse_updatelist updatelist.xml)"
#
# Sets label, upd_version_full, upd_version, major_version, build_date,
# sys_url, sys_size and sys_sha256. Fails if the file is not a parseable
# updatelist.
ps5fw_parse_updatelist() {
  local xml="$1"
  local pup image label upd_full upd_short major url size sha date

  if [[ ! -s "$xml" ]]; then
    echo "ps5fw: updatelist '$xml' is missing or empty" >&2
    return 1
  fi

  pup="$(ps5fw_system_pup_line "$xml")"
  image="$(ps5fw_image_line "$xml")"
  if [[ -z "$pup" || -z "$image" ]]; then
    echo "ps5fw: '$xml' has no <system_pup> or <image> element" >&2
    return 1
  fi

  label="$(echo "$pup" | ps5fw_attr label)"
  upd_full="$(echo "$pup" | ps5fw_attr upd_version)"
  size="$(echo "$image" | ps5fw_attr size)"
  url="$(echo "$image" | sed -e 's/<image[^>]*>//;s|</image>||' | tr -d '[:space:]')"
  upd_short="$(ps5fw_short_version "$upd_full")"
  major="$(ps5fw_major_version "$upd_short")"
  date="$(ps5fw_url_build_date "$url")"
  sha="$(ps5fw_url_sha256 "$url")"

  if [[ -z "$label" || -z "$upd_full" || -z "$url" || -z "$date" || -z "$sha" ]]; then
    echo "ps5fw: '$xml' is missing required firmware metadata" >&2
    return 1
  fi

  printf 'label=%q\n' "$label"
  printf 'upd_version_full=%q\n' "$upd_full"
  printf 'upd_version=%q\n' "$upd_short"
  printf 'major_version=%q\n' "$major"
  printf 'build_date=%q\n' "$date"
  printf 'sys_url=%q\n' "$url"
  printf 'sys_size=%q\n' "$size"
  printf 'sys_sha256=%q\n' "$sha"
}

# --- playstation.com support page parsing -----------------------------------

# Print every PS5UPDATE.PUP URL found in an HTML page, one per line. The
# scheme is left open rather than pinned to http(s) so the tests can point the
# same code at file:// fixtures.
ps5fw_extract_pup_urls() {
  grep -oE '[a-zA-Z][a-zA-Z0-9+.-]*://[^"'"'"'[:space:]<>\\]*PS5UPDATE\.PUP[^"'"'"'[:space:]<>\\]*' "$1" |
    awk '!seen[$0]++'
}

# Print the recovery (rec_) URL for a given build date, if the page has one.
# The build date pins the recovery image to the same release as the update
# image from updatelist.xml, so a page that has already moved on to a newer
# firmware does not contaminate the row.
ps5fw_find_recovery_url() {
  local html="$1" build_date="$2" url
  while IFS= read -r url; do
    [[ "$(ps5fw_url_kind "$url")" == "rec" ]] || continue
    [[ "$(ps5fw_url_build_date "$url")" == "$build_date" ]] || continue
    echo "$url"
    return 0
  done < <(ps5fw_extract_pup_urls "$html")
  return 1
}

# --- README table editing ---------------------------------------------------

# The two header lines every firmware table starts with. Copied out of the
# README itself so the generated section always matches the current columns.
PS5FW_FALLBACK_TABLE_HEADER='| Firmware Version (Long)        | Version (Short) | Type     | Build Date      | sha256                                                           | md5 checksum                     | size   |'
PS5FW_FALLBACK_TABLE_SEPARATOR='| ------------------------------ | --------------- | -------- | --------------- | ---------------------------------------------------------------- | -------------------------------- | ------ |'

ps5fw_table_header() {
  local line
  line="$(grep -m 1 '^| Firmware Version (Long)' "$1" || true)"
  echo "${line:-$PS5FW_FALLBACK_TABLE_HEADER}"
}

# The separator is taken from the line directly below the first firmware
# table header rather than the first dashed line in the file, so an unrelated
# markdown table elsewhere in the README cannot be mistaken for it.
ps5fw_table_separator() {
  local line
  line="$(grep -A 1 -m 1 '^| Firmware Version (Long)' "$1" | tail -n 1 | grep '^| -\+ |' || true)"
  echo "${line:-$PS5FW_FALLBACK_TABLE_SEPARATOR}"
}

# README.md is stored with CRLF line endings, so anything generated here has
# to match or every inserted row shows up as a whole-file diff. Rewrite a
# file's line endings to match a reference file's.
ps5fw_match_line_endings() {
  local target="$1" reference="$2"
  if head -n 1 "$reference" | grep -q $'\r$'; then
    sed -i -e 's/\r*$/\r/' "$target"
  else
    sed -i -e 's/\r$//' "$target"
  fi
}

# True when the README already mentions a checksum.
ps5fw_readme_has_hash() {
  grep -qiF "$2" "$1"
}

# True when the README already has a "### <major>.x" section.
ps5fw_readme_has_section() {
  grep -qE "^### $2\.x[[:space:]]*$" "$1"
}

# Render one README table row. The padding matches the rows that are already
# in the README (and the suggestion printed by check_updatelist.sh) so the
# generated diff stays consistent with hand-written entries.
# Usage: ps5fw_format_row <label> <short_version> <sys|rec> <build_date> <sha256> <md5> <size_bytes>
ps5fw_format_row() {
  local label="$1" version="$2" kind="$3" build_date="$4" sha256="$5" md5="$6" size="$7"
  local type_cell
  case "$kind" in
    sys) type_cell='🆙 Update  ' ;;
    rec) type_cell='❤️‍🩹 Recovery' ;;
    *) echo "ps5fw: unknown image kind '$kind'" >&2; return 1 ;;
  esac
  printf '| %s | %-15s | %s | %-15s | %s | %s | %s B |\n' \
    "$label" "$version" "$type_cell" "$build_date" "$sha256" "$md5" "$size"
}

# Line number of the row the new "### <major>.x" section must be inserted
# before: the first existing section older than it, otherwise the heading that
# ends the firmware list, otherwise one past the last line of the file.
ps5fw_new_section_line() {
  local readme="$1" major="$2"
  awk -v newmaj="$((10#$major))" '
    !seen_list {
      if ($0 ~ /^## The Full List[[:space:]]*$/) seen_list = 1
      next
    }
    $0 ~ /^### [0-9]+\.x[[:space:]]*$/ {
      m = $2
      sub(/\.x$/, "", m)
      if (m + 0 < newmaj) { print NR; found = 1; exit }
      next
    }
    $0 ~ /^## / { print NR; found = 1; exit }
    END { if (!found) print NR + 1 }
  ' "$readme"
}

# Insert the contents of a file before a given line number of another file,
# printing the result on stdout.
ps5fw_insert_before_line() {
  local file="$1" line="$2" block="$3"
  awk -v target="$line" -v blockfile="$block" '
    NR == target { while ((getline l < blockfile) > 0) print l; close(blockfile) }
    { print }
    END { if (target > NR) { while ((getline l < blockfile) > 0) print l; close(blockfile) } }
  ' "$file"
}

# Add rows to the README, at the top of the "### <major>.x" table because the
# tables are ordered newest first. A major version that has no section yet -
# every 14.00.00-style release - gets a brand new section inserted ahead of
# the sections it supersedes.
# Usage: ps5fw_readme_insert_rows <readme> <major> <rows_file>
ps5fw_readme_insert_rows() {
  local readme="$1" major="$2" rows_file="$3"
  local tmp rows block line

  if [[ ! -s "$rows_file" ]]; then
    echo "ps5fw: refusing to insert an empty set of rows" >&2
    return 1
  fi

  tmp="$(mktemp)"
  rows="$(mktemp)"
  cat "$rows_file" > "$rows"
  ps5fw_match_line_endings "$rows" "$readme"

  if ps5fw_readme_has_section "$readme" "$major"; then
    awk -v major="$major" -v rows_file="$rows" '
      { print }
      !inserted && $0 ~ "^### " major "\\.x[[:space:]]*$" { in_section = 1; next }
      !inserted && in_section && $0 ~ /^\| -+ \|/ {
        while ((getline l < rows_file) > 0) print l
        close(rows_file)
        inserted = 1
        in_section = 0
      }
      END { if (!inserted) exit 3 }
    ' "$readme" > "$tmp" || {
      rm -f "$tmp" "$rows"
      echo "ps5fw: section '### $major.x' has no table to extend" >&2
      return 1
    }
  else
    block="$(mktemp)"
    {
      echo "### $major.x"
      ps5fw_table_header "$readme"
      ps5fw_table_separator "$readme"
      cat "$rows"
      echo ""
    } > "$block"
    ps5fw_match_line_endings "$block" "$readme"
    line="$(ps5fw_new_section_line "$readme" "$major")"
    ps5fw_insert_before_line "$readme" "$line" "$block" > "$tmp"
    rm -f "$block"
  fi

  rm -f "$rows"
  cat "$tmp" > "$readme"
  rm -f "$tmp"
}

# Add rows immediately after the README row that carries a given checksum.
# Used to backfill a recovery image whose update image is already listed, so
# the pair stays adjacent instead of jumping to the top of the table.
ps5fw_readme_insert_after_hash() {
  local readme="$1" hash="$2" rows_file="$3"
  local tmp rows

  if [[ ! -s "$rows_file" ]]; then
    echo "ps5fw: refusing to insert an empty set of rows" >&2
    return 1
  fi

  tmp="$(mktemp)"
  rows="$(mktemp)"
  cat "$rows_file" > "$rows"
  ps5fw_match_line_endings "$rows" "$readme"

  awk -v hash="$hash" -v rows_file="$rows" '
    { print }
    !inserted && index($0, hash) > 0 {
      while ((getline l < rows_file) > 0) print l
      close(rows_file)
      inserted = 1
    }
    END { if (!inserted) exit 3 }
  ' "$readme" > "$tmp" || {
    rm -f "$tmp" "$rows"
    echo "ps5fw: no README row contains '$hash'" >&2
    return 1
  }

  rm -f "$rows"
  cat "$tmp" > "$readme"
  rm -f "$tmp"
}

# --- downloading ------------------------------------------------------------

# Fetch a URL to a local path, retrying transient network failures. Accepts
# file:// URLs, which is what the tests use so they never touch the network.
ps5fw_download() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location \
    --connect-timeout 30 \
    --retry "${PS5FW_CURL_RETRY:-5}" \
    --retry-delay "${PS5FW_CURL_RETRY_DELAY:-10}" \
    --retry-all-errors \
    --output "$dest" "$url"
}

# Hash a local file and print "<sha256> <md5> <size_in_bytes>".
ps5fw_checksums() {
  local file="$1" sha md5 size
  sha="$(sha256sum "$file" | awk '{print $1}')"
  md5="$(md5sum "$file" | awk '{print $1}')"
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  echo "$sha $md5 $size"
}
