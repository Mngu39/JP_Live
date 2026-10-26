"""Source guard for the capture-boundary optimization; runtime equivalence in CoreTests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class R5JCaptureBoundaryGuards(unittest.TestCase):
    def test_boundary_checked_before_final_and_time_filters(self):
        part = (ROOT / "Shared/TranscriptBuffer.swift").read_text().split(
            "func recentFinalSpeakerRowIndices(", 1)[1].split("mutating func begin(", 1)[0]
        boundary = part.index("guard row.captureID == captureID else { break }")
        self.assertLess(boundary, part.index("guard row.isFinal else { continue }"))
        self.assertLess(boundary, part.index("row.end <= minimumEnd"))
        self.assertRegex(part, r"for index in rows\.indices\.reversed\(\)")
        self.assertIn("indices.reverse()", part)

    def test_old_captures_are_retained_and_replacement_is_in_place(self):
        source = (ROOT / "Shared/TranscriptBuffer.swift").read_text()
        begin = source.split("mutating func begin(", 1)[1].split("mutating func clearDisplay(", 1)[0]
        self.assertNotIn("rows.remove", begin)
        self.assertIn("rows.replaceSubrange(index...index, with: replacement)", source)

    def test_phase1_mirror(self):
        self.assertEqual((ROOT / "Shared/TranscriptBuffer.swift").read_bytes(),
                         (ROOT / "Phase1/JPLive.swiftpm/Sources/TranscriptBuffer.swift").read_bytes())

if __name__ == "__main__":
    unittest.main()
