import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 設定画面の、画面から分けて確かめられる規則（キーの書き方・重なり・エンジンの組み立て）。設定ファイルの値は、ここで一度だけ検査してから書く。
enum KeyKind: Hashable {
    case listen, dictate, chat, shot
    /// 音声入力のあとに送るキー（一覧の `index` 番目。`Settings.sendKeyList`）。**トリガーではない**（押している間だけ話すキーではなく、1 回押すキー：単独のキーも、よい）。一覧の長さ以上の番号は、「これから足す」キー。
    case sendKey(Int)
    /// 操作のショートカット（キーの組み合わせだけ）：直前の入力の貼り直し・送るキーの切り替え。
    case pasteLast, cycleSend
    /// 文字起こし（システム音声）の開始・停止（キーの組み合わせだけ）。
    case transcribe
    /// 文字起こし（自分の声・マイク）の開始・停止（キーの組み合わせだけ。相手の音声とは、別の経路）。
    case transcribeMic

    /// 設定ウィンドウの欄が 1 つずつある、固定のキー（送るキーは、一覧で、足し引きする）。
    static var fixed: [KeyKind] { [.listen, .dictate, .chat, .shot, .pasteLast, .cycleSend, .transcribe, .transcribeMic] }
    /// 押している間だけ話すキー。
    static var holdKeys: [KeyKind] { [.listen, .dictate, .chat] }
    /// ショートカット（キーの組み合わせだけ）。
    static var shortcuts: [KeyKind] { [.shot, .pasteLast, .cycleSend, .transcribe, .transcribeMic] }

    var title: String {
        switch self {
        case .listen: return tr("声で頼む")
        case .dictate: return tr("音声入力")
        case .chat: return tr("会話")
        case .shot: return tr("画面撮影")
        case let .sendKey(index): return tr("キー \(index + 1)")
        case .pasteLast: return tr("直前の入力を貼り直す")
        case .cycleSend: return tr("送るキーを切り替える")
        case .transcribe: return tr("文字起こし（相手の音声）の開始・停止")
        case .transcribeMic: return tr("文字起こし（自分の声）の開始・停止")
        }
    }

    /// 1 回押すキー（送るキー）か。`false` は、キーの組み合わせ・長押しのトリガーの書き方（`HotKeySpec`）。
    var isStroke: Bool { if case .sendKey = self { return true } else { return false } }
    /// `HotKeySpec` の書き方のキー（押している間だけ話すキー・画面撮影・操作のショートカット）。
    var isTrigger: Bool { !isStroke }
    /// キーの組み合わせだけ使える、操作のショートカットか（長押しは、使えない）。
    var isAction: Bool { self == .shot || self == .pasteLast || self == .cycleSend || self == .transcribe || self == .transcribeMic }

    var help: String? {
        switch self {
        case .listen: return tr("押している間だけ話し、離すと、スキルを選んで実行します（既定：shift の長押し）")
        case .dictate: return tr("押している間だけ話し、離すと、文字にして、前面のアプリへ入力します（スキルは使いません）")
        case .chat: return tr("押している間だけ話し、離すと、会話として質問します（スキルは使いません。会話のウィンドウで、文字でも質問できます。実験）")
        case .shot: return tr("押して範囲を選び、そのあと声で頼みます（キーの組み合わせだけ）")
        case .sendKey: return nil
        case .pasteLast: return tr("直前の入力を、もう一度、前面のアプリへ入れます（キーの組み合わせだけ。メニューからも、できます）")
        case .cycleSend: return tr("送るキーの候補を、順に切り替えます（送らない → キー 1 → 2 …）。キーの組み合わせだけ。メニューからも、できます")
        case .transcribe: return tr("Mac から出ている音（相手の音声）の文字起こしを、始め・止めます（キーの組み合わせだけ。音声入力のキーとは、別です）")
        case .transcribeMic: return tr("自分の声（マイク）の文字起こしを、始め・止めます（キーの組み合わせだけ。相手の音声とは、別々に動きます。音声入力のキーとも、別です）")
        }
    }

    /// 空にできる（使わない）か。声で頼むキーは、空にすると、既定（shift の長押し）。送るキーは、一覧から外す。
    var isOptional: Bool { self != .listen && !isStroke }

    /// 空にしたときの、実際のキー（空のままの欄の表示と、「既定に戻す」）。
    var fallback: String? { self == .listen ? "shift" : nil }

    /// 設定に書かれている書き方（なければ nil）。
    func value(in settings: Settings) -> String? {
        switch self {
        case .listen: return settings.hotkey
        case .dictate: return settings.dictateHotkey
        case .chat: return settings.chatHotkey
        case .shot: return settings.shotHotkey
        case let .sendKey(index): let list = settings.sendKeyList; return list.indices.contains(index) ? list[index] : nil
        case .pasteLast: return settings.pasteLastHotkey
        case .cycleSend: return settings.dictateCycleHotkey
        case .transcribe: return settings.transcribeHotkey
        case .transcribeMic: return settings.transcribeMicHotkey
        }
    }

    /// 設定へ書く。`nil`・空は、外す（送るキーは、一覧から取る。一覧の末尾の次の番号は、足す）。送るキーは、一覧（`dictateKeys`）に書き、古い `dictateKey` は、外す。
    func set(_ text: String?, in settings: inout Settings) {
        let value = text.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .listen: settings.hotkey = value
        case .dictate: settings.dictateHotkey = value
        case .chat: settings.chatHotkey = value
        case .shot: settings.shotHotkey = value
        case let .sendKey(index):
            var list = settings.sendKeyList
            if list.indices.contains(index) {
                if let value { list[index] = value } else { list.remove(at: index) }
            } else if let value { list.append(value) }
            settings.dictateKeys = list
            settings.dictateKey = nil
        case .pasteLast: settings.pasteLastHotkey = value
        case .cycleSend: settings.dictateCycleHotkey = value
        case .transcribe: settings.transcribeHotkey = value
        case .transcribeMic: settings.transcribeMicHotkey = value
        }
    }

    /// 選びやすい候補（書き方は `HotKeySpec`・`KeyStroke`）。
    var presets: [String] {
        switch self {
        case .shot: return ["ctrl+opt+s", "ctrl+opt+space", "f5"]
        case .pasteLast: return ["opt+shift+v", "ctrl+opt+v", "f6"]
        case .cycleSend: return ["opt+shift+e", "ctrl+opt+e", "f7"]
        case .transcribe: return ["opt+shift+t", "ctrl+opt+t", "f8"]
        case .transcribeMic: return ["opt+shift+m", "ctrl+opt+m", "f9"]
        case .sendKey: return ["return", "cmd+return", "shift+return", "opt+return", "ctrl+return", "tab"]
        default: return ["shift", "ctrl", "rshift", "rcmd", "ropt", "ctrl+opt+space", "f5"]
        }
    }
}

enum SettingsRules {
    /// キーの書き方と、ほかのキーとの重なりの問題（なければ `nil`）。`text` が空なら、そのキーを外した（または、既定に戻した）ものとして、重なりだけを見る。
    static func keyProblem(_ kind: KeyKind, text: String, in settings: Settings) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if kind.isStroke {   // 1 回押すキー：書き方だけ（トリガーとの重なりは、関係ない）
            if !trimmed.isEmpty, case let .failure(f) = KeyStroke.parse(trimmed) { return f.reason }
            return nil
        }
        var candidate = settings
        if trimmed.isEmpty {
            kind.set(nil, in: &candidate)
        } else {
            if case let .failure(f) = HotKeySpec.parse(trimmed) { return f.reason }
            kind.set(trimmed, in: &candidate)
        }
        guard case let .success(listen) = candidate.hotkeySpec else { return nil }   // すでに書かれている声で頼むキーが壊れている：その直しは、そのキーの欄で
        func spec(_ text: String?) -> HotKeySpec? { text.flatMap { try? HotKeySpec.parse($0).get() } }
        return KeyConflicts.message(listen: listen, dictate: spec(candidate.dictateHotkey), shot: spec(candidate.shotHotkey), chat: spec(candidate.chatHotkey),
                                    actions: [(KeyKind.pasteLast.title, spec(candidate.pasteLastHotkey)), (KeyKind.cycleSend.title, spec(candidate.dictateCycleHotkey)), (KeyKind.transcribe.title, spec(candidate.transcribeHotkey)), (KeyKind.transcribeMic.title, spec(candidate.transcribeMicHotkey))].compactMap { name, spec in spec.map { (name, $0) } })
    }
}
