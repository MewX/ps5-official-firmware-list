"""Unit tests for ps5fw: parsing, row formatting and README editing.

These run against the updatelist.xml files and the README.md that are already
committed to this repository, so they double as a regression test that the
parser and the row formatter still agree with the real data.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

import ps5fw

REPO_ROOT = Path(__file__).resolve().parent.parent
README = REPO_ROOT / "README.md"
UPDATELISTS = sorted(
    path for path in (REPO_ROOT / "updatelists").glob("updatelist.*.xml")
    if path.name != "updatelist.latest.xml"
)

SYS_URL = (
    "http://dus01.ps5.update.playstation.net/update/ps5/official/"
    "tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/image/2026_0909/"
    "sys_1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc/PS5UPDATE.PUP?dest=us"
)
REC_URL = (
    "http://dus01.ps5.update.playstation.net/update/ps5/official/"
    "tJMRE80IbXnE9YuG0jzTXgKEjIMoabr6/image/2026_0909/"
    "rec_7ec8dd8a6f518370422844d2c9d670316774d3dc9d52d78a676a3452ff63c556/PS5UPDATE.PUP"
)

FIXTURES = REPO_ROOT / "tests" / "fixtures"

# A miniature README with the same shape as the real one: an intro, the
# firmware list with two sections, and a trailing heading. Kept as a fixture
# file so the table rows, which are inherently long, stay out of the source.
MINI_README = ps5fw.read_raw(FIXTURES / "mini_readme.md")
HEADER = next(line for line in MINI_README.splitlines() if line.startswith(ps5fw.TABLE_HEADER_PREFIX))
SEPARATOR = next(line for line in MINI_README.splitlines() if ps5fw.SEPARATOR_RE.match(line))


def make_updatelist(label="27.01-15.00.00.10-00.00.00.0.1", upd_version="15.00.00.00",
                    url=SYS_URL, size="1260600832") -> str:
    return f"""<?xml version="1.0" ?>
<update_data_list>
\t<region id="us">
\t\t<system_pup auto_update_version="00.00" label="{label}" sdk_version="x" upd_version="{upd_version}">
\t\t\t<update_data update_type="full">
\t\t\t\t<image size="{size}">{url}</image>
\t\t\t</update_data>
\t\t</system_pup>
\t</region>
</update_data_list>
"""


class TempReadmeMixin:
    def write_readme(self, text: str = MINI_README, *, crlf: bool = False) -> ps5fw.Readme:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "README.md"
        if crlf:
            text = text.replace("\n", "\r\n")
        with path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        return ps5fw.Readme(path)


class TestVersions(unittest.TestCase):
    def test_short_version_drops_the_fourth_component(self):
        self.assertEqual(ps5fw.parse_updatelist(make_updatelist()).version, "15.00.00")

    def test_short_version_of_a_padded_release(self):
        release = ps5fw.parse_updatelist(make_updatelist(upd_version="09.60.00.00"))
        self.assertEqual(release.version, "09.60.00")

    def test_major_keeps_the_zero_padding_used_by_section_headers(self):
        release = ps5fw.parse_updatelist(make_updatelist(upd_version="09.60.00.00"))
        self.assertEqual(release.major, "09")

    def test_major_of_a_two_digit_release(self):
        self.assertEqual(ps5fw.parse_updatelist(make_updatelist()).major, "15")


class TestUrlHelpers(unittest.TestCase):
    def test_build_date_comes_from_the_segment_after_image(self):
        self.assertEqual(ps5fw.url_build_date(SYS_URL), "2026_0909")

    def test_a_query_string_does_not_leak_into_the_build_date(self):
        self.assertNotIn("?", ps5fw.url_build_date(SYS_URL))

    def test_sha256_comes_from_the_sys_segment(self):
        self.assertEqual(
            ps5fw.url_sha256(SYS_URL),
            "1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc",
        )

    def test_sha256_comes_from_the_rec_segment(self):
        self.assertEqual(
            ps5fw.url_sha256(REC_URL),
            "7ec8dd8a6f518370422844d2c9d670316774d3dc9d52d78a676a3452ff63c556",
        )

    def test_an_update_url_is_recognised_as_sys(self):
        self.assertEqual(ps5fw.url_kind(SYS_URL), "sys")

    def test_a_recovery_url_is_recognised_as_rec(self):
        self.assertEqual(ps5fw.url_kind(REC_URL), "rec")

    def test_a_url_without_a_checksum_segment_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.url_sha256("http://example.invalid/PS5UPDATE.PUP")

    def test_a_url_without_an_image_segment_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.url_build_date("http://example.invalid/PS5UPDATE.PUP")


class TestSupportPage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = (REPO_ROOT / "tests" / "fixtures" / "support_page.html").read_text(encoding="utf-8")

    def test_every_pup_link_is_found(self):
        self.assertEqual(len(ps5fw.extract_pup_urls(self.page)), 4)

    def test_duplicate_links_are_collapsed(self):
        urls = ps5fw.extract_pup_urls(self.page)
        self.assertEqual(len(urls), len(set(urls)))

    def test_the_recovery_image_for_the_requested_build_is_returned(self):
        self.assertEqual(ps5fw.find_recovery_url(self.page, "2026_0909"), REC_URL)

    def test_an_older_builds_recovery_image_is_not_returned(self):
        self.assertNotIn("2026_0717", ps5fw.find_recovery_url(self.page, "2026_0909"))

    def test_an_unknown_build_date_yields_nothing(self):
        self.assertIsNone(ps5fw.find_recovery_url(self.page, "2099_0101"))

    def test_a_page_with_no_links_yields_nothing(self):
        self.assertIsNone(ps5fw.find_recovery_url("<html></html>", "2026_0909"))

    def test_a_malformed_link_does_not_abort_the_scan(self):
        page = '<a href="http://example.invalid/PS5UPDATE.PUP">junk</a>' + self.page
        self.assertEqual(ps5fw.find_recovery_url(page, "2026_0909"), REC_URL)


class TestParseUpdatelist(unittest.TestCase):
    def test_a_malformed_document_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.parse_updatelist("this is not an updatelist")

    def test_xml_without_a_system_pup_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.parse_updatelist("<update_data_list></update_data_list>")

    def test_xml_without_an_image_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.parse_updatelist(
                '<update_data_list><system_pup label="x" upd_version="15.00.00.00"/>'
                "</update_data_list>"
            )

    def test_a_system_pup_without_a_label_is_rejected(self):
        with self.assertRaises(ps5fw.ParseError):
            ps5fw.parse_updatelist(make_updatelist(label=""))

    def test_a_label_with_markup_characters_survives_as_text(self):
        # The updatelist comes off the network. An entity has to decode to
        # literal text, never to anything with meaning to a later step.
        release = ps5fw.parse_updatelist(make_updatelist(label="26.06 &amp; &lt;b&gt;x&lt;/b&gt;"))
        self.assertEqual(release.label, "26.06 & <b>x</b>")

    def test_a_missing_size_is_tolerated(self):
        self.assertIsNone(ps5fw.parse_updatelist(make_updatelist(size="")).sys_size)

    def test_whitespace_around_the_url_is_stripped(self):
        release = ps5fw.parse_updatelist(make_updatelist(url=f"\n\t  {SYS_URL}  \n"))
        self.assertEqual(release.sys_url, SYS_URL)


class TestAgainstCommittedData(unittest.TestCase):
    """Round trip every committed updatelist against the real README."""

    @classmethod
    def setUpClass(cls):
        cls.readme = ps5fw.Readme(README)

    def test_there_are_updatelists_to_check(self):
        self.assertGreaterEqual(len(UPDATELISTS), 17)

    def test_every_updatelist_round_trips(self):
        for path in UPDATELISTS:
            with self.subTest(updatelist=path.name):
                # updatelist.<build_date>.<short_version>.xml
                parts = path.name.split(".")
                expected_build_date, expected_version = parts[1], ".".join(parts[2:5])

                release = ps5fw.parse_updatelist(path.read_text(encoding="utf-8"))
                self.assertEqual(release.build_date, expected_build_date)
                self.assertEqual(release.version, expected_version)
                self.assertEqual(release.version, release.upd_version_full.rsplit(".", 1)[0])

                self.assertTrue(
                    self.readme.has_hash(release.sys_sha256),
                    f"{release.sys_sha256} is missing from README.md",
                )
                self.assertTrue(
                    self.readme.has_section(release.major),
                    f"README.md has no ### {release.major}.x section",
                )

                row = next(
                    line.rstrip("\r\n") for line in self.readme.lines
                    if release.sys_sha256 in line
                )
                md5 = row.split("|")[6].strip()
                self.assertEqual(
                    row,
                    ps5fw.format_row(
                        release.label, release.version, "sys", release.build_date,
                        release.sys_sha256, md5, release.sys_size,
                    ),
                )


class TestFormatRow(unittest.TestCase):
    """Re-render every README row the current template produced.

    This is what catches a change in the column padding.
    """

    ROW_RE = re.compile(r"^\| \d{2}\.\d{2}-[\d.]+-[\d.]+ \|.*\| \d+ B \|$")
    KINDS = {"\N{SQUARED UP WITH EXCLAMATION MARK} Update": "sys", "❤️‍\U0001fa79 Recovery": "rec"}

    def test_every_generated_row_round_trips(self):
        checked = 0
        for raw in ps5fw.Readme(README).lines:
            row = raw.rstrip("\r\n")
            if not self.ROW_RE.match(row):
                continue
            cells = [cell.strip() for cell in row.split("|")]
            kind = self.KINDS.get(cells[3])
            if kind is None:
                continue
            with self.subTest(row=cells[1] + " " + cells[3]):
                self.assertEqual(
                    row,
                    ps5fw.format_row(
                        cells[1], cells[2], kind, cells[4], cells[5], cells[6],
                        cells[7].removesuffix(" B"),
                    ),
                )
            checked += 1
        self.assertGreaterEqual(checked, 20, "expected to check a meaningful number of rows")

    def test_an_unknown_kind_is_rejected(self):
        with self.assertRaises(ValueError):
            ps5fw.format_row("x", "15.00.00", "nope", "2027_0210", "a" * 64, "b" * 32, 1)


class TestReadmeLookups(TempReadmeMixin, unittest.TestCase):
    def setUp(self):
        self.readme = self.write_readme()

    def test_an_existing_section_is_found(self):
        self.assertTrue(self.readme.has_section("14"))

    def test_a_missing_section_is_not_found(self):
        self.assertFalse(self.readme.has_section("15"))

    def test_a_section_is_not_matched_by_a_prefix(self):
        self.assertFalse(self.readme.has_section("1"))

    def test_an_existing_checksum_is_found(self):
        self.assertTrue(self.readme.has_hash("aaaa" + "0" * 59 + "1"))

    def test_checksum_lookup_ignores_case(self):
        self.assertTrue(self.readme.has_hash(("aaaa" + "0" * 59 + "1").upper()))

    def test_an_unknown_checksum_is_not_found(self):
        self.assertFalse(self.readme.has_hash("cccc" + "0" * 59 + "9"))

    def test_the_table_header_is_read_from_the_readme(self):
        self.assertEqual(self.readme.table_header(), HEADER)

    def test_the_table_separator_is_read_from_the_readme(self):
        self.assertEqual(self.readme.table_separator(), SEPARATOR)

    def test_an_unrelated_table_does_not_hijack_the_lookup(self):
        decoy = self.write_readme(
            MINI_README + "\n## Automation\n\n| Workflow | Trigger |\n| -------- | ------- |\n| tests | push |\n"
        )
        self.assertEqual(decoy.table_header(), HEADER)
        self.assertEqual(decoy.table_separator(), SEPARATOR)

    def test_the_fixture_columns_match_the_real_readme(self):
        real = ps5fw.Readme(README)
        self.assertEqual(HEADER, real.table_header())
        self.assertEqual(SEPARATOR, real.table_separator())

    def test_a_readme_without_a_table_falls_back(self):
        bare = self.write_readme("# nothing here\n")
        self.assertEqual(bare.table_header(), ps5fw.FALLBACK_TABLE_HEADER)
        self.assertEqual(bare.table_separator(), ps5fw.FALLBACK_TABLE_SEPARATOR)


class TestInsertRows(TempReadmeMixin, unittest.TestCase):
    NEW_ROW = ps5fw.format_row(
        "26.07-14.20.00.01-00.00.00.0.1", "14.20.00", "sys", "2026_1021",
        "dddd" + "0" * 59 + "1", "4444444444444444444444444444dddd", 1270000000,
    )
    SYS_15 = ps5fw.format_row(
        "27.01-15.00.00.10-00.00.00.0.1", "15.00.00", "sys", "2027_0210",
        "eeee" + "0" * 59 + "1", "5555555555555555555555555555eeee", 1300000000,
    )
    REC_15 = ps5fw.format_row(
        "27.01-15.00.00.10-00.00.00.0.1", "15.00.00", "rec", "2027_0210",
        "eeee" + "0" * 59 + "2", "6666666666666666666666666666eeee", 1450000000,
    )
    OLD_ROW = ps5fw.format_row(
        "22.01-05.00.00.01-00.00.00.0.0", "05.00.00", "sys", "2022_0101",
        "ffff" + "0" * 59 + "1", "7777777777777777777777777777ffff", 1000000000,
    )

    def sections(self, readme):
        return [line.rstrip("\r\n") for line in readme.lines if line.startswith("### ")]

    def section_body(self, readme, major):
        body, inside = [], False
        for raw in readme.lines:
            line = raw.rstrip("\r\n")
            if line == f"### {major}.x":
                inside = True
                continue
            if inside and line.startswith("#"):
                break
            if inside:
                body.append(line)
        return body

    # -- an existing section

    def test_a_row_lands_at_the_top_of_its_table(self):
        readme = self.write_readme()
        self.assertFalse(readme.insert_rows("14", [self.NEW_ROW]))
        self.assertEqual(self.section_body(readme, "14")[2], self.NEW_ROW)

    def test_no_new_section_is_created(self):
        readme = self.write_readme()
        readme.insert_rows("14", [self.NEW_ROW])
        self.assertEqual(self.sections(readme), ["### 14.x", "### 13.x"])

    def test_the_existing_rows_survive(self):
        readme = self.write_readme()
        readme.insert_rows("14", [self.NEW_ROW])
        self.assertTrue(readme.has_hash("aaaa" + "0" * 59 + "1"))

    def test_the_row_does_not_leak_into_another_section(self):
        readme = self.write_readme()
        readme.insert_rows("14", [self.NEW_ROW])
        self.assertNotIn(self.NEW_ROW, self.section_body(readme, "13"))

    def test_an_empty_set_of_rows_is_rejected(self):
        readme = self.write_readme()
        with self.assertRaises(ValueError):
            readme.insert_rows("14", [])

    def test_a_section_without_a_table_is_rejected(self):
        readme = self.write_readme("## The Full List\n\n### 14.x\n\nno table here\n")
        with self.assertRaises(ps5fw.ReadmeError):
            readme.insert_rows("14", [self.NEW_ROW])

    # -- a major version bump

    def test_a_new_major_creates_a_section(self):
        readme = self.write_readme()
        self.assertTrue(readme.insert_rows("15", [self.SYS_15, self.REC_15]))
        self.assertTrue(readme.has_section("15"))

    def test_the_new_section_goes_first(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.SYS_15, self.REC_15])
        self.assertEqual(self.sections(readme), ["### 15.x", "### 14.x", "### 13.x"])

    def test_the_new_section_carries_the_table_head(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.SYS_15, self.REC_15])
        self.assertEqual(self.section_body(readme, "15")[:2], [HEADER, SEPARATOR])

    def test_both_rows_land_in_order_update_first(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.SYS_15, self.REC_15])
        self.assertEqual(self.section_body(readme, "15")[2:4], [self.SYS_15, self.REC_15])

    def test_the_new_section_is_followed_by_a_blank_line(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.SYS_15, self.REC_15])
        self.assertEqual(self.section_body(readme, "15")[-1], "")

    def test_the_previous_section_is_intact(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.SYS_15, self.REC_15])
        self.assertTrue(readme.has_hash("aaaa" + "0" * 59 + "2"))

    # -- an older major

    def test_an_older_major_goes_last(self):
        readme = self.write_readme()
        readme.insert_rows("05", [self.OLD_ROW])
        self.assertEqual(self.sections(readme), ["### 14.x", "### 13.x", "### 05.x"])

    def test_an_older_major_stays_ahead_of_the_next_heading(self):
        readme = self.write_readme()
        readme.insert_rows("05", [self.OLD_ROW])
        headings = [line.rstrip("\r\n") for line in readme.lines if line.startswith("#")]
        self.assertLess(headings.index("### 05.x"), headings.index("## Contribution Guide"))

    def test_a_list_running_to_the_end_of_the_file_appends(self):
        text = MINI_README.split("## Contribution Guide")[0].rstrip("\n") + "\n"
        readme = self.write_readme(text)
        readme.insert_rows("05", [self.OLD_ROW])
        self.assertEqual(self.sections(readme)[-1], "### 05.x")
        self.assertTrue(readme.has_hash("ffff" + "0" * 59 + "1"))

    def test_a_file_without_a_trailing_newline_still_appends_cleanly(self):
        text = MINI_README.split("## Contribution Guide")[0].rstrip("\n")
        readme = self.write_readme(text)
        readme.insert_rows("05", [self.OLD_ROW])
        self.assertIn(self.OLD_ROW, [line.rstrip("\r\n") for line in readme.lines])
        self.assertNotIn(self.OLD_ROW + "###", readme.text)

    # -- backfilling

    def test_a_recovery_row_lands_below_its_update_row(self):
        readme = self.write_readme()
        anchor = "bbbb" + "0" * 59 + "1"
        backfill = ps5fw.format_row(
            "26.05-13.60.00.07-00.00.00.0.1", "13.60.00", "rec", "2026_0717",
            "bbbb" + "0" * 59 + "2", "8888888888888888888888888888bbbb", 1404953088,
        )
        readme.insert_after_hash(anchor, [backfill])
        body = self.section_body(readme, "13")
        self.assertEqual(body[body.index(backfill) - 1].split("|")[5].strip(), anchor)

    def test_backfilling_against_an_unknown_checksum_fails(self):
        readme = self.write_readme()
        with self.assertRaises(ps5fw.ReadmeError):
            readme.insert_after_hash("0" * 64, [self.NEW_ROW])

    def test_backfilling_an_empty_set_of_rows_is_rejected(self):
        readme = self.write_readme()
        with self.assertRaises(ValueError):
            readme.insert_after_hash("bbbb" + "0" * 59 + "1", [])


class TestLineEndings(TempReadmeMixin, unittest.TestCase):
    """README.md is CRLF; an inserted row must not turn that into a whole-file diff."""

    ROW = TestInsertRows.SYS_15

    def test_the_real_readme_is_crlf(self):
        self.assertEqual(ps5fw.Readme(README).eol, "\r\n")

    def test_a_crlf_readme_stays_crlf_when_inserting_a_section(self):
        readme = self.write_readme(crlf=True)
        readme.insert_rows("15", [self.ROW])
        self.assertTrue(all(line.endswith("\r\n") for line in readme.lines))

    def test_a_crlf_readme_stays_crlf_when_inserting_a_row(self):
        readme = self.write_readme(crlf=True)
        readme.insert_rows("14", [self.ROW])
        self.assertTrue(all(line.endswith("\r\n") for line in readme.lines))

    def test_a_crlf_readme_stays_crlf_when_backfilling(self):
        readme = self.write_readme(crlf=True)
        readme.insert_after_hash("bbbb" + "0" * 59 + "1", [self.ROW])
        self.assertTrue(all(line.endswith("\r\n") for line in readme.lines))

    def test_no_row_picks_up_a_doubled_carriage_return(self):
        readme = self.write_readme(crlf=True)
        readme.insert_rows("15", [self.ROW])
        self.assertNotIn("\r\r", readme.text)

    def test_an_lf_readme_stays_lf(self):
        readme = self.write_readme()
        readme.insert_rows("15", [self.ROW])
        self.assertNotIn("\r", readme.text)

    def test_saving_preserves_the_bytes_exactly(self):
        readme = self.write_readme(crlf=True)
        before = readme.path.read_bytes()
        readme.save()
        self.assertEqual(readme.path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
