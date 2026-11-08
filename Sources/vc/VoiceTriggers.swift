import VCSpeech

/// `vc listen --hotkey`・`vc dictate` の、トリガーの組み立て：手放し（ダブルタップ）で包む・2 つ以上なら `ModeTrigger`（トリガーで、声で頼む／音声入力を切り替える）にまとめる。
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
    static func message(listen: HotKeySpec, dictate: HotKeySpec?, shot: HotKeySpec?) -> String? {
        var taken: [(name: String, spec: HotKeySpec)] = [("声で頼む", listen)]
        if let dictate {
            if dictate.overlaps(listen) { return "声で頼むトリガー（\(listen.description)）と、音声入力のトリガー（\(dictate.description)）が、重なります。vc hotkey set-dictate で、別のキーにしてください" }
            taken.append(("音声入力", dictate))
        }
        if let shot, let why = ScreenKeys.problem(shot, taken: taken) { return "スクリーンショットのキー（\(shot.description)）: \(why)（vc hotkey で直す）" }
        return nil
    }
}
