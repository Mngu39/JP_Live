"""S1 integration source-contract checks (not Apple device tests)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


class S1SourceContract(unittest.TestCase):
    def test_picker_stream_resets_audio_source_provenance(self):
        text = source("Phase2/SystemAudioInput.swift")
        self.assertIn("self.currentStreamFirstAudioTime = nil", text)
        self.assertIn("func firstAudioTime(for stream: SCStream) -> Double?", text)
        self.assertIn("self.streamID == ObjectIdentifier(stream)", text)
        self.assertIn("currentStreamFirstAudioTime = time", text)
        self.assertIn("case .enqueued:", text)

    def test_study_screenshot_validates_source_before_and_after_capture(self):
        text = source("Phase2/SystemAudioInput.swift")
        block = text[text.index("private func captureLearningScreenshot(expectedSentence:"):
                     text.index("private static func screenshotTarget")]
        self.assertEqual(block.count("ScreenshotSourcePolicy.matches("), 2)
        self.assertIn("delegate?.firstAudioTime(for: stream)", block)
        self.assertIn("self.stream === stream", block)
        self.assertIn("selectionID == requestID", block)

    def test_caption_uses_full_semantic_source_time(self):
        app = source("Shared/AppModel.swift")
        popup = source("Shared/StudyPopup.swift")
        self.assertIn("matchingSentenceStart: caption.semanticStart, end: caption.semanticEnd", app)
        self.assertIn("app.learningScreenshot(for: current)", popup)
        self.assertIn("SavePayload.make", popup)

    def test_simulator_and_device_share_study_screenshot_signature(self):
        text = source("Phase2/SystemAudioInput.swift")
        simulator, device = text.split("#if targetEnvironment(simulator)", 1)[1].split("#else", 1)
        signature = "func captureLearningScreenshot(matchingSentenceStart start: Double, end: Double) async throws -> [String: Any]"
        self.assertIn(signature, simulator)
        self.assertIn(signature, device)
        self.assertIn("throw AppFailure.message", simulator)

    def test_device_validation_uses_unrestricted_probe(self):
        text = source("Phase2/SystemAudioInput.swift")
        self.assertIn("func captureLearningScreenshot() async throws", text)
        self.assertIn("captureLearningScreenshot(expectedSentence: nil)", text)
        self.assertIn("matchingSentenceStart start: Double", text)


if __name__ == "__main__":
    unittest.main()
