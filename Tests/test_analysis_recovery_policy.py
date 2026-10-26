"""Static product wiring guard; the executable Swift seam probe is separate."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parent.parent

class AnalysisRecoveryPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'Shared/AudioPipeline.swift').read_text()

    def test_boundary_does_not_charge_failure_budget(self):
        s = self.source
        self.assertIn('reason: .sourceBoundary', s)
        self.assertIn('reason == .failure {', s)
        self.assertIn('analysisRecoveryAttempts += 1', s)
        self.assertEqual(s.count('analysisRecoveryAttempts += 1'), 1)
        self.assertIn('maxAnalysisRecoveryAttempts = 2', s)

    def test_native_errors_are_classified_as_failures(self):
        s = self.source
        for message in ('화자 분석 오류', '화자 분석 큐 초과', '화자 분석 입력 종료'):
            self.assertIn('requestAnalysisRecovery("' + message, s)
        self.assertEqual(s.count('reason: .failure)'), 3)

    def test_pending_supersession_and_eof_are_bounded(self):
        s = self.source
        self.assertIn('analysisRecoveryToken == token', s)
        self.assertIn('if analysisRecoveryPending != nil', s)
        self.assertIn('recoveryDeadline = ProcessInfo.processInfo.systemUptime + maxAnalysisWait', s)
        self.assertIn('while let recovery = analysisRecoveryTask', s)
        self.assertIn('analysisRecoveryToken = nil', s)

    def test_shared_and_phase1_have_same_source(self):
        mirror = (ROOT/'Phase1/JPLive.swiftpm/Sources/AudioPipeline.swift').read_text()
        self.assertEqual(self.source, mirror)

if __name__ == '__main__': unittest.main()
