#if canImport(SudachiBridge)
import Foundation
import SudachiBridge

enum SudachiRuntime {
    static func analyze(_ source: String, mode: SudachiSplitMode) throws -> [WordToken] {
        let bundle = Bundle.main
        guard let resource = bundle.url(forResource: "Sudachi", withExtension: nil)
            ?? bundle.url(forResource: "Sudachi", withExtension: nil, subdirectory: "Resources") else {
            throw AppFailure.message("앱의 Sudachi 사전 폴더가 없습니다.")
        }
        let config = resource.appendingPathComponent("sudachi.json").path
        let dictionary = resource.appendingPathComponent("system.dic").path
        let pointer = config.withCString { c in resource.path.withCString { r in dictionary.withCString { d in source.withCString { t in
            jp_sudachi_analyze_with_mode(c, r, d, t, mode.bridgeValue)
        } } } }
        guard let pointer else { throw AppFailure.message("Sudachi 응답이 없습니다.") }
        defer { jp_sudachi_free(pointer) }
        struct Result: Decodable { var tokens: [WordToken]?; var error: String? }
        let result = try JSONDecoder().decode(Result.self, from: Data(String(cString: pointer).utf8))
        if let error = result.error { throw AppFailure.message(error) }
        guard var tokens = result.tokens else { throw AppFailure.message("Sudachi 형태소 결과가 없습니다.") }
        var cursor = 0
        for i in tokens.indices {
            let token = tokens[i]
            guard token.start == cursor, token.end > token.start, token.end <= source.utf16.count,
                  let range = Range(NSRange(location: token.start, length: token.end-token.start), in: source),
                  String(source[range]) == token.surface else {
                throw AppFailure.message("Sudachi 원문/UTF-16 범위가 일치하지 않습니다.")
            }
            cursor = token.end
            tokens[i].reading = token.reading.applyingTransform(StringTransform.hiraganaToKatakana, reverse: true) ?? token.reading
        }
        guard cursor == source.utf16.count else { throw AppFailure.message("Sudachi 원문 일부가 누락되었습니다.") }
        return tokens
    }
}
#endif
