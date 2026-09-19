# Update URL anatomy and the available regions

Background for [issue #8](https://github.com/MewX/ps5-official-firmware-list/issues/8),
which asked how to work out `<OBFUSCATED_STRING>` for a specific firmware.
Short answer: you don't — it is a constant. The longer answer, and everything
else the URLs turned out to hide, is below. All of it was measured on
2026-09-19 against firmware 14.00.00 (build `2026_0909`).

## The URLs

```
update list:  http://f<REGION>01.ps5.update.playstation.net/update/ps5/official/<OBFUSCATED_STRING>/list/<REGION>/updatelist.xml
firmware:     http://d<REGION>01.ps5.update.playstation.net/update/ps5/official/<OBFUSCATED_STRING>/image/<BUILD_DATE>/sys_<SHA256>/PS5UPDATE.PUP?dest=<REGION>
```

| Part                  | Varies?          | Where it comes from                                                       |
| --------------------- | ---------------- | ------------------------------------------------------------------------- |
| `f<REGION>01` host    | No (cosmetic)    | Any resolving host works — see [Hostnames](#hostnames-are-cosmetic)        |
| `<OBFUSCATED_STRING>` | No               | Always `tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6`                                  |
| `<REGION>`            | 8 values         | See [Regions](#only-8-regions-exist)                                       |
| `<BUILD_DATE>`        | Per firmware     | `YYYY_MMDD`, the "Build Date" column of the main README                    |
| `sys_<SHA256>`        | Per firmware     | The SHA-256 of `PS5UPDATE.PUP` itself. Recovery images use `rec_<SHA256>`  |
| `?dest=<REGION>`      | No (ignored)     | The download servers do not look at it                                     |

Neither the build date nor the SHA-256 can be computed ahead of time. Read them
from `updatelist.xml`, from the
[PS5 system software page](https://www.playstation.com/en-us/support/hardware/ps5/system-software/),
or from the tables in the main README.

## `<OBFUSCATED_STRING>` is a constant

It is not derived from the firmware version, the region, or anything else. Every
`updatelist.xml` archived in [`../../updatelists/`](../../updatelists/) carries the
same value, as does every response collected here, and
[`../../check_updatelist.sh`](../../check_updatelist.sh) simply hardcodes it.

It is matched exactly — changing its case, truncating it by one character,
substituting a same-length string, or dropping it altogether all return
`404 Not found`. It is also console-specific: the same string against
`fus01.ps4.update.playstation.net` and `fus01.ps3.update.playstation.net` 404s.

The path shape is equally exact. `/list/us/` without a filename, `/list/us`,
`/list/updatelist.xml` and `/list/us/update-list.xml` (the PS4 spelling) all 404.

## Only 8 regions exist

| `<REGION>` | Country of the code | ISO 3166-1 alpha-2? |
| ---------- | ------------------- | ------------------- |
| `au`       | Australia           | yes                 |
| `br`       | Brazil              | yes                 |
| `cn`       | China               | yes                 |
| `jp`       | Japan               | yes                 |
| `ru`       | Russia              | yes                 |
| `sa`       | Saudi Arabia        | yes                 |
| `uk`       | United Kingdom      | **no** — ISO assigns `gb` |
| `us`       | United States       | yes                 |

So these are Sony's own market codes, not an international standard: only 7 of
the 249 officially assigned ISO 3166-1 alpha-2 codes serve a list, and the
eighth, `uk`, is not an ISO 3166-1 country code at all (`/list/gb/` 404s).

Everything else returns `404 Not found`: the other 242 ISO alpha-2 codes (no
`de`, `fr`, `ca`, `kr`, `hk`, `in`, ...), ISO 3166-1 alpha-3 codes (`usa`, `jpn`,
`gbr`, ...), ISO 3166-1 numeric codes (`840`, `392`, ...), uppercase spellings
(`/list/US/` — the path is case-sensitive, unlike DNS), and groupings such as
`eu`, `apac`, `emea` and `latam`.

Which console uses which list is decided by the console, so the mapping from a
country without its own list to the one it actually uses cannot be observed from
outside.

## Hostnames are cosmetic

Twelve `f<CC>01` names resolve — the 8 regions above plus `eu`, `kr`, `mx` and
`tw`, which have no list of their own — and they all resolve to a single Akamai
endpoint. Every one of the twelve serves all 8 regions' lists:
`http://feu01.../list/us/updatelist.xml` returns the same bytes as
`http://fus01.../list/us/updatelist.xml`. Only the `/list/<REGION>/` path
segment selects the content. See the 12 × 8 matrix in
[`results/cross_checks.txt`](results/cross_checks.txt).

## The 8 lists are the same firmware

All 8 responses are 2825 bytes with the same `Last-Modified`
(Tue, 15 Sep 2026 00:44:51 GMT), and they agree on every field that matters:
`system_pup` label `26.06-14.00.00.39-00.00.00.0.1`, `upd_version`
`14.00.00.00`, size `1260600832`, build date `2026_0909`, SHA-256
`1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc`, the same
12-entry `force_update` block and the same `finished_test_list`.

They differ in exactly three cosmetic places — `<region id>`, the `d<REGION>01`
hostname inside the image URL, and `?dest=<REGION>`:

```diff
-	<region id="us">
+	<region id="jp">
-	<image ...>http://dus01.../PS5UPDATE.PUP?dest=us</image>
+	<image ...>http://djp01.../PS5UPDATE.PUP?dest=jp</image>
```

And neither of those two URL differences matters either. `?dest=` is ignored —
`dest=jp`, `dest=zz`, an empty value and no parameter at all all return 200 — and
all 8 `d<REGION>01` hosts serve the byte-identical file (identical SHA-256 over
the first 1 MiB, `content-length` 1260600832 everywhere).

**The region does not change which firmware you get.**

## Method and caveats

[`region_probe.sh`](region_probe.sh) requests `/list/<CC>/updatelist.xml` for 292
codes — all 249 officially assigned ISO 3166-1 alpha-2 codes plus alpha-3,
numeric, uppercase, grouping and invalid-control codes — sending every request to
one fixed host, and separately records whether `f<CC>01` and `d<CC>01` resolve.
[`region_report.py`](region_report.py) groups the responses and prints every
field that differs.

```
bash region_probe.sh out && python3 region_report.py out
```

Host reachability and path availability are deliberately probed separately:
conflating them is wrong, because the hostname has no effect on the response.

Caveats:

- Measured from a GitHub-hosted runner (US, plain HTTP). If Sony varies
  responses by client geography, that would not show up here.
- The set of regions is whatever Sony served on 2026-09-19. Re-run the script to
  check it again.

## Files

| Path | What it is |
| ---- | ---------- |
| [`results/results.tsv`](results/results.tsv)         | All 292 probed codes: DNS for `f*01`/`d*01`, HTTP status, body size and hash |
| [`results/report.txt`](results/report.txt)           | Generated summary: availability, DNS grouping, field-by-field differences |
| [`results/cross_checks.txt`](results/cross_checks.txt) | Host × region matrix, token and `?dest=` sensitivity, path shapes, PS4/PS3 |
| [`results/headers.txt`](results/headers.txt)         | Response headers from four serving regions |
| `results/<region>.xml`                               | The update list each of the 8 regions served |
