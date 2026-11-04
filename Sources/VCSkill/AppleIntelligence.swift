import FoundationModels

/// Apple の言語モデル（FoundationModels。スキルの実行に使う）が、いま使えるか。使えないとき、理由と、直す手順を返す。
/// Tiny-Jev のモデルが無いときに `vc model download` を案内するのと同じ形：使えないまま実行して、実行の途中で失敗させない。
public enum AppleIntelligence {
    public enum Status: Equatable, Sendable {
        case available
        case unavailable(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// この Mac が、Apple Intelligence に対応していない。
        case deviceNotEligible
        /// 設定で、Apple Intelligence がオフ。
        case notEnabled
        /// オンだが、言語モデルが、まだ使えない（ダウンロード中など）。
        case modelNotReady
        /// OS が、これ以外の理由を返した（将来の理由を含む）。
        case unknown

        /// 何が使えないか（1 文）。
        public var summary: String {
            switch self {
            case .deviceNotEligible: return "この Mac（または環境）は、Apple Intelligence に対応していません"
            case .notEnabled: return "Apple Intelligence が、オフです"
            case .modelNotReady: return "Apple の言語モデルが、まだ使えません（ダウンロード中など）"
            case .unknown: return "Apple の言語モデルが、使えません"
            }
        }

        /// 直す手順（1〜2 文）。ツールは、設定を変えない：利用者が、システム設定で行う。
        public var remedy: String {
            switch self {
            case .deviceNotEligible:
                return "Apple Intelligence は、対応する Mac・macOS・言語と地域でだけ使えます（仮想マシンなどでは、使えないことがあります）。スキルの実行には、これが要ります"
            case .notEnabled:
                return "システム設定 > Apple Intelligence と Siri で、Apple Intelligence をオンにしてください（オンにすると、言語モデルのダウンロードが始まります）"
            case .modelNotReady:
                return "システム設定 > Apple Intelligence と Siri で、ダウンロードが終わるのを待って、もう一度実行してください"
            case .unknown:
                return "システム設定 > Apple Intelligence と Siri を確かめてください（対応する言語・地域の設定も）"
            }
        }
    }

    /// いまの状態。
    public static func current() -> Status { status(of: SystemLanguageModel.default.availability) }

    /// OS の答えを、`Status` に写す（OS の状態を作れない環境でも、試せるように、引数にしている）。
    static func status(of availability: SystemLanguageModel.Availability) -> Status {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.notEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        @unknown default:
            return .unavailable(.unknown)
        }
    }
}
