import AVFoundation
import Foundation

/// 読み上げの声（日本語）の選び方。**入っている声のうち、品質がいちばん高いものを、自動で使う**（高品質〔Premium・拡張〕の声を、利用者がダウンロードすると、その声になる）。
/// 利用者が、声を決めたとき（`vc speak voice`）は、それを使う。面白い声（Eloquence・効果音の声）は、自動では選ばない。
public enum SpeechVoice {
    /// 声の情報（`AVSpeechSynthesisVoice` の写し。テストで、作れるように）。
    public struct Info: Equatable, Sendable {
        public let identifier: String
        public let name: String
        public let language: String
        /// 1＝標準・2＝拡張（Enhanced）・3＝高品質（Premium）。
        public let quality: Int
        public init(identifier: String, name: String, language: String, quality: Int) {
            self.identifier = identifier; self.name = name; self.language = language; self.quality = quality
        }

        /// 面白い声（読み上げに向かない）。
        var isNovelty: Bool { identifier.hasPrefix("com.apple.eloquence.") || identifier.hasPrefix("com.apple.speech.synthesis.voice.") }
        var qualityName: String { quality >= 3 ? "高品質" : (quality == 2 ? "拡張" : "標準") }
        public var title: String { "\(name)（\(qualityName)）" }
    }

    /// 品質がいちばん高い声（同じ品質なら、面白くない声を先に。それでも同じなら、識別子の順）。日本語の声がなければ nil。
    public static func best(_ voices: [Info]) -> Info? {
        voices.filter { $0.language.hasPrefix("ja") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                if a.isNovelty != b.isNovelty { return !a.isNovelty }
                return a.identifier < b.identifier
            }.first
    }

    /// 使う声：利用者が決めた声（識別子か名前。大文字小文字は見ない）が入っていれば、それ。なければ（決めていない・消えた）、`best`。
    public static func resolve(preferred: String?, voices: [Info]) -> Info? {
        if let preferred, !preferred.isEmpty, preferred.lowercased() != "auto" {
            let wanted = preferred.lowercased()
            let candidates = voices.filter { $0.language.hasPrefix("ja") && ($0.identifier.lowercased() == wanted || $0.name.lowercased() == wanted) }
            if let found = candidates.max(by: { $0.quality < $1.quality }) { return found }
        }
        return best(voices)
    }

    /// この Mac に入っている、日本語の声。
    public static func installed() -> [Info] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
            .map { Info(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
    }
}
