"""Disposable-schema checks for the Mac history exporter; never read Apple data."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


class HistoryExportTests(unittest.TestCase):
    def test_source_six_defaults_and_marked_flags_have_truthful_evidence(self):
        script = Path(__file__).resolve().parents[1] / "Tools/ApplePodcastsExport/export-history.sh"
        with tempfile.TemporaryDirectory(prefix="HistoryExportTests-") as folder:
            source = Path(folder) / "copy.sqlite"
            output = Path(folder) / "export.json"
            with sqlite3.connect(source) as db:
                db.executescript("""
                    CREATE TABLE ZMTPODCAST (Z_PK INTEGER PRIMARY KEY, ZUPDATEDFEEDURL TEXT,
                        ZFEEDURL TEXT, ZTITLE TEXT, ZSUBSCRIBED INTEGER);
                    CREATE TABLE ZMTEPISODE (ZPODCAST INTEGER, ZGUID TEXT, ZTITLE TEXT,
                        ZPLAYSTATE INTEGER, ZPLAYCOUNT INTEGER, ZLASTUSERMARKEDASPLAYEDDATE REAL,
                        ZLASTDATEPLAYED REAL, ZPLAYSTATESOURCE INTEGER, ZPLAYHEAD REAL,
                        ZPUBDATE REAL, ZSAVED INTEGER);
                    INSERT INTO ZMTPODCAST VALUES (1, NULL, 'https://example.invalid/Show.xml', 'Show', 1);
                """)
                db.executemany("INSERT INTO ZMTEPISODE VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, 100, 0)", [
                    ("default", "Default", 0, 0, None, 1000, 6, 0),
                    ("zero", "Zero dates", 0, 0, 0, 0, 1, 0),
                    ("marked", "Marked", 0, 0, 1200, 1000, 6, 0),
                    ("counted", "Counted", 0, 2, None, 1300, 6, 0),
                    ("partial", "Partial", 1, 0, None, 1400, 6, 35),
                    ("unfinished", "Unfinished default", 1, 0, None, 1500, 6, 0),
                ])
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            environment = dict(os.environ, PODSKIPPER_HISTORY_DATABASE=str(source))
            result = subprocess.run(["/bin/zsh", str(script), str(output)], env=environment,
                                    check=True, text=True, capture_output=True)
            archive = json.loads(output.read_text())
            self.assertEqual(archive["version"], 3)
            self.assertEqual(archive["format"], "podskipper-apple-podcasts-history")
            rows = {row["guid"]: row for row in archive["episodes"]}
            for guid in ("default", "zero", "unfinished"):
                self.assertEqual(rows[guid]["played"], 0)
                self.assertIsNone(rows[guid]["lastPlayed"])
            self.assertEqual(rows["marked"]["played"], 1)
            self.assertIsNone(rows["marked"]["lastPlayed"])
            self.assertEqual(rows["marked"]["lastUserMarkedPlayed"], 978307200 + 1200)
            self.assertEqual(rows["counted"]["played"], 1)
            self.assertEqual(rows["counted"]["lastPlayed"], 978307200 + 1300)
            self.assertEqual(rows["counted"]["playCount"], 2)
            self.assertEqual(rows["partial"]["playhead"], 35)
            self.assertEqual(rows["partial"]["lastPlayed"], 978307200 + 1400)
            self.assertEqual(rows["default"]["playStateSource"], 6)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)
            self.assertIn("2 played episodes, 1 in progress", result.stdout)


if __name__ == "__main__":
    unittest.main()
