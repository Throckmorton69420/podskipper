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

    def test_cleanup_selects_signed_and_unsigned_independently(self):
        source = (ROOT / "feather_global_v3/LibraryView.swift").read_text()
        body = self.section("feather_global_v3/LibraryView.swift", "private func _applyOlderDownloadPolicies", "private func _enqueueCleanupPrompt")
        self.assertIn("_unsignedCleanupPolicy", body)
        self.assertIn("_signedCleanupPolicy", body)
        self.assertIn("_importedApps", body)
        self.assertIn("_signedApps", body)
        self.assertIn("removeOlderLibraryCopies", body)
        self.assertIn("OlderUnsignedPolicy", source)
        self.assertIn("OlderSignedPolicy", source)

    def test_cleanup_deletion_is_exact_and_off_main(self):
        body = self.section("feather_global_v3/UpdateManager.swift", "func removeOlderLibraryCopies", "private func _isUpdateDismissed")
        self.assertIn("expectedDirectory.standardizedFileURL", body)
        self.assertIn("_fingerprintLane.run", body)
        self.assertLess(body.index("FileManager.default.removeItem"), body.index("Storage.shared.context.delete"))

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

    def test_install_after_sign_uses_exact_signed_uuid(self):
        patch = (ROOT / "feather_global_v9/SigningView.patch").read_text()
        added = "\n".join(
            line[1:] for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        self.assertIn("signPackageFileReturningUUID", patch)
        self.assertIn('Notification.Name("Feather.Signing.InstallRequested")', patch)
        self.assertIn("object: signedUUID", patch)
        self.assertNotIn('Notification.Name("Feather.installApp")', added)
        library = (ROOT / "feather_global_v3/LibraryView.swift").read_text()
        listener = self.section("feather_global_v3/LibraryView.swift", 'Notification.Name("Feather.Signing.InstallRequested")', 'Notification.Name("Feather.GlobalUpdater.InstallFinished")')
        self.assertIn("_waitForSignedCopy(uuid: uuid)", listener)
        self.assertIn("_enqueueInstall(signed)", listener)
        self.assertNotIn("_signedApps.first", listener)
        self.assertNotIn('Notification.Name("Feather.installApp")', library)

    def test_terminal_install_success_unlocks_selected_cleanup(self):
        source = (ROOT / "feather_global_v2/InstallPreviewView.swift").read_text()
        completed = source.split("case .completed:", 1)[1].split("case .broken", 1)[0]
        self.assertIn("confirmedForSignedCleanup: true", completed)
        self.assertNotIn("_installationMethod == 1", completed)

    def test_validation_short_circuits_if_original_cannot_be_scanned(self):
        body = self.section("feather_global_v3/UpdateManager.swift", "func validateDownloadedUpdate", "let originalVariant =")
        self.assertIn("guard\n\t\t\tlet originalFingerprint = await _backgroundFingerprint", body)
        self.assertNotIn("async let", body)
        self.assertIn("thermal != .serious, thermal != .critical", body)


if __name__ == "__main__":
    unittest.main()
