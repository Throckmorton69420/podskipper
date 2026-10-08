"""Structural guards for paths that cannot run in the macOS policy harness."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class RegressionInvariants(unittest.TestCase):
    def section(self, file, begin, end):
        source = (ROOT / file).read_text()
        return source.split(begin, 1)[1].split(end, 1)[0]

    def test_row_has_no_filesystem_or_source_fetch(self):
        body = self.section("feather_global_v3/LibraryCellView.swift", "private var _desc:", "private func _candidateButtonTitle")
        for forbidden in ("Storage.shared", "FileManager", "_fingerprintJobInput", "binaryValidationDetail"):
            self.assertNotIn(forbidden, body)

    def test_scan_status_never_prepares_a_job(self):
        body = self.section("feather_global_v3/UpdateManager.swift", "func fingerprintDate(", "var visibleUpdates:")
        for forbidden in ("_fingerprintJobInput", "_cheapContentStamp", "JSONDecoder", "Storage.shared", "FileManager"):
            self.assertNotIn(forbidden, body)

    def test_checks_do_not_launch_full_scans(self):
        body = self.section("feather_global_v3/LibraryView.swift", "private func _checkForUpdates()", "private func _automaticallyCheckForUpdatesIfNeeded")
        self.assertNotIn("startFingerprintLibrary", body)
        self.assertNotIn("AutoFingerprint", (ROOT / "feather_global_v5/SettingsView.swift").read_text())

    def test_only_lane_calls_fingerprint_compute(self):
        source = (ROOT / "feather_global_v3/UpdateManager.swift").read_text()
        self.assertEqual(source.count("FingerprintWorker.compute("), 1)
        body = self.section("feather_global_v3/UpdateManager.swift", "private func _runFingerprint", "func cachedFingerprintCount")
        self.assertIn("_fingerprintLane.run", body)
        self.assertIn("epoch == _cacheEpoch", body)
        self.assertNotIn("schemaVersion == 6", source)
        self.assertNotIn("func _binaryFingerprint", source)

    def test_cleanup_cannot_select_signed_copies(self):
        body = self.section("feather_global_v3/LibraryView.swift", "private func _olderCopyUUIDs", "private func _enqueueCleanupPrompt")
        self.assertNotIn("_signedApps", body)
        self.assertNotIn("includeSigned", body)
        self.assertIn("removeOlderUnsigned", body)

    def test_progress_is_throttled_before_main_dispatch(self):
        body = self.section("feather_global_v6/DownloadManager.swift", "didWriteData bytesWritten:", "didCompleteWithError")
        self.assertLess(body.index("shouldPublish"), body.index("DispatchQueue.main.async"))

    def test_metadata_crosses_as_value_snapshot(self):
        body = self.section("feather_global_v3/UpdateManager.swift", "private func _variantEvidence", "private func _rememberLocalEvidence")
        self.assertIn("VariantMetadataInput", body)
        self.assertIn("Task.detached(priority: .utility)", body)
        self.assertIn("VariantMetadataParser.parse(input)", body)

    def test_manual_update_actions_cannot_bypass_pipeline(self):
        body = self.section("feather_global_v3/LibraryCellView.swift", "private func _startUpdateDownload", "private func _cancelUpdateDownload")
        self.assertIn("Feather.GlobalUpdater.QueueUpdate", body)
        self.assertNotIn("startDownload(", body)
        pump = self.section("feather_global_v3/LibraryView.swift", "private func _pumpUpdateDownloadQueue", "private func _handleUpdateCheckStateChange")
        for gate in ("_activeVerifications == 0", "_autoSignQueue.isEmpty", "_activeInstallUUID == nil"):
            self.assertIn(gate, pump)

    def test_validation_short_circuits_if_original_cannot_be_scanned(self):
        body = self.section("feather_global_v3/UpdateManager.swift", "func validateDownloadedUpdate", "let originalVariant =")
        self.assertIn("guard\n\t\t\tlet originalFingerprint = await _backgroundFingerprint", body)
        self.assertNotIn("async let", body)
        self.assertIn("thermal != .serious, thermal != .critical", body)


if __name__ == "__main__":
    unittest.main()
