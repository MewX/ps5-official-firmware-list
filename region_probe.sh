#!/bin/bash
# Probe every ISO 3166-1 alpha-2 region code for a PS5 update list.
#
# URL format (see README.md):
#   http://f<CC>01.ps5.update.playstation.net/update/ps5/official/<TOKEN>/list/<CC>/updatelist.xml
#
# Usage: bash region_probe.sh [output_dir]
# Env:   PAR=<n> parallel workers (default 12), TIMEOUT=<s> per request (default 20)

set -uo pipefail

TOKEN="tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6"
OUT="${1:-region_probe_out}"
PAR="${PAR:-12}"
TIMEOUT="${TIMEOUT:-20}"

# ISO 3166-1 alpha-2, the 249 officially assigned codes (tzdata iso3166.tab).
ISO_CODES="ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq
br bs bt bv bw by bz ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee
eg eh er es et fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr
ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls
lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl
no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si
sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug um us uy
uz va vc ve vg vi vn vu wf ws ye yt za zm zw"

# Non-ISO codes worth checking: ccTLD-style and region-style aliases, plus a
# deliberately invalid control code.
EXTRA_CODES="uk eu en su ac zz"

mkdir -p "$OUT/xml" "$OUT/hdr" "$OUT/rows"

probe() {
  cc="$1"
  host="f${cc}01.ps5.update.playstation.net"
  url="http://${host}/update/ps5/official/${TOKEN}/list/${cc}/updatelist.xml"

  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  [ -z "$ip" ] && ip="-"

  if [ "$ip" = "-" ]; then
    printf '%s\t%s\tDNS_FAIL\t0\t-\n' "$cc" "$ip" > "$OUT/rows/$cc"
    return
  fi

  code=$(curl -sS -o "$OUT/xml/$cc.xml" -D "$OUT/hdr/$cc.txt" \
              -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>"$OUT/hdr/$cc.err")
  rc=$?
  [ $rc -ne 0 ] && code="CURL_$rc"

  bytes=$(wc -c < "$OUT/xml/$cc.xml" 2>/dev/null | tr -d ' ')
  if [ "${bytes:-0}" -gt 0 ]; then
    body=$(sha256sum "$OUT/xml/$cc.xml" | cut -c1-16)
  else
    body="-"
    rm -f "$OUT/xml/$cc.xml"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$cc" "$ip" "$code" "${bytes:-0}" "$body" > "$OUT/rows/$cc"
}
export -f probe
export TOKEN OUT TIMEOUT

echo "Probing $(echo $ISO_CODES $EXTRA_CODES | wc -w) region codes with $PAR workers..." >&2
echo $ISO_CODES $EXTRA_CODES | tr ' ' '\n' | grep -v '^$' | \
  xargs -P "$PAR" -I{} bash -c 'probe "$@"' _ {}

printf 'cc\tip\thttp\tbytes\tbody_sha256_16\n' > "$OUT/results.tsv"
cat "$OUT/rows"/* >> "$OUT/results.tsv"
rm -rf "$OUT/rows"

echo "Wrote $OUT/results.tsv ($(($(wc -l < "$OUT/results.tsv") - 1)) rows), XML in $OUT/xml/" >&2
