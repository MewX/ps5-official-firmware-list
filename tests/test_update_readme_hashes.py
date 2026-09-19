"""End to end tests for update_readme_hashes.py.

The script's three inputs - the updatelist, the support page and the firmware
images - are all fetched by URL, so these tests point them at file:// fixtures
built in a temp directory. That exercises the real fetch, streaming hash,
verification and README editing code paths in a few milliseconds, with no
network access and without downloading gigabytes of firmware.
"""

from __future__ import annotations

import hashlib
import io
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import ps5fw
import update_readme_hashes

REPO_ROOT = Path(__file__).resolve().parent.parent
REAL_README = REPO_ROOT / "README.md"

LABEL_15 = "27.01-15.00.00.10-00.00.00.0.1"
LABEL_14_20 = "26.07-14.20.00.01-00.00.00.0.1"
SYS_BODY = b"fake PS5 update image"
REC_BODY = b"fake PS5 recovery image"


def sha_of(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def md5_of(body: bytes) -> str:
    return hashlib.md5(body).hexdigest()


class Case:
    """One test case's fixture tree, served over file:// URLs."""

    def __init__(self, directory: Path):
        self.dir = directory
        self.readme = directory / "README.md"
        shutil.copyfile(REAL_README, self.readme)
        self.summary = directory / "summary.md"
        self.outputs = directory / "outputs.txt"

    def publish(self, build_date: str, kind: str, body: bytes, *, dir_hash: str | None = None) -> str:
        """Lay out a firmware image the way Sony does: the directory is named
        after the sha256 of the file it holds. Returns the URL."""
        name = f"{kind}_{dir_hash or sha_of(body)}"
        target = self.dir / "update" / "ps5" / "official" / "OBF" / "image" / build_date / name
        target.mkdir(parents=True, exist_ok=True)
        (target / "PS5UPDATE.PUP").write_bytes(body)
        return (target / "PS5UPDATE.PUP").as_uri()

    def updatelist(self, label: str, upd_version: str, url: str, size: int | str) -> str:
        path = self.dir / "updatelist.xml"
        path.write_text(
            '<?xml version="1.0" ?>\n'
            "<update_data_list><region id=\"us\">\n"
            f'<system_pup auto_update_version="00.00" label="{label}" '
            f'sdk_version="x" upd_version="{upd_version}">\n'
            f'<update_data update_type="full"><image size="{size}">{url}</image></update_data>\n'
            "</system_pup></region></update_data_list>\n",
            encoding="utf-8",
        )
        return path.as_uri()

    def support_page(self, *urls: str) -> str:
        path = self.dir / "support.html"
        links = "".join(f'<a href="{url}">download</a>\n' for url in urls)
        path.write_text(f"<html><body>\n{links}</body></html>\n", encoding="utf-8")
        return path.as_uri()

    def missing_url(self) -> str:
        return (self.dir / "definitely-missing.html").as_uri()


class Result:
    def __init__(self, status: int, output: str, case: Case):
        self.status = status
        self.output = output
        self.case = case

    @property
    def outputs(self) -> dict[str, str]:
        if not self.case.outputs.exists():
            return {}
        pairs = (
            line.split("=", 1)
            for line in self.case.outputs.read_text(encoding="utf-8").splitlines()
            if "=" in line
        )
        return dict(pairs)

    @property
    def readme_text(self) -> str:
        return ps5fw.read_raw(self.case.readme)

    @property
    def summary(self) -> str:
        return self.case.summary.read_text(encoding="utf-8") if self.case.summary.exists() else ""


class UpdaterTestCase(unittest.TestCase):
    def new_case(self) -> Case:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Case(Path(directory.name))

    def run_updater(self, case: Case, updatelist_url: str, support_url: str) -> Result:
        argv = [
            "--updatelist-url", updatelist_url,
            "--support-url", support_url,
            "--readme", str(case.readme),
            "--summary-file", str(case.summary),
            "--retries", "0",
            "--retry-delay", "0",
        ]
        previous = os.environ.get("GITHUB_OUTPUT")
        os.environ["GITHUB_OUTPUT"] = str(case.outputs)
        stream = io.StringIO()
        try:
            with redirect_stdout(stream), redirect_stderr(stream):
                try:
                    status = update_readme_hashes.main(argv)
                except ps5fw.Ps5fwError as error:
                    print(f"ERROR: {error}")
                    status = 1
        finally:
            if previous is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = previous
        return Result(status, stream.getvalue(), case)


class TestMajorVersionBump(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2027_0210", "sys", SYS_BODY)
        rec_url = self.case.publish("2027_0210", "rec", REC_BODY)
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY)),
            self.case.support_page(sys_url, rec_url),
        )

    def test_it_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_it_reports_the_change(self):
        self.assertEqual(self.result.outputs["changed"], "true")
        self.assertEqual(self.result.outputs["version"], "15.00.00")
        self.assertEqual(self.result.outputs["build_date"], "2027_0210")
        self.assertEqual(self.result.outputs["new_section"], "true")

    def test_a_new_section_is_first(self):
        sections = [line for line in self.result.readme_text.splitlines() if line.startswith("### ")]
        self.assertEqual(sections[:2], ["### 15.x", "### 14.x"])

    def test_the_rows_carry_the_real_digests(self):
        for body in (SYS_BODY, REC_BODY):
            self.assertIn(sha_of(body), self.result.readme_text)
            self.assertIn(md5_of(body), self.result.readme_text)

    def test_the_update_row_comes_before_the_recovery_row(self):
        text = self.result.readme_text
        self.assertLess(text.index(sha_of(SYS_BODY)), text.index(sha_of(REC_BODY)))

    def test_the_rows_match_the_house_format(self):
        self.assertIn(
            ps5fw.format_row(LABEL_15, "15.00.00", "sys", "2027_0210",
                             sha_of(SYS_BODY), md5_of(SYS_BODY), len(SYS_BODY)),
            self.result.readme_text,
        )

    def test_crlf_is_preserved(self):
        lines = self.result.readme_text.split("\n")[:-1]
        self.assertTrue(all(line.endswith("\r") for line in lines))

    def test_only_the_new_section_was_added(self):
        before = ps5fw.read_raw(REAL_README).splitlines()
        after = self.result.readme_text.splitlines()
        self.assertEqual(len(after) - len(before), 6)
        start = after.index("### 15.x")
        # Taking the six inserted lines back out must reproduce the file exactly.
        self.assertEqual(after[:start] + after[start + 6:], before)

    def test_the_summary_describes_the_release(self):
        self.assertIn(LABEL_15, self.result.summary)
        self.assertIn("new `### 15.x` section", self.result.summary)


class TestIdempotence(UpdaterTestCase):
    def test_a_second_run_changes_nothing(self):
        case = self.new_case()
        sys_url = case.publish("2027_0210", "sys", SYS_BODY)
        rec_url = case.publish("2027_0210", "rec", REC_BODY)
        updatelist = case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY))
        support = case.support_page(sys_url, rec_url)

        first = self.run_updater(case, updatelist, support)
        self.assertEqual(first.status, 0, first.output)
        after_first = case.readme.read_bytes()

        second = self.run_updater(case, updatelist, support)
        self.assertEqual(second.status, 0, second.output)
        self.assertEqual(second.outputs["changed"], "false")
        self.assertEqual(case.readme.read_bytes(), after_first)
        self.assertIn("already lists", second.output)


class TestMinorRelease(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2026_1021", "sys", SYS_BODY)
        rec_url = self.case.publish("2026_1021", "rec", REC_BODY)
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_14_20, "14.20.00.00", sys_url, len(SYS_BODY)),
            self.case.support_page(sys_url, rec_url),
        )

    def test_it_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_no_new_section_was_created(self):
        self.assertEqual(self.result.outputs["new_section"], "false")
        before = REAL_README.read_text(encoding="utf-8").count("\n### ")
        self.assertEqual(self.result.readme_text.count("\n### "), before)

    def test_the_rows_go_to_the_top_of_the_existing_table(self):
        lines = self.result.readme_text.splitlines()
        start = lines.index("### 14.x")
        separator = next(i for i in range(start, len(lines)) if lines[i].startswith("| ---"))
        self.assertIn(sha_of(SYS_BODY), lines[separator + 1])

    def test_the_previous_release_is_still_listed(self):
        self.assertIn("1eb4b18451e0f064fc23b5bd4c95cae7f6489f9ad1148b5dfb0d66452a108ebc",
                      self.result.readme_text)


class TestCorruptedDownload(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        # The directory is named after a different checksum than the file it
        # holds, which is what a truncated or tampered download looks like.
        sys_url = self.case.publish("2027_0210", "sys", b"totally different bytes",
                                    dir_hash=sha_of(SYS_BODY))
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY)),
            self.case.support_page(sys_url),
        )

    def test_it_fails(self):
        self.assertNotEqual(self.result.status, 0)

    def test_it_explains_the_mismatch(self):
        self.assertIn("but its URL claims", self.result.output)

    def test_the_readme_is_untouched(self):
        self.assertEqual(self.result.readme_text,
                         ps5fw.read_raw(REAL_README))

    def test_it_did_not_claim_a_change(self):
        self.assertNotEqual(self.result.outputs.get("changed"), "true")


class TestMissingRecovery(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2027_0210", "sys", SYS_BODY)
        # The page still advertises the previous release's recovery image.
        stale = self.case.publish("2026_0909", "rec", b"older recovery image")
        self.stale_sha = sha_of(b"older recovery image")
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY)),
            self.case.support_page(sys_url, stale),
        )

    def test_it_still_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_it_warns(self):
        self.assertIn("no recovery image for build 2027_0210", self.result.output)

    def test_the_update_row_was_added(self):
        self.assertIn(sha_of(SYS_BODY), self.result.readme_text)

    def test_the_stale_recovery_image_was_not_used(self):
        self.assertNotIn(self.stale_sha, self.result.readme_text)

    def test_the_summary_flags_it(self):
        self.assertIn("needs to be filled in", self.result.summary)


class TestUnreachableSupportPage(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2027_0210", "sys", SYS_BODY)
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY)),
            self.case.missing_url(),
        )

    def test_it_still_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_it_warns(self):
        self.assertIn("could not fetch the support page", self.result.output)

    def test_the_update_row_was_still_added(self):
        self.assertIn(sha_of(SYS_BODY), self.result.readme_text)


class TestRecoveryBackfill(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2027_0210", "sys", SYS_BODY)
        rec_url = self.case.publish("2027_0210", "rec", REC_BODY)
        updatelist = self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, len(SYS_BODY))
        # First run without the recovery link, then again once it shows up.
        self.run_updater(self.case, updatelist, self.case.support_page(sys_url))
        self.result = self.run_updater(self.case, updatelist, self.case.support_page(sys_url, rec_url))

    def test_it_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_it_reports_a_change(self):
        self.assertEqual(self.result.outputs["changed"], "true")

    def test_it_says_it_is_backfilling(self):
        self.assertIn("Backfilling the recovery row", self.result.output)

    def test_the_recovery_row_sits_below_its_update_row(self):
        lines = self.result.readme_text.splitlines()
        index = next(i for i, line in enumerate(lines) if sha_of(SYS_BODY) in line)
        self.assertIn(sha_of(REC_BODY), lines[index + 1])

    def test_no_duplicate_section_was_created(self):
        self.assertEqual(self.result.readme_text.count("### 15.x"), 1)


class TestSizeMismatch(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        sys_url = self.case.publish("2027_0210", "sys", SYS_BODY)
        self.result = self.run_updater(
            self.case,
            self.case.updatelist(LABEL_15, "15.00.00.00", sys_url, 999999999),
            self.case.support_page(sys_url),
        )

    def test_it_succeeds(self):
        self.assertEqual(self.result.status, 0, self.result.output)

    def test_it_warns(self):
        self.assertIn("updatelist.xml says 999999999 B", self.result.output)

    def test_the_row_records_the_real_size(self):
        self.assertIn(f"| {len(SYS_BODY)} B |", self.result.readme_text)


class TestBrokenUpdatelist(UpdaterTestCase):
    def setUp(self):
        self.case = self.new_case()
        (self.case.dir / "updatelist.xml").write_text("<html>404</html>", encoding="utf-8")
        self.result = self.run_updater(
            self.case,
            (self.case.dir / "updatelist.xml").as_uri(),
            self.case.support_page(),
        )

    def test_it_fails(self):
        self.assertNotEqual(self.result.status, 0)

    def test_the_readme_is_untouched(self):
        self.assertEqual(self.result.readme_text,
                         ps5fw.read_raw(REAL_README))


class TestUnreachableUpdatelist(UpdaterTestCase):
    def test_it_fails(self):
        case = self.new_case()
        result = self.run_updater(case, case.missing_url(), case.support_page())
        self.assertNotEqual(result.status, 0)
        self.assertIn("could not fetch", result.output)


if __name__ == "__main__":
    unittest.main()
