#!/bin/bash
# Download the firmware images for the newest release and write their
# checksums into README.md.
#
# check_updatelist.sh notices that a new updatelist.xml exists and opens a PR
# for it, but it can only print a TODO_SHA256/TODO_MD5 row because the real
# checksums require the ~1.2GB update image and the ~1.4GB recovery image.
# This script does that part: it downloads both images, hashes them, verifies
# the hashes against the checksum Sony embeds in the download URL, and adds
# the rows to the README - creating a new "### <major>.x" section when the
# release bumps the major version.
#
# Every input can be overridden, which is how tests/ exercises the whole flow
# against local fixtures without touching the network or downloading 2GB:
#
#   PS5FW_UPDATELIST_URL  where to read updatelist.xml from
#   PS5FW_SUPPORT_URL     the PlayStation support page listing the PUP links
#   PS5FW_README          the README to edit
#   PS5FW_WORKDIR         scratch directory for downloads
#   PS5FW_SUMMARY_FILE    where to write the markdown summary (PR body)
#   PS5FW_KEEP_DOWNLOADS  set to 1 to keep the PUPs instead of deleting them
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ps5fw.sh
source "$script_dir/lib/ps5fw.sh"

UPDATELIST_URL="${PS5FW_UPDATELIST_URL:-http://fus01.ps5.update.playstation.net/update/ps5/official/tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/list/us/updatelist.xml}"
SUPPORT_URL="${PS5FW_SUPPORT_URL:-https://www.playstation.com/en-us/support/hardware/ps5/system-software/}"
README="${PS5FW_README:-$script_dir/README.md}"
KEEP_DOWNLOADS="${PS5FW_KEEP_DOWNLOADS:-0}"
SUMMARY_FILE="${PS5FW_SUMMARY_FILE:-}"

workdir="${PS5FW_WORKDIR:-}"
workdir_is_temporary=0
if [[ -z "$workdir" ]]; then
  workdir="$(mktemp -d)"
  workdir_is_temporary=1
fi
mkdir -p "$workdir"

cleanup() {
  if [[ "$workdir_is_temporary" == 1 && "$KEEP_DOWNLOADS" != 1 ]]; then
    rm -rf "$workdir"
  fi
}
trap cleanup EXIT

log() { echo "==> $*"; }

# Report back to the calling workflow. Harmless when run locally.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

finish_unchanged() {
  log "$1"
  set_output changed false
  if [[ -n "$SUMMARY_FILE" ]]; then
    echo "$1" > "$SUMMARY_FILE"
  fi
  exit 0
}

[[ -f "$README" ]] || { echo "No README at '$README'" >&2; exit 1; }

# --- 1. what is the newest release? -----------------------------------------

updatelist="$workdir/updatelist.xml"
log "Fetching $UPDATELIST_URL"
ps5fw_download "$UPDATELIST_URL" "$updatelist"
metadata="$(ps5fw_parse_updatelist "$updatelist")"
# ps5fw_parse_updatelist emits shell assignments for exactly these names.
# upd_version_full is part of that contract even though only the short form
# ends up in the README.
# shellcheck disable=SC2034
label="" upd_version_full="" upd_version="" major_version=""
build_date="" sys_url="" sys_size="" sys_sha256=""
eval "$metadata"

log "Latest firmware: $label ($upd_version, built $build_date)"

support_page="$workdir/support.html"
rec_url=""
log "Fetching $SUPPORT_URL"
if ps5fw_download "$SUPPORT_URL" "$support_page"; then
  rec_url="$(ps5fw_find_recovery_url "$support_page" "$build_date" || true)"
else
  echo "WARNING: could not fetch the support page; continuing without it" >&2
fi

if [[ -n "$rec_url" ]]; then
  rec_sha256="$(ps5fw_url_sha256 "$rec_url")"
  log "Recovery image: $rec_url"
else
  rec_sha256=""
  echo "WARNING: no recovery image for build $build_date on the support page" >&2
fi

# --- 2. is there anything to do? --------------------------------------------

need_sys=1
need_rec=0
if ps5fw_readme_has_hash "$README" "$sys_sha256"; then
  need_sys=0
fi
if [[ -n "$rec_sha256" ]] && ! ps5fw_readme_has_hash "$README" "$rec_sha256"; then
  need_rec=1
fi

if [[ "$need_sys" == 0 && "$need_rec" == 0 ]]; then
  finish_unchanged "README.md already lists $label ($upd_version). Nothing to do."
fi

# --- 3. download and hash ---------------------------------------------------

# Hash a firmware image and print "<sha256> <md5> <size>". The download is
# rejected unless it matches the checksum in its own URL, so a truncated or
# tampered transfer can never reach the README.
hash_image() {
  local kind="$1" url="$2" expected_sha="$3"
  local dest sums sha md5 size

  dest="$workdir/${kind}_PS5UPDATE.PUP"
  log "Downloading $kind image ($url)" >&2
  ps5fw_download "$url" "$dest"

  sums="$(ps5fw_checksums "$dest")"
  read -r sha md5 size <<< "$sums"
  log "$kind: sha256=$sha md5=$md5 size=$size B" >&2

  if [[ "${sha,,}" != "${expected_sha,,}" ]]; then
    echo "ERROR: $kind image hashed to $sha but its URL claims $expected_sha" >&2
    return 1
  fi

  if [[ "$KEEP_DOWNLOADS" != 1 ]]; then
    rm -f "$dest"
  fi

  echo "$sha $md5 $size"
}

rows_file="$workdir/rows.md"
: > "$rows_file"
added=()

if [[ "$need_sys" == 1 ]]; then
  sums="$(hash_image sys "$sys_url" "$sys_sha256")"
  read -r sha md5 size <<< "$sums"
  if [[ -n "$sys_size" && "$sys_size" != "$size" ]]; then
    echo "WARNING: updatelist.xml says $sys_size B but the download is $size B" >&2
  fi
  ps5fw_format_row "$label" "$upd_version" sys "$build_date" "$sha" "$md5" "$size" >> "$rows_file"
  added+=("Update (\`$sha\`, $size B)")
fi

if [[ "$need_rec" == 1 ]]; then
  sums="$(hash_image rec "$rec_url" "$rec_sha256")"
  read -r sha md5 size <<< "$sums"
  ps5fw_format_row "$label" "$upd_version" rec "$build_date" "$sha" "$md5" "$size" >> "$rows_file"
  added+=("Recovery (\`$sha\`, $size B)")
fi

# --- 4. write the README ----------------------------------------------------

new_section=false
if [[ "$need_sys" == 1 ]]; then
  if ! ps5fw_readme_has_section "$README" "$major_version"; then
    new_section=true
    log "Creating a new '### $major_version.x' section"
  fi
  ps5fw_readme_insert_rows "$README" "$major_version" "$rows_file"
else
  # Only the recovery image is missing: keep it next to its update row.
  log "Backfilling the recovery row for $label"
  ps5fw_readme_insert_after_hash "$README" "$sys_sha256" "$rows_file"
fi

log "README.md updated"

set_output changed true
set_output version "$upd_version"
set_output label "$label"
set_output build_date "$build_date"
set_output major_version "$major_version"
set_output new_section "$new_section"

if [[ -n "$SUMMARY_FILE" ]]; then
  {
    echo "Checksums for PS5 firmware \`$label\` (\`$upd_version\`, built \`$build_date\`)."
    echo ""
    echo "| Image | Source |"
    echo "| ----- | ------ |"
    if [[ "$need_sys" == 1 ]]; then echo "| 🆙 Update | $sys_url |"; fi
    if [[ "$need_rec" == 1 ]]; then echo "| ❤️‍🩹 Recovery | $rec_url |"; fi
    echo ""
    echo "Added to the README:"
    echo ""
    for entry in "${added[@]}"; do
      echo "- $entry"
    done
    echo ""
    if [[ "$new_section" == true ]]; then
      echo "This release bumps the major version, so a new \`### $major_version.x\` section was created."
      echo ""
    fi
    if [[ "$need_sys" == 1 && -z "$rec_sha256" ]]; then
      echo "> [!WARNING]"
      echo "> No recovery image for build \`$build_date\` was found on the support page,"
      echo "> so only the update row was added. The recovery row still needs to be filled in."
      echo ""
    fi
    echo "Every image was verified against the sha256 that Sony embeds in its download URL."
  } > "$SUMMARY_FILE"
fi
