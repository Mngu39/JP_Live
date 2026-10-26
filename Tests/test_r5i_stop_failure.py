"""R5I source-path and portable policy checks, not Apple SDK/native Stop tests."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Phase2' / 'DeviceValidation.swift'


def native_stop_method():
    text = SOURCE.read_text()
    begin = text.index('    func recordNativeStopFailure(_ failure: String?) {')
    opening = text.index('{', begin)
    depth = 0
    for i in range(opening, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[begin:i+1]
    raise AssertionError('Unclosed production method')


class R5INativeStopReporting(unittest.TestCase):
    def test_actual_validation_completion_records_stop_before_finish(self):
        source = SOURCE.read_text()
        run = source.split('    private func run(language: SourceLanguage) async {', 1)[1]
        completion = run.split('        await liveAnalysisPreparation.cancel()', 1)[1]
        stop = completion.index('        await input.stop()')
        recorded = completion.index('        metrics.recordNativeStopFailure(input.stopFailure)')
        finalized = completion.index('        let report = metrics.finish(userStopped: stopRequested)')
        self.assertLess(stop, recorded)
        self.assertLess(recorded, finalized)
        self.assertIn('errors.isEmpty ? .pass : .fail', source)
        self.assertIn('errors: errors', source)
        ordinary = (ROOT/'Shared/AppModel.swift').read_text()
        self.assertIn('let nativeStopFailure = newInput.stopFailure', ordinary)

    def test_stop_recording_is_idempotent_and_filters_empty_input(self):
        swiftc = shutil.which('swiftc')
        if not swiftc:
            self.skipTest('Swift compiler not available; XCTest included separately')
        # Compiles the **actual R5I production method body** inside a minimal
        # Foundation-backed shell, avoiding unavailable Apple-only frameworks.
        snippet = native_stop_method()
        source = '''import Foundation
final class MockMetrics {
    private(set) var errors = [String]()
    func recordError(_ value: String) {
        guard !value.isEmpty, !errors.contains(value) else { return }
        errors.append(value)
    }
''' + snippet + '''
}
let m = MockMetrics()
m.recordNativeStopFailure(nil)
m.recordNativeStopFailure("")
m.recordNativeStopFailure("  \\n  ")
precondition(m.errors.isEmpty)
m.recordNativeStopFailure("SCStream.stopCapture failed")
m.recordNativeStopFailure("SCStream.stopCapture failed")
precondition(m.errors == ["네이티브 종료 확인 실패: SCStream.stopCapture failed"])
precondition(!m.errors.isEmpty)
print("R5I production stop-error method: 6 assertions PASS")
'''
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp)/'main.swift'
            out = Path(tmp)/'probe'
            file.write_text(source)
            compile_result = subprocess.run([swiftc, '-swift-version', '6', '-warnings-as-errors', str(file), '-o', str(out)], capture_output=True, text=True, timeout=45)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            execution = subprocess.run([str(out)], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn('assertions PASS', execution.stdout)

    def test_apple_xctest_checks_report_fail_after_injected_stop_error(self):
        tests = (ROOT/'Tests/CoreTests.swift').read_text()
        case = tests.split('func testR5IDeviceValidationNativeStopFailureCannotPassSession() {', 1)[1].split('\n    @MainActor',1)[0]
        self.assertIn('metrics.recordNativeStopFailure(stopError)',case)
        self.assertIn('XCTAssertEqual(failed.verdict, .fail)',case)
        self.assertIn('$0.name == "runtime_errors" && $0.verdict == .fail',case)


if __name__ == '__main__':
    unittest.main()
