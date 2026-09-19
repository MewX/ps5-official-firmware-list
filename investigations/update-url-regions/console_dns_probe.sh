#!/bin/bash
# Resolve the update-service hostnames of several consoles for every region
# code, to see which region names each console has.
#
# Hostname shape:
#   f<CC>01.<console>.update.playstation.net   (update list)
#   d<CC>01.<console>.update.playstation.net   (firmware download)
#
# This probes DNS only. Fetching a console's update list needs that console's
# own obfuscated path segment, which we have for the PS5 alone, so hostname
# existence is as far as a cross-console comparison can go.
#
# Usage: bash console_dns_probe.sh [output_dir]
# Env:   PAR=<n> parallel workers (default 16), CONSOLES="ps3 ps4 ps5"

set -uo pipefail

OUT="${1:-console_dns_out}"
PAR="${PAR:-16}"
CONSOLES="${CONSOLES:-ps3 ps4 ps5}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_codes() { grep -v '^#' "$1" | grep -v '^$'; }
CODES=$(read_codes "$HERE/codes-iso3166.txt"; read_codes "$HERE/codes-extra.txt")

mkdir -p "$OUT/rows"

probe() {
  cc="$1"
  line="$cc"
  for console in $CONSOLES; do
    for prefix in f d; do
      host="${prefix}${cc}01.${console}.update.playstation.net"
      ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
      line="$line	${ip:--}"
    done
  done
  printf '%s\n' "$line" > "$OUT/rows/$cc"
}
export -f probe
export OUT CONSOLES

echo "Resolving $(echo "$CODES" | wc -l) codes x $(echo $CONSOLES | wc -w) consoles x 2 prefixes..." >&2
echo "$CODES" | xargs -P "$PAR" -I{} bash -c 'probe "$@"' _ {}

header="cc"
for console in $CONSOLES; do
  header="$header	${console}_f	${console}_d"
done
printf '%s\n' "$header" > "$OUT/results.tsv"
cat "$OUT/rows"/* >> "$OUT/results.tsv"
rm -rf "$OUT/rows"

echo "Wrote $OUT/results.tsv ($(($(wc -l < "$OUT/results.tsv") - 1)) rows)" >&2

# Summary: which codes each console has hostnames for.
{
  echo "== Region hostnames per console (DNS) =="
  col=1
  for console in $CONSOLES; do
    for prefix in f d; do
      col=$((col + 1))
      codes=$(awk -F'\t' -v c="$col" 'NR>1 && $c != "-" {print $1}' "$OUT/results.tsv" | sort | tr '\n' ' ')
      count=$(echo $codes | wc -w)
      printf '%s %s<CC>01  %3d  %s\n' "$console" "$prefix" "$count" "$codes"
    done
  done
} | tee "$OUT/summary.txt"
