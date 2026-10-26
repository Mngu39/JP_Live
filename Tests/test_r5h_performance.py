"""Structural checks only; actual selector behavior is exercised by Swift tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class R5HPerformanceGuards(unittest.TestCase):
    def test_production_uses_bounded_selector(self):
        text = (ROOT / "Shared/AppModel.swift").read_text()
        region = text.split("private func refreshSpeakerPresentation() {",1)[1].split("private func recordPrimarySpeech",1)[0]
        self.assertIn("transcript.recentFinalSpeakerRowIndices", region)
        self.assertNotIn("transcript.rows.indices.filter", region)
    def test_selector_is_reverse_bounded_and_order_restored(self):
        text = (ROOT / "Shared/TranscriptBuffer.swift").read_text()
        part = text.split("func recentFinalSpeakerRowIndices(",1)[1].split("mutating func begin(",1)[0]
        for feature in ["rows.indices.reversed()", "row.captureID == captureID", "row.isFinal", "row.end <= minimumEnd", "indices.count == limit", "indices.reverse()"]:
            self.assertIn(feature, part)
    def test_mirror_preserved(self):
        for file in ("AppModel.swift", "TranscriptBuffer.swift"):
            self.assertEqual((ROOT/"Shared"/file).read_bytes(),(ROOT/"Phase1/JPLive.swiftpm/Sources"/file).read_bytes())
if __name__ == "__main__": unittest.main()
