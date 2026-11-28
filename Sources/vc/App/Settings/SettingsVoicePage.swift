import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: 音声

struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card(tr("言語"), footer: tr("録音の認識・録音中の文字・読み上げの声の言語です。声で頼む機能（スキルの選択）は、日本語で測っています。英語の精度は、日本語より低いことがあります。") + (model.sttLanguage == .auto ? " " + (model.usesLocalSpeechModel ? tr("「自動」は、話した音声から、言語を判定します（短い言葉では、外れることがあります）。") : tr("いまの認識は Apple のものなので、「自動」は、この Mac の言語になります。音声から判定するには、モデルのページで、ダウンロードしたモデルを選びます。")) : "")) {
            Row(tr("音声認識の言語"), detail: tr("話す言語")) {
                Picker("", selection: Binding(get: { model.sttLanguage }, set: { model.setSTTLanguage($0) })) {
                    // 自動は、ダウンロードしたモデル（Whisper）を選んでいるときだけ：Apple の認識は、言語を決めて始める
                    ForEach(SpeechLanguage.allCases.filter { $0 != .auto || model.usesLocalSpeechModel || model.sttLanguage == .auto }, id: \.self) { Text($0.displayName ?? tr("自動（音声から判定）")).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
        }
        Card(tr("録音")) {
            SwitchRow(model: model, title: tr("録音中は、ほかの音を消す"), detail: tr("マイクが、再生中の音楽や通話を拾わないように（音声入力（システム）で Mac の音を取り込んでいる間は、消しません）"), value: model.settings.mute ?? true) { $0.mute = $1 }
            RowDivider()
            SwitchRow(model: model, title: tr("録音中の文字を、画面の上に出す"), detail: tr("聞こえている文字を、字幕のように（実験）"), value: model.settings.liveCaption ?? true) { $0.liveCaption = $1 }
            RowDivider()
            SwitchRow(model: model, title: tr("聞き取りに自信がないとき、確かめる"), detail: tr("実行の前に、聞こえた文を確かめます（実験）"), value: model.settings.recheck ?? true) { $0.recheck = $1 }
        }
        Card(tr("読み上げ"), footer: tr("確認の問いかけは、いつも読み上げます。より自然な声は、システム設定 > アクセシビリティ > 読み上げコンテンツ で入れられます。")) {
            SwitchRow(model: model, title: tr("実行の結果・会話の答えを、声で読み上げる"), detail: tr("会話の答えは、全文を読みます。止めるには、Esc・トリガーを押す・メニューバーの「読み上げを止める」"), value: model.settings.speakResults ?? false) { $0.speakResults = $1 }
            RowDivider()
            Row(tr("声"), detail: tr("自動：入っている日本語の声のうち、品質が最も高いもの")) {
                HStack {
                    Picker("", selection: Binding(get: { model.settings.voice ?? "" }, set: { value in model.update { $0.voice = value.isEmpty ? nil : value } })) {
                        Text(tr("自動")).tag("")
                        ForEach(SpeechVoice.installed(language: model.sttLanguage.resolved).sorted { ($0.quality, $1.identifier) > ($1.quality, $0.identifier) }, id: \.identifier) { Text($0.name).tag($0.identifier) }
                    }
                    .labelsHidden().frame(width: 150)
                    Button { say(tr("声の確認です。こんにちは。")) } label: { Image(systemName: "speaker.wave.2.fill") }.help(tr("試しに読む"))
                }
            }
        }
    }
}
