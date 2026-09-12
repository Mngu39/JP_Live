#if canImport(SudachiBridge)
import Foundation
import SudachiBridge

enum SudachiRuntime {
    static func analyze(_ source: String) -> [WordToken]? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let resource = bundle.url(forResource: "Sudachi", withExtension: nil) else { return nil }
        let config = resource.appendingPathComponent("sudachi.json").path
        let dictionary = resource.appendingPathComponent("system.dic").path
        let pointer = config.withCString { c in resource.path.withCString { r in dictionary.withCString { d in source.withCString { t in
            jp_sudachi_analyze(c, r, d, t)
        } } } }
        guard let pointer else { return nil }
        defer { jp_sudachi_free(pointer) }
        struct Result: Decodable { var tokens: [WordToken] }
        guard var result = try? JSONDecoder().decode(Result.self, from: Data(String(cString: pointer).utf8)),
              result.tokens.map(\.surface).joined() == source else { return nil }
        for i in result.tokens.indices {
            result.tokens[i].reading = result.tokens[i].reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? result.tokens[i].reading
        }
        return result.tokens
    }
}
#endif
