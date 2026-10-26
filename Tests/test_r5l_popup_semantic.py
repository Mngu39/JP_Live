"""Portable guard for indexed popup sentence lookup and production call wiring."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class R5LPopupSemanticGuards(unittest.TestCase):
    def test_production_passes_verified_index(self):
        source = (ROOT / 'Shared/AppModel.swift').read_text()
        body = source.split('func popupCaption(rowID:', 1)[1]
        self.assertIn('guard let index = captionIndex(', body)
        self.assertIn('PopupSemanticSentence.resolve(current: current, rows: transcript.rows, currentIndex: index)', body)

    def test_semantic_group_scans_adjacent_rows_not_history(self):
        source = (ROOT / 'Shared/Core.swift').read_text()
        body = source.split('enum PopupSemanticSentence {', 1)[1].split('struct LearningSession:', 1)[0]
        self.assertIn('rows.indices.contains(currentIndex)', body)
        self.assertIn('rows[currentIndex].id == current.id', body)
        self.assertIn('rows[lower - 1]', body)
        self.assertIn('rows[upper + 1]', body)
        self.assertIn('row.captureID == captureID && row.semanticID == semanticID', body)
        self.assertIn('group.first(where: \\.isSemanticSentenceAnchor)', body)
        self.assertNotIn('rows.filter', body)

    def test_canonical_phase1_same_bytes(self):
        for name in ('Core.swift', 'AppModel.swift'):
            self.assertEqual((ROOT/'Shared'/name).read_bytes(), (ROOT/'Phase1/JPLive.swiftpm/Sources'/name).read_bytes())

if __name__ == '__main__': unittest.main()
