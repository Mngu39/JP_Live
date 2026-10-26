import Foundation

@main struct ScreenshotSourceProbe {
    static func main() {
        let a = UUID(), b = UUID()
        var count = 0
        func check(_ truth: Bool, _ description: String) {
            guard truth else { fatalError("FAIL: \(description)") }
            count += 1
            print("PASS: \(description)")
        }
        check(ScreenshotCapturePolicy.matches(caption: a, current: a, running: true), "same capture identity")
        check(!ScreenshotCapturePolicy.matches(caption: a, current: b, running: true), "historical capture rejected")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: 2, sentenceEnd: 3, currentSourceFirstAudioTime: 10), "same capture old selected source rejected")
        check(ScreenshotSourcePolicy.matches(sentenceStart: 11, sentenceEnd: 12, currentSourceFirstAudioTime: 10), "same capture new source accepted")
        check(ScreenshotSourcePolicy.matches(sentenceStart: 10, sentenceEnd: 11, currentSourceFirstAudioTime: 10), "source first audio boundary accepted")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: 9, sentenceEnd: 11, currentSourceFirstAudioTime: 10), "cross-source sentence rejected")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: 11, sentenceEnd: 12, currentSourceFirstAudioTime: nil), "new selection with no PCM rejected")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: .nan, sentenceEnd: 12, currentSourceFirstAudioTime: 10), "non-finite sentence rejected")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: 11, sentenceEnd: 11, currentSourceFirstAudioTime: 10), "empty interval rejected")
        check(!ScreenshotSourcePolicy.matches(sentenceStart: 11, sentenceEnd: 12, currentSourceFirstAudioTime: .infinity), "invalid source clock rejected")
        check(ScreenshotSourcePolicy.matches(sentenceStart: 11, sentenceEnd: 12, currentSourceFirstAudioTime: 10.5), "current stream reused for next sentence")
        print("S1 source-time policy assertions: \(count)/\(count) PASS")
    }
}
