"""R5E source/document contract tests; NOT Apple SDK or native behavior tests."""
from pathlib import Path
from hashlib import sha256
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class R5EGuardTests(unittest.TestCase):
    def test_history_is_byte_exact_and_old_root_copies_are_gone(self):
        data = (ROOT/'Docs/CHANGE_HISTORY.md').read_bytes()
        rows = re.findall(rb'^\| `(JP_Live_(?:CHAT_CHANGE_LEDGER|REPAIR_)[^`]+\.md)` \| (\d+) \| `([a-f0-9]{64})` \|$',data,re.M)
        self.assertEqual(len(rows),9)
        for name, size, digest in rows:
            name=name.decode(); count=int(size)
            marker=f'\n## Begin original: `{name}` ({count} bytes)\n\n'.encode()
            start=data.index(marker)+len(marker)
            self.assertEqual(sha256(data[start:start+count]).hexdigest().encode(),digest)
            self.assertFalse((ROOT/name).exists())

    def test_current_doc_links_and_source_mirrors(self):
        for name in ('CHANGE_HISTORY.md','NATIVE_STOP_AUDIT.md','REPOSITORY_AUDIT.md'):
            self.assertTrue((ROOT/'Docs'/name).exists())
        for p in (ROOT/'Shared').glob('*.swift'):
            self.assertEqual(p.read_bytes(),(ROOT/'Phase1/JPLive.swiftpm/Sources'/p.name).read_bytes())

    def test_stop_error_source_guards(self):
        audio=(ROOT/'Shared/Audio.swift').read_text()
        phase2=(ROOT/'Phase2/SystemAudioInput.swift').read_text()
        app=(ROOT/'Shared/AppModel.swift').read_text()
        self.assertIn('var stopFailure: String? { get }', audio)
        self.assertIn('catch {\n                // The ledger deliberately keeps the unconfirmed SCStream.',phase2)
        self.assertIn('stopFailure = "시스템 오디오 캡처 종료를 확인하지 못했습니다.',phase2)
        self.assertIn('await stopFlight.run { [self] in await stopOnce() }',phase2)
        self.assertIn('guard !stopFlight.hasStarted else',phase2)
        self.assertIn('let nativeStopFailure = newInput.stopFailure',app)
        self.assertIn('if let nativeStopFailure { status = nativeStopFailure }',app)
        self.assertIn('&& nativeStopFailure == nil',app)

if __name__ == '__main__':
    unittest.main()
