"""Static guards for the R5G source-level safety contracts.

These checks are NOT a substitute for Apple XCTest or actual native errors.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text()


class R5GSafetyGuards(unittest.TestCase):
    def test_c2_started_stream_cleanup_does_not_drop_unconfirmed_reference(self):
        s = source("Phase2/SystemAudioInput.swift")
        part = s[s.index("var attemptedStart = false"):s.index("func stopped(")]
        self.assertIn("attemptedStart = true", part)
        self.assertIn("if attemptedStart {", part)
        self.assertIn("try await stopNativeCapture(stream)", part)
        self.assertIn("Preserve the stream for explicit Stop retry", part)

    def test_c3_screenshot_has_single_native_stop_site_and_flight(self):
        s = source("Phase2/SystemAudioInput.swift")
        part = s[s.index("func captureLearningScreenshot() async throws", s.index("#else")):s.index("private static func screenshotTarget")]
        self.assertEqual(part.count("stopNativeCapture(stream)"), 1)
        self.assertIn("let nativeStopFlights = CaptureNativeStopFlights()", s)
        self.assertIn("if nativeStopConfirmed { self.stream = nil }", part)

    def test_c4_checks_caption_id_on_both_sides_of_await(self):
        s = source("Shared/AppModel.swift")
        part = s[s.index("func learningScreenshot(for caption: Caption)"):s.index("func retryFailedTranslations")]
        self.assertEqual(part.count("ScreenshotCapturePolicy.matches("), 2)
        self.assertIn("currentInput === systemInput", part)
        self.assertIn("app.learningScreenshot(for: current)", source("Shared/StudyPopup.swift"))

    def test_c5_identity_is_carried_to_painted_rows(self):
        timeline = source("Shared/SpeechTimeline.swift")
        mapper = source("Shared/Separation.swift")
        buffer = source("Shared/TranscriptBuffer.swift")
        self.assertIn("epoch: Int)?", timeline)
        self.assertIn("evidence.epoch == overlapEpoch", mapper)
        self.assertIn("LaneSpeakerIdentity(epoch: evidence.epoch, slot: evidence.slot)", mapper)
        self.assertIn("identityEpoch: identity.epoch", mapper)
        self.assertIn("identityEpoch: identity.epoch", buffer)
        self.assertIn("[Int: LaneSpeakerIdentity]", mapper)


if __name__ == "__main__":
    unittest.main()
