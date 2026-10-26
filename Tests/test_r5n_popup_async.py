"""Product-call-site guards for D1: never apply obsolete popup network responses."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PopupAsyncSourceContract(unittest.TestCase):
    def test_translation_mutation_after_context_guard(self):
        s = (ROOT/'Shared/StudyPopup.swift').read_text()
        toggle = s.split('private func toggleAI() async {', 1)[1].split('private func save(', 1)[0]
        guard = toggle.index('guard generation == morphologyGeneration, contextKey == popupContextKey,')
        assign = toggle.index('baseTranslation = translated')
        self.assertLess(guard, assign)
        self.assertIn('let sourceRow = row', toggle)
        self.assertIn('let sourceTokens = baseTokens', toggle)
        self.assertIn('selectionCurrent, tokensReady else { return }', toggle)
    def test_saving_never_mutates_popup_before_validating_source_and_semantic_identity(self):
        s = (ROOT/'Shared/StudyPopup.swift').read_text()
        save = s.split('private func save(_ session:', 1)[1].split('struct SessionPicker:', 1)[0]
        self.assertLess(save.index('latest.semanticID == current.semanticID'), save.index('baseTranslation = savedTranslation'))
        self.assertIn('if popupContextKey == PopupAnalysisIdentity.morphologyKey', save)
    def test_mirrored_sources(self):
        self.assertEqual((ROOT/'Shared/StudyPopup.swift').read_bytes(),
                         (ROOT/'Phase1/JPLive.swiftpm/Sources/StudyPopup.swift').read_bytes())
    def test_async_probe_has_exact_body_marker(self):
        template = (ROOT/'Tools/popup_async_probe.template').read_text()
        self.assertEqual(template.count('__TOGGLE_AI_METHOD__'), 1)

if __name__ == '__main__': unittest.main()
