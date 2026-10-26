"""R5F production path source contracts; Apple SDK build is outside this host."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class LiveOnlyRepositoryTests(unittest.TestCase):
    def test_dormant_second_stt_removed(self):
        sources = "\n".join(p.read_text() for p in (ROOT / 'Shared').glob('*.swift'))
        tests = (ROOT / 'Tests' / 'CoreTests.swift').read_text()
        for obsolete in ('QualitySpeechPass', 'QualityWorkLease', 'QualitySpeechSink',
                         'QualityAudioBudget', 'revisionTranscript', 'applyQualityRevisions',
                         'resolveRevision(', 'applyRevision(', 'qualitySpeechTrace',
                         'qualityRevisionCount', 'qualityFeatureStatus', 'qualityRevision'):
            self.assertNotIn(obsolete, sources, obsolete)
        self.assertNotIn('TestQualitySpeechSink', tests)
        self.assertNotIn('QualitySpeechPass', tests)

    def test_live_paths_retained(self):
        app = (ROOT/'Shared/AppModel.swift').read_text()
        self.assertIn('let pipeline = AudioPreprocessor()', app)
        self.assertIn('let speech = AppleSpeechEngine()', app)
        self.assertIn('speech.append(output)', app)
        self.assertIn('let liveAnalysisPreparation = OptionalProviderPreparation(',app)
        self.assertIn('self.transcript.applySeparation(',app)
        self.assertIn('await pipeline.finish(cancelAnalysis:',app)
        self.assertIn('let nativeStopFailure = newInput.stopFailure',app)
        self.assertIn('var captions: [Caption] { transcript.rows }',app)

    def test_diagnostics_contains_no_fake_quality_fields(self):
        diagnostics=(ROOT/'Shared/Audio.swift').read_text()
        settings=(ROOT/'Shared/Settings.swift').read_text()
        for stale in ('QualityPassDiagnostics','qualityRevisions','qualitySpeech:','value.quality'):
            self.assertNotIn(stale, diagnostics + '\n' + settings)
        for useful in ('primarySpeech: [SpeechResultTrace]', 'diarization = DiarizationDiagnostics()',
                       'separation = SeparationDiagnostics()'):
            self.assertIn(useful, diagnostics)

    def test_mirrors_and_docs(self):
        for src in (ROOT/'Shared').glob('*.swift'):
            self.assertEqual(src.read_bytes(),(ROOT/'Phase1/JPLive.swiftpm/Sources'/src.name).read_bytes())
        self.assertTrue((ROOT/'Docs/REFACTOR_R5F.md').is_file())
        self.assertTrue((ROOT/'Docs/CHANGE_HISTORY.md').is_file())

if __name__=='__main__': unittest.main()
