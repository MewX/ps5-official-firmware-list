#!/bin/bash
# Probe Sony's PS5 update service for every plausible country/region code.
#
# URL format (see README.md):
#   http://f<CC>01.ps5.update.playstation.net/update/ps5/official/<TOKEN>/list/<CC>/updatelist.xml
#
# The hostname and the /list/<CC>/ path segment are probed independently,
# because they are not the same thing: every f*01 hostname that resolves is the
# same Akamai endpoint, and the path segment alone selects the region.
#
# Usage: bash region_probe.sh [output_dir]
# Env:   PAR=<n> parallel workers (default 8), TIMEOUT=<s> per request (default 15),
#        FIXED_HOST=<host> host used for every path-segment request.

set -uo pipefail

TOKEN="tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6"
OUT="${1:-region_probe_out}"
PAR="${PAR:-8}"
TIMEOUT="${TIMEOUT:-15}"
FIXED_HOST="${FIXED_HOST:-fus01.ps5.update.playstation.net}"

# The code lists live beside this script so the console DNS probe can share them.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_codes() { grep -v '^#' "$1" | grep -v '^$'; }
ISO2=$(read_codes "$HERE/codes-iso3166.txt")
EXTRA=$(read_codes "$HERE/codes-extra.txt")

mkdir -p "$OUT/xml" "$OUT/rows"

probe() {
  cc="$1"
  fhost="f${cc}01.ps5.update.playstation.net"
  dhost="d${cc}01.ps5.update.playstation.net"

  f_ip=$(getent ahostsv4 "$fhost" 2>/dev/null | awk 'NR==1{print $1}')
  d_ip=$(getent ahostsv4 "$dhost" 2>/dev/null | awk 'NR==1{print $1}')

  url="http://${FIXED_HOST}/update/ps5/official/${TOKEN}/list/${cc}/updatelist.xml"
  code=$(curl -sS -o "$OUT/xml/$cc.xml" -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null)
  rc=$?
  [ $rc -ne 0 ] && code="CURL_$rc"

  bytes=$(wc -c < "$OUT/xml/$cc.xml" 2>/dev/null | tr -d ' ')
  bytes=${bytes:-0}
  if [ "$bytes" -gt 0 ] && [ "$code" = "200" ]; then
    body=$(sha256sum "$OUT/xml/$cc.xml" | cut -c1-16)
    regid=$(grep -o '<region id="[^"]*"' "$OUT/xml/$cc.xml" | head -1 | sed 's/.*id="//;s/"//')
  else
    body="-"; regid="-"
    rm -f "$OUT/xml/$cc.xml"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cc" "${f_ip:--}" "${d_ip:--}" "$code" "$bytes" "${body:--}" "${regid:--}" > "$OUT/rows/$cc"
}
export -f probe
export TOKEN OUT TIMEOUT FIXED_HOST

CODES=$(echo $ISO2 $EXTRA | tr ' ' '\n' | grep -v '^$')
echo "Probing $(echo "$CODES" | wc -l) codes via $FIXED_HOST with $PAR workers..." >&2
echo "$CODES" | xargs -P "$PAR" -I{} bash -c 'probe "$@"' _ {}

printf 'cc\tf_host_ip\td_host_ip\thttp\tbytes\tbody_sha256_16\tregion_id\n' > "$OUT/results.tsv"
cat "$OUT/rows"/* >> "$OUT/results.tsv"
rm -rf "$OUT/rows"

echo "Wrote $OUT/results.tsv ($(($(wc -l < "$OUT/results.tsv") - 1)) rows), XML in $OUT/xml/" >&2
