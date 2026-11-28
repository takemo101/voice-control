import AppKit
import Foundation
import VCCore
import VCSpeech

/// 音声入力に付く、**入力そのもの以外の操作**：直前の入力の貼り直し・直近の入力のコピー・履歴・入力のあとに送るキーの切り替え。
/// ショートカット（`VoiceSession` が登録）とメニュー（`StatusMenu`）が、同じものを呼ぶ。**直近の入力は、メモリだけ**（`RecentDictations`）。履歴は、設定 `history` がオンのときだけ、ファイルに書く（`DictationHistory`）。
@MainActor enum DictationActions {
    /// メニューから貼り直すときの、貼り付け（ショートカットは、`VoiceSession` のものを使う）。
    static let menuPaste = ClipboardPaste()

    /// 設定が、ショートカット・メニューで変わった（開いている設定ウィンドウが、読み直す）。
    static let settingsChanged = Notification.Name("voice-control.settings-changed")

    /// 認識した文字を、**直近の入力に覚え**、履歴がオンなら、履歴に書く。書けなかったことは、画面の上に出す（入力は、続ける）。
    static func record(_ text: String, settings: Settings) {
        RecentDictations.shared.add(text)
        guard settings.history ?? false else { return }
        do { try DictationHistory().append(text, days: DictationHistory.days(setting: settings.historyDays)) } catch {
            eprint(tr("履歴を書けませんでした: \(error)"))
            HUD.shared.show(HUDContent(phase: .failure, title: tr("履歴を書けませんでした"), hint: "\(error)"), hideAfter: 4)
        }
    }

    /// ショートカット（直前の入力の貼り直し・送るキーの切り替え・文字起こしの開始と停止）を登録する（なければ、何も登録しない）。返したトリガーは、聞いている間、保持する。
    static func install(pasteLast: HotKeySpec?, cycleSend: HotKeySpec?, transcribe: HotKeySpec?, paste: ClipboardPaste, settings: @escaping @MainActor () -> Settings) throws -> [any PushToTalkTrigger] {
        var triggers: [any PushToTalkTrigger] = []
        if let pasteLast {
            let key = try makeTrigger(pasteLast)
            key.onPress = { Task { @MainActor in await Self.pasteLast(paste: paste, settings: settings()) } }
            triggers.append(key)
        }
        if let cycleSend {
            let key = try makeTrigger(cycleSend)
            key.onPress = { Task { @MainActor in Self.cycleSendMode() } }
            triggers.append(key)
        }
        if let transcribe {   // システム音声（相手の音声）の文字起こしの開始・停止：音声入力のキー（自分の声）とは、別
            let key = try makeTrigger(transcribe)
            key.onPress = { Task { @MainActor in TranscriptWindow.shared.toggleFromShortcut() } }
            triggers.append(key)
        }
        return triggers
    }

    // MARK: 貼り直し・コピー

    /// 直前の入力を、もう一度、前面のアプリへ入れる。
    static func pasteLast(paste: ClipboardPaste, settings: Settings) async {
        guard let text = RecentDictations.shared.last else {
            HUD.shared.show(HUDContent(phase: .info, title: tr("貼り直す入力が、まだありません"), hint: tr("音声入力をすると、直前の入力を、ここから貼り直せます")), hideAfter: 2.5)
            return
        }
        await insert(text, paste: paste, settings: settings, title: tr("貼り直しました"))
    }

    /// 履歴・直近の 1 件を、前面のアプリへ入れる（メニューから）。
    static func insert(_ text: String, paste: ClipboardPaste, settings: Settings, title: String) async {
        let spaced = (settings.smartSpacing ?? true) ? SmartSpacing.adjusted(text, before: CaretContext.characterBeforeCaret()) : text
        do {
            switch try await paste.insert(spaced) {
            case .inserted: HUD.shared.show(HUDContent(phase: .success, title: title, reply: text), hideAfter: 1.8)
            case .notReceived(let kept):
                HUD.shared.show(HUDContent(phase: .failure, title: tr("入力できませんでした"), hint: kept ? tr("文字は、クリップボードに入れました（⌘V で貼り付け）") : tr("前面のアプリが、貼り付けを受け取りませんでした"), reply: text), hideAfter: 5)
            }
        } catch { HUD.shared.show(HUDContent(phase: .failure, title: tr("入力できませんでした"), hint: "\(error)"), hideAfter: 5) }
    }

    /// 文字を、クリップボードへコピーする（貼り付けは、しない）。
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.shared.show(HUDContent(phase: .success, title: tr("コピーしました"), reply: text), hideAfter: 1.5)
    }

    // MARK: 入力のあとに送るキーの切り替え

    /// 次の候補へ（順に回る）。
    static func cycleSendMode() {
        let modes = Settings.loadOrDefault().settings.dictateSend
        setSendMode(modes.nextIndex)
    }

    /// 候補の番号を決めて、設定に書く（再起動は、要らない：入力のたびに、設定を読む）。画面の上に、いまの候補を出す。
    static func setSendMode(_ index: Int) {
        let loaded = Settings.loadOrDefault()
        guard loaded.problem == nil else { eprint(tr("設定を読めないので、切り替えられません")); return }   // 読めない設定を、上書きしない
        var settings = loaded.settings
        let modes = settings.dictateSend
        guard modes.modes.indices.contains(index) else { return }
        settings.dictateMode = index
        do { try settings.save() } catch {
            HUD.shared.show(HUDContent(phase: .failure, title: tr("切り替えを保存できませんでした"), hint: "\(error)"), hideAfter: 3)
            return
        }
        let mode = modes.modes[index]
        HUD.shared.show(HUDContent(phase: .info, title: tr("入力のあと：\(mode.title)"), hint: mode.stroke == nil ? tr("文字だけを入れます（キーは、送りません）") : tr("文字を入れたあと、\(mode.title) を送ります")), hideAfter: 1.8)
        NotificationCenter.default.post(name: settingsChanged, object: nil)
    }
}
