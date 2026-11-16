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
        Card("録音") {
            SwitchRow(model: model, title: "録音中は、ほかの音を消す", detail: "マイクが、再生中の音楽や通話を拾わないように", value: model.settings.mute ?? true) { $0.mute = $1 }
            RowDivider()
            SwitchRow(model: model, title: "録音中の文字を、画面の上に出す", detail: "聞こえている文字を、字幕のように（実験）", value: model.settings.liveCaption ?? true) { $0.liveCaption = $1 }
            RowDivider()
            SwitchRow(model: model, title: "聞き取りに自信がないとき、確かめる", detail: "実行の前に、聞こえた文を確かめます（実験）", value: model.settings.recheck ?? true) { $0.recheck = $1 }
        }
        Card("読み上げ", footer: "確認の問いかけは、いつも読み上げます。より自然な声は、システム設定 > アクセシビリティ > 読み上げコンテンツ で入れられます。") {
            SwitchRow(model: model, title: "実行の結果・会話の答えを、声で読み上げる", detail: "会話の答えは、全文を読みます。止めるには、Esc・トリガーを押す・メニューバーの「読み上げを止める」", value: model.settings.speakResults ?? false) { $0.speakResults = $1 }
            RowDivider()
            Row("声", detail: "自動：入っている日本語の声のうち、品質が最も高いもの") {
                HStack {
                    Picker("", selection: Binding(get: { model.settings.voice ?? "" }, set: { value in model.update { $0.voice = value.isEmpty ? nil : value } })) {
                        Text("自動").tag("")
                        ForEach(SpeechVoice.installed().sorted { ($0.quality, $1.identifier) > ($1.quality, $0.identifier) }, id: \.identifier) { Text($0.name).tag($0.identifier) }
                    }
                    .labelsHidden().frame(width: 150)
                    Button { say("声の確認です。こんにちは。") } label: { Image(systemName: "speaker.wave.2.fill") }.help("試しに読む")
                }
            }
        }
        Card("音声入力", footer: "オンにすると、送信ボタンやコマンドの実行まで、声だけでできます。メッセージ・ターミナルでは、そのまま送られます（キーを送る前の 0.8 秒に、Esc で取りやめられます）。") {
            SwitchRow(model: model, title: "入力したあと、キーを送る", detail: "文字を入れてから、選んだキー（既定：Enter）を押します", value: model.settings.dictateEnter ?? false) { $0.dictateEnter = $1 }
            if model.settings.dictateEnter ?? false {   // オフのときは、キーの欄を、出さない
                RowDivider()
                KeyRow(model: model, kind: .sendKey)
            }
        }
        Card("音声入力のつなぎ言葉", footer: (model.settings.removeFillers ?? false) ? "消す言葉は、1 行に 1 つ。空にすると、既定の辞書を使います。声で頼む内容には、使いません。" : "オンにすると、消す言葉の一覧を、ここで直せます。音声入力だけに効きます（声で頼む内容には、使いません）。") {
            SwitchRow(model: model, title: "つなぎ言葉（えーと・um など）を消す", detail: nil, value: model.settings.removeFillers ?? false) { $0.removeFillers = $1 }
            if model.settings.removeFillers ?? false {   // オフのときは、言葉の欄を、出さない（空の大きな欄が、目立つ）
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.fillersText)
                        .font(.system(size: 12)).frame(height: 84).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    HStack {
                        Button("保存") { model.saveFillers() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                        Button("既定に戻す") { model.resetFillers() }.controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }
}
