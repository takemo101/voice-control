import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: キー

struct KeysPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Callout(symbol: "hand.tap.fill", text: tr("キーを押している間だけ、話します。たとえば、Shift を押したまま「電卓を開いて」と言って、離すと、実行されます。キーの欄を押して、使いたいキーを押すと、決まります。"))
        Card(tr("話すキー"), footer: tr("修飾キーだけのキー（⇧ ⌃ ⌥ ⌘）の長押しは、アクセシビリティの許可が要ります。右側のキーだけにすると、普段の入力での誤作動が減ります。音声入力（システム）だけは、押すたびに、開始・停止します（キーの組み合わせだけ）。マイクとシステムは、別々に動かせます。")) {
            ForEach(Array(KeyKind.holdKeys.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                KeyRow(model: model, kind: kind)
            }
            RowDivider()
            SwitchRow(model: model, title: tr("手放し（ダブルタップ）"), detail: tr("キーを短く 2 回押すと、黙るまで録音します（押し続ける使い方も、そのまま使えます）"), value: model.settings.handsFree ?? true) { $0.handsFree = $1 }
        }
        Card(tr("ショートカット"), footer: tr("キーの組み合わせだけ（⌃⌥ などを含むもの）が使えます。")) {
            ForEach(Array(KeyKind.shortcuts.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                KeyRow(model: model, kind: kind)
            }
        }
    }
}

struct KeyRow: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind

    var body: some View {
        let saved = kind.value(in: model.settings) ?? ""
        let isRecording = model.recording == kind
        let effective = saved.isEmpty ? (kind.fallback ?? "") : saved
        let label: String = {
            if kind.isTrigger, case let .success(spec) = HotKeySpec.parse(effective) { return KeyRow.label(of: spec) }
            if !kind.isTrigger, case let .success(stroke) = KeyStroke.parse(effective) { return "\(stroke.displayName)  \(stroke.description)" }
            return effective.isEmpty ? tr("未設定") : "?"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Row(kind.title, detail: kind.help) {
                KeyChip(model: model, kind: kind, label: label, isEmpty: effective.isEmpty,
                        extra: kind.isOptional ? (tr("使わない"), { model.setDraft(kind, ""); model.commitKey(kind) }) : nil)
            }
            if isRecording {
                Label(model.recordingHint ?? (kind.isTrigger ? tr("修飾キーだけなら、押して、離します。組み合わせなら、続けて押します。") : tr("送りたいキーを押してください（⌘Enter のように、修飾キーと一緒でも）。Esc で取りやめ。")), systemImage: model.recordingHint == nil ? "keyboard" : "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(model.recordingHint == nil ? Color.secondary : Brand.rec1)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else if let problem = model.keyProblems[kind] {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    /// キーの表示：記号と、書き方（例：「⇧  shift」「右⌘  rcmd」「⌃⌥S  ctrl+opt+s」）。
    static func label(of spec: HotKeySpec) -> String {
        let symbols = String(spec.displayName.split(whereSeparator: { "(（".contains($0) })[0]).trimmingCharacters(in: .whitespaces)
        return "\(symbols)  \(spec.description)"
    }

    /// 候補メニューの表示。
    static func title(of preset: String, trigger: Bool = true) -> String {
        if trigger, case let .success(spec) = HotKeySpec.parse(preset) { return label(of: spec) }
        if !trigger, case let .success(stroke) = KeyStroke.parse(preset) { return "\(stroke.displayName)  \(stroke.description)" }
        return preset
    }
}

/// キーの欄：押して、使いたいキーを押す（記録）＋ 候補のメニュー。送るキーの行（`SendKeyRow`）と、キーの行（`KeyRow`）が、共有する。
struct KeyChip: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind
    let label: String
    let isEmpty: Bool
    /// 候補のメニューに足す項目（「使わない」など）。
    var extra: (title: String, action: () -> Void)?

    var body: some View {
        let isRecording = model.recording == kind
        HStack(spacing: 8) {
            Button { isRecording ? model.stopRecording() : model.startRecording(kind) } label: {
                Text(isRecording ? tr("キーを押してください…") : label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? Brand.rec1 : (isEmpty ? Color.secondary : Color.primary))
                    .padding(.horizontal, 12).frame(minWidth: 86, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isRecording ? Brand.rec2.opacity(0.14) : Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isRecording ? Brand.rec1 : Color.primary.opacity(0.18), lineWidth: isRecording ? 1.5 : 1))
                    .shadow(color: .black.opacity(isRecording ? 0 : 0.16), radius: 0, y: 2)
            }
            .buttonStyle(.plain)
            .help(tr("押して、使いたいキーを押す（Esc で取りやめ）"))
            Menu {
                ForEach(kind.presets, id: \.self) { preset in
                    Button(KeyRow.title(of: preset, trigger: kind.isTrigger)) { choose(preset) }
                }
                if let extra { Divider(); Button(extra.title, action: extra.action) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().help(tr("候補から選ぶ"))
        }
    }

    private func choose(_ preset: String) {
        if case let .sendKey(index) = kind { model.setSendKey(index, preset) } else { model.setDraft(kind, preset); model.commitKey(kind) }
    }
}
