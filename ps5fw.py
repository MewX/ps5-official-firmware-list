"""Shared helpers for parsing PS5 update metadata and editing the README table.

Nothing here writes to the network unless you call one of the fetch helpers,
and the parsing and README editing are pure functions over text, which keeps
them cheap to unit test.
"""

from __future__ import annotations

import hashlib
import re
import time
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

USER_AGENT = "ps5-official-firmware-list (+https://github.com/MewX/ps5-official-firmware-list)"

# Sony names the directory holding a PUP after the sha256 of the file itself,
# so the URL carries the checksum a download can be verified against.
IMAGE_SEGMENT_RE = re.compile(r"/(?P<kind>sys|rec)_(?P<sha256>[0-9a-fA-F]{64})/")

# The scheme is left open rather than pinned to http(s) so the tests can point
# the same code at file:// fixtures.
PUP_URL_RE = re.compile(r"""[a-zA-Z][a-zA-Z0-9+.\-]*://[^"'\s<>\\]*PS5UPDATE\.PUP[^"'\s<>\\]*""")

SECTION_RE = re.compile(r"^### (\d+)\.x$")
FULL_LIST_RE = re.compile(r"^## The Full List$")
SEPARATOR_RE = re.compile(r"^\| -+ \|")

TABLE_HEADER_PREFIX = "| Firmware Version (Long)"
FALLBACK_TABLE_HEADER = (
    "| Firmware Version (Long)        | Version (Short) | Type     | Build Date      "
    "| sha256                                                           "
    "| md5 checksum                     | size   |"
)
FALLBACK_TABLE_SEPARATOR = (
    "| ------------------------------ | --------------- | -------- | --------------- "
    "| ---------------------------------------------------------------- "
    "| -------------------------------- | ------ |"
)

# The trailing spaces line the column up the way the rest of the table does.
TYPE_CELLS = {"sys": "\N{SQUARED UP WITH EXCLAMATION MARK} Update  ", "rec": "❤️‍\U0001fa79 Recovery"}


class Ps5fwError(Exception):
    """Base class for the errors this module raises."""


class ParseError(Ps5fwError):
    """An updatelist or support page could not be understood."""


class ChecksumMismatch(Ps5fwError):
    """A download did not match the checksum its own URL advertises."""


class ReadmeError(Ps5fwError):
    """The README is not shaped the way the editing helpers expect."""


# --- updatelist.xml ---------------------------------------------------------


@dataclass(frozen=True)
class Release:
    """The one firmware release an updatelist.xml describes."""

    label: str
    upd_version_full: str
    build_date: str
    sys_url: str
    sys_size: int | None

    @property
    def version(self) -> str:
        """The three part version the README uses, e.g. 14.00.00."""
        return ".".join(self.upd_version_full.split(".")[:3])

    @property
    def major(self) -> str:
        """The section this release belongs in, zero padded: 14, or 09."""
        return self.version.split(".")[0]

    @property
    def sys_sha256(self) -> str:
        return url_sha256(self.sys_url)


def parse_updatelist(xml: str) -> Release:
    """Read the release out of an updatelist.xml document."""
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise ParseError(f"updatelist is not valid XML: {exc}") from exc

    pup = root.find(".//system_pup")
    if pup is None:
        raise ParseError("updatelist has no <system_pup> element")

    image = pup.find(".//image")
    if image is None or not (image.text or "").strip():
        raise ParseError("updatelist has no <image> element with a URL")

    label = pup.get("label")
    upd_version = pup.get("upd_version")
    if not label or not upd_version:
        raise ParseError("<system_pup> is missing its label or upd_version")

    url = "".join((image.text or "").split())
    size = image.get("size")

    release = Release(
        label=label,
        upd_version_full=upd_version,
        build_date=url_build_date(url),
        sys_url=url,
        sys_size=int(size) if size and size.isdigit() else None,
    )
    # Accessing these raises if the URL is not shaped the way we expect, which
    # is better found here than three steps later.
    _ = release.sys_sha256
    return release


# --- firmware URLs ----------------------------------------------------------


def _image_segment(url: str) -> re.Match[str]:
    match = IMAGE_SEGMENT_RE.search(url)
    if match is None:
        raise ParseError(f"no sys_/rec_ checksum segment in URL: {url}")
    return match


def url_sha256(url: str) -> str:
    """The sha256 Sony embeds in a firmware URL."""
    return _image_segment(url).group("sha256").lower()


def url_kind(url: str) -> str:
    """"sys" for an update image, "rec" for a recovery image."""
    return _image_segment(url).group("kind")


def url_build_date(url: str) -> str:
    """The build date segment, i.e. the part right after /image/."""
    parts = url.split("/")
    try:
        return parts[parts.index("image") + 1]
    except (ValueError, IndexError):
        raise ParseError(f"no /image/<build date>/ segment in URL: {url}") from None


# --- playstation.com support page -------------------------------------------


def extract_pup_urls(html: str) -> list[str]:
    """Every PS5UPDATE.PUP URL on a page, in order, without duplicates."""
    seen: dict[str, None] = {}
    for url in PUP_URL_RE.findall(html):
        seen.setdefault(url, None)
    return list(seen)


def find_recovery_url(html: str, build_date: str) -> str | None:
    """The recovery image for one build, or None if the page has no such link.

    Pinning to the build date keeps a page that has already moved on to a newer
    firmware from contaminating the row.
    """
    for url in extract_pup_urls(html):
        try:
            if url_kind(url) == "rec" and url_build_date(url) == build_date:
                return url
        except ParseError:
            continue
    return None


# --- downloading ------------------------------------------------------------


@dataclass(frozen=True)
class Checksums:
    sha256: str
    md5: str
    size: int


def _open(url: str, timeout: float):
    return urlopen(Request(url, headers={"User-Agent": USER_AGENT}), timeout=timeout)


def _with_retries(what: str, attempt, retries: int, delay: float):
    last: Exception | None = None
    for remaining in range(retries, -1, -1):
        try:
            return attempt()
        except (URLError, OSError) as exc:  # URLError is an OSError, be explicit
            last = exc
            if remaining:
                time.sleep(delay)
    raise Ps5fwError(f"could not fetch {what}: {last}") from last


def fetch_text(url: str, *, retries: int = 3, delay: float = 5.0, timeout: float = 60.0) -> str:
    """Download a small text document."""

    def attempt() -> str:
        with _open(url, timeout) as response:
            return response.read().decode("utf-8", errors="replace")

    return _with_retries(url, attempt, retries, delay)


def hash_url(
    url: str,
    *,
    retries: int = 3,
    delay: float = 5.0,
    timeout: float = 60.0,
    chunk_size: int = 1 << 20,
    progress=None,
) -> Checksums:
    """Stream a URL, hashing it as it arrives.

    The firmware images are over a gigabyte each, so they are never written to
    disk: both digests and the size come out of a single pass over the stream.
    """

    def attempt() -> Checksums:
        sha256 = hashlib.sha256()
        md5 = hashlib.md5()
        size = 0
        with _open(url, timeout) as response:
            while chunk := response.read(chunk_size):
                sha256.update(chunk)
                md5.update(chunk)
                size += len(chunk)
                if progress is not None:
                    progress(size)
        return Checksums(sha256.hexdigest(), md5.hexdigest(), size)

    return _with_retries(url, attempt, retries, delay)


def hash_url_verified(url: str, **kwargs) -> Checksums:
    """Stream and hash a firmware URL, rejecting it unless it matches its own
    advertised checksum. A truncated or tampered transfer stops here."""
    expected = url_sha256(url)
    checksums = hash_url(url, **kwargs)
    if checksums.sha256.lower() != expected:
        raise ChecksumMismatch(
            f"{url} hashed to {checksums.sha256} but its URL claims {expected}"
        )
    return checksums


# --- README table -----------------------------------------------------------


def format_row(
    label: str,
    version: str,
    kind: str,
    build_date: str,
    sha256: str,
    md5: str,
    size: int | str,
) -> str:
    """Render one README table row.

    The padding matches the rows already in the README, so a generated entry is
    indistinguishable from a hand written one.
    """
    try:
        type_cell = TYPE_CELLS[kind]
    except KeyError:
        raise ValueError(f"unknown image kind: {kind!r}") from None
    return f"| {label} | {version:<15} | {type_cell} | {build_date:<15} | {sha256} | {md5} | {size} B |"


def read_raw(path: str | Path) -> str:
    """Read a text file with its line endings untranslated."""
    with Path(path).open(encoding="utf-8", newline="") as handle:
        return handle.read()


class Readme:
    """The README, loaded so its exact line endings survive a round trip.

    README.md is stored with CRLF. Reading with newline="" keeps every line
    ending untranslated, and generated lines reuse whatever the file already
    uses, so an inserted row never shows up as a whole-file diff.
    """

    def __init__(self, path: str | Path):
        self.path = Path(path)
        text = read_raw(self.path)
        self.eol = "\r\n" if "\r\n" in text else "\n"
        self.lines = text.splitlines(keepends=True)

    # -- reading

    @property
    def text(self) -> str:
        return "".join(self.lines)

    def _plain(self, index: int) -> str:
        return self.lines[index].rstrip("\r\n")

    def has_hash(self, checksum: str) -> bool:
        return checksum.lower() in self.text.lower()

    def section_index(self, major: str) -> int | None:
        """Where the "### <major>.x" heading is, if the README has one."""
        wanted = int(major)
        for index in range(len(self.lines)):
            match = SECTION_RE.match(self._plain(index))
            if match and int(match.group(1)) == wanted:
                return index
        return None

    def has_section(self, major: str) -> bool:
        return self.section_index(major) is not None

    def table_header(self) -> str:
        for index in range(len(self.lines)):
            if self._plain(index).startswith(TABLE_HEADER_PREFIX):
                return self._plain(index)
        return FALLBACK_TABLE_HEADER

    def table_separator(self) -> str:
        """The separator below the first firmware table header.

        Taken from that exact position rather than the first dashed line in the
        file, so an unrelated markdown table cannot be mistaken for it.
        """
        for index in range(len(self.lines) - 1):
            if self._plain(index).startswith(TABLE_HEADER_PREFIX):
                below = self._plain(index + 1)
                return below if SEPARATOR_RE.match(below) else FALLBACK_TABLE_SEPARATOR
        return FALLBACK_TABLE_SEPARATOR

    # -- writing

    def _render(self, text: str) -> str:
        return text + self.eol

    def _separator_after(self, section_index: int) -> int:
        for index in range(section_index + 1, len(self.lines)):
            plain = self._plain(index)
            if SEPARATOR_RE.match(plain):
                return index
            if plain.startswith("#"):
                break
        raise ReadmeError(f"section at line {section_index + 1} has no table to extend")

    def _new_section_index(self, major: str) -> int:
        """Where a brand new "### <major>.x" section belongs.

        Before the first section it supersedes, otherwise before the heading
        that ends the firmware list, otherwise at the end of the file.
        """
        wanted = int(major)
        start = 0
        for index in range(len(self.lines)):
            if FULL_LIST_RE.match(self._plain(index)):
                start = index + 1
                break

        for index in range(start, len(self.lines)):
            plain = self._plain(index)
            match = SECTION_RE.match(plain)
            if match:
                if int(match.group(1)) < wanted:
                    return index
            elif plain.startswith("## "):
                return index
        return len(self.lines)

    def insert_rows(self, major: str, rows: list[str]) -> bool:
        """Add rows to the "### <major>.x" table, newest first.

        A major version with no section yet gets one created ahead of the
        sections it supersedes. Returns True if a new section was created.
        """
        if not rows:
            raise ValueError("refusing to insert an empty set of rows")

        section = self.section_index(major)
        if section is not None:
            at = self._separator_after(section) + 1
            self.lines[at:at] = [self._render(row) for row in rows]
            return False

        block = [
            self._render(f"### {major}.x"),
            self._render(self.table_header()),
            self._render(self.table_separator()),
            *(self._render(row) for row in rows),
            self._render(""),
        ]
        at = self._new_section_index(major)
        if at == len(self.lines) and self.lines and not self.lines[-1].endswith(("\n", "\r")):
            self.lines[-1] += self.eol
        self.lines[at:at] = block
        return True

    def insert_after_hash(self, checksum: str, rows: list[str]) -> None:
        """Add rows directly below the row carrying a checksum.

        Used to backfill a recovery image whose update image is already listed,
        so the pair stays adjacent instead of jumping to the top of the table.
        """
        if not rows:
            raise ValueError("refusing to insert an empty set of rows")

        needle = checksum.lower()
        for index, line in enumerate(self.lines):
            if needle in line.lower():
                at = index + 1
                self.lines[at:at] = [self._render(row) for row in rows]
                return
        raise ReadmeError(f"no README row contains {checksum}")

    def save(self) -> None:
        with self.path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(self.text)
