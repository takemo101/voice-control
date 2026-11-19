import VCCore
import VCSpeech

/// 声の入力（アプリ） の、トリガーの組み立て：手放し（ダブルタップ）で包む・2 つ以上なら `ModeTrigger`（トリガーで、声で頼む／音声入力を切り替える）にまとめる。
@MainActor struct VoiceTriggers {
    /// `VoiceLoop` に渡すトリガー。
    let trigger: PushToTalkTrigger
    /// 手放しの録音（音量・出来事・案内を、渡す先）。`handsFreeEnabled` が false でも、持つ（何も包まないので、何も起きない）。
    let handsFree: HandsFreeGroup

    /// `keys`：（`ModeTrigger` の印, キー）の並び（1 つ以上）。
    static func make(_ keys: [(tag: String, key: PushToTalkTrigger)], handsFreeEnabled: Bool) -> VoiceTriggers {
        let group = HandsFreeGroup()
        let wrapped = keys.map { (tag: $0.tag, trigger: handsFreeEnabled ? group.wrap($0.key, tag: $0.tag) : $0.key) }
        let trigger = wrapped.count == 1 ? wrapped[0].trigger : ModeTrigger(wrapped)
        return VoiceTriggers(trigger: trigger, handsFree: group)
    }
}

/// 設定したキーどうしが、重ならないか（重なるなら、直し方つきの理由）。
enum KeyConflicts {
    static func message(listen: HotKeySpec, dictate: HotKeySpec?, shot: HotKeySpec?, chat: HotKeySpec? = nil, actions: [(name: String, spec: HotKeySpec)] = []) -> String? {
        var taken: [(name: String, spec: HotKeySpec)] = [(tr("声で頼む"), listen)]
        if let chat {
            if let clash = [(tr("声で頼む"), listen)].first(where: { $0.1.overlaps(chat) }) ?? dictate.flatMap({ $0.overlaps(chat) ? (tr("音声入力"), $0) : nil }) {
                return tr("会話のトリガー（\(chat.description)）が、\(clash.0)のトリガー（\(clash.1.description)）と、重なります。別のキーにするか、外してください")
            }
            taken.append((tr("会話"), chat))
        }
        if let dictate {
            if dictate.overlaps(listen) { return tr("声で頼むトリガー（\(listen.description)）と、音声入力のトリガー（\(dictate.description)）が、重なります。別のキーにしてください") }
            taken.append((tr("音声入力"), dictate))
        }
        if let shot {
            if let why = ScreenKeys.problem(shot, taken: taken) { return tr("スクリーンショットのキー（\(shot.description)）: \(why)") }
            taken.append((tr("画面撮影"), shot))
        }
        // 操作のショートカット（直前の入力の貼り直し・送るキーの切り替え）：キーの組み合わせだけ・ほかのキーと重ならない
        for action in actions {
            if let why = ScreenKeys.problem(action.spec, taken: taken) { return tr("\(action.name)のキー（\(action.spec.description)）: \(why)") }
            taken.append((action.name, action.spec))
        }
        return nil
    }
}
