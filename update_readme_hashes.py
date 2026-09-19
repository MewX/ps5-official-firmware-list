#!/usr/bin/env python3
"""Hash the firmware images for the newest release and record them in README.md.

check_updatelist.sh notices that a new updatelist.xml exists and opens a PR for
it, but it can only print a TODO_SHA256/TODO_MD5 row: the real checksums need
the ~1.2GB update image and the ~1.4GB recovery image. This does that part.

Both images are streamed and hashed as they arrive, so neither is ever written
to disk, and each is rejected unless it matches the sha256 Sony embeds in its
own download URL.

Every input can be overridden, which is how tests/ drives the whole flow
against local file:// fixtures without touching the network.
"""

from __future__ import annotations

import argparse
import os
import sys

import ps5fw

DEFAULT_UPDATELIST_URL = (
    "http://fus01.ps5.update.playstation.net/update/ps5/official/"
    "tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/list/us/updatelist.xml"
)
DEFAULT_SUPPORT_URL = "https://www.playstation.com/en-us/support/hardware/ps5/system-software/"


def log(message: str) -> None:
    print(f"==> {message}", flush=True)


def warn(message: str) -> None:
    print(f"WARNING: {message}", file=sys.stderr, flush=True)


def set_output(name: str, value: object) -> None:
    """Report back to the calling workflow. A no-op when run locally."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    env = os.environ.get
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--updatelist-url", default=env("PS5FW_UPDATELIST_URL", DEFAULT_UPDATELIST_URL))
    parser.add_argument("--support-url", default=env("PS5FW_SUPPORT_URL", DEFAULT_SUPPORT_URL))
    parser.add_argument("--readme", default=env("PS5FW_README", "README.md"))
    parser.add_argument("--summary-file", default=env("PS5FW_SUMMARY_FILE") or None)
    parser.add_argument("--retries", type=int, default=int(env("PS5FW_RETRIES", "3")))
    parser.add_argument("--retry-delay", type=float, default=float(env("PS5FW_RETRY_DELAY", "5")))
    return parser.parse_args(argv)


def write_summary(path: str, lines: list[str]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    fetch = {"retries": args.retries, "delay": args.retry_delay}

    readme = ps5fw.Readme(args.readme)

    # 1. What is the newest release?
    log(f"Fetching {args.updatelist_url}")
    release = ps5fw.parse_updatelist(ps5fw.fetch_text(args.updatelist_url, **fetch))
    log(f"Latest firmware: {release.label} ({release.version}, built {release.build_date})")

    log(f"Fetching {args.support_url}")
    recovery_url = None
    try:
        page = ps5fw.fetch_text(args.support_url, **fetch)
    except ps5fw.Ps5fwError as exc:
        warn(f"could not fetch the support page, continuing without it: {exc}")
    else:
        recovery_url = ps5fw.find_recovery_url(page, release.build_date)

    if recovery_url:
        log(f"Recovery image: {recovery_url}")
    else:
        warn(f"no recovery image for build {release.build_date} on the support page")

    # 2. Is there anything to do?
    need_update = not readme.has_hash(release.sys_sha256)
    need_recovery = bool(recovery_url) and not readme.has_hash(ps5fw.url_sha256(recovery_url))

    if not need_update and not need_recovery:
        message = f"README.md already lists {release.label} ({release.version}). Nothing to do."
        log(message)
        set_output("changed", "false")
        if args.summary_file:
            write_summary(args.summary_file, [message])
        return 0

    # 3. Stream, hash and verify.
    rows: list[str] = []
    added: list[str] = []
    sources: list[str] = []

    def take(kind: str, url: str) -> None:
        log(f"Hashing {kind} image ({url})")
        sums = ps5fw.hash_url_verified(url, **fetch)
        log(f"{kind}: sha256={sums.sha256} md5={sums.md5} size={sums.size} B")
        rows.append(
            ps5fw.format_row(
                release.label, release.version, kind, release.build_date,
                sums.sha256, sums.md5, sums.size,
            )
        )
        label = "\N{SQUARED UP WITH EXCLAMATION MARK} Update" if kind == "sys" else "❤️‍\U0001fa79 Recovery"
        added.append(f"- {label} (`{sums.sha256}`, {sums.size} B)")
        sources.append(f"| {label} | {url} |")
        if kind == "sys" and release.sys_size is not None and release.sys_size != sums.size:
            warn(f"updatelist.xml says {release.sys_size} B but the download is {sums.size} B")

    if need_update:
        take("sys", release.sys_url)
    if need_recovery:
        take("rec", recovery_url)

    # 4. Write the README.
    new_section = False
    if need_update:
        if not readme.has_section(release.major):
            log(f"Creating a new '### {release.major}.x' section")
        new_section = readme.insert_rows(release.major, rows)
    else:
        # Only the recovery image is missing: keep it next to its update row.
        log(f"Backfilling the recovery row for {release.label}")
        readme.insert_after_hash(release.sys_sha256, rows)
    readme.save()
    log(f"{args.readme} updated")

    set_output("changed", "true")
    set_output("version", release.version)
    set_output("label", release.label)
    set_output("build_date", release.build_date)
    set_output("major_version", release.major)
    set_output("new_section", str(new_section).lower())

    if args.summary_file:
        summary = [
            f"Checksums for PS5 firmware `{release.label}` "
            f"(`{release.version}`, built `{release.build_date}`).",
            "",
            "| Image | Source |",
            "| ----- | ------ |",
            *sources,
            "",
            "Added to the README:",
            "",
            *added,
            "",
        ]
        if new_section:
            summary += [
                f"This release bumps the major version, so a new "
                f"`### {release.major}.x` section was created.",
                "",
            ]
        if need_update and not recovery_url:
            summary += [
                "> [!WARNING]",
                f"> No recovery image for build `{release.build_date}` was found on the",
                "> support page, so only the update row was added. The recovery row still",
                "> needs to be filled in.",
                "",
            ]
        summary.append(
            "Every image was verified against the sha256 that Sony embeds in its download URL."
        )
        write_summary(args.summary_file, summary)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ps5fw.Ps5fwError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
