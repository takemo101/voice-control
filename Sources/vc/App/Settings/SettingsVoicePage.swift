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
            SwitchRow(model: model, title: tr("録音中は、ほかの音を消す"), detail: tr("マイクが、再生中の音楽や通話を拾わないように"), value: model.settings.mute ?? true) { $0.mute = $1 }
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
        Card(tr("音声入力"), footer: tr("送るキーを選ぶと、送信ボタンやコマンドの実行まで、声だけでできます。メッセージ・ターミナルでは、そのまま送られます（キーを送る前の 0.8 秒に、Esc で取りやめられます）。")) {
            Row(tr("入力したあとに送るキー"), detail: tr("文字を入れてから、選んだキーを押します。候補は、キーのページで決めます")) {
                let send = model.settings.dictateSend
                Picker("", selection: Binding(get: { send.active }, set: { model.setDictateMode($0) })) {
                    ForEach(Array(send.modes.enumerated()), id: \.offset) { Text($0.element.title).tag($0.offset) }
                }
                .labelsHidden().frame(width: 150)
            }
            RowDivider()
            SwitchRow(model: model, title: tr("英語の前に、空白を足す"), detail: tr("英語を、単語のすぐあとに入れるとき、空白を 1 つ足します（日本語には、足しません）"), value: model.settings.smartSpacing ?? true, restart: false) { $0.smartSpacing = $1 ? nil : false }
        }
        Card(tr("音声入力のつなぎ言葉"), footer: (model.settings.removeFillers ?? false) ? tr("消す言葉は、1 行に 1 つ。空にすると、既定の辞書を使います。声で頼む内容には、使いません。") : tr("オンにすると、消す言葉の一覧を、ここで直せます。音声入力だけに効きます（声で頼む内容には、使いません）。")) {
            SwitchRow(model: model, title: tr("つなぎ言葉（えーと・um など）を消す"), detail: nil, value: model.settings.removeFillers ?? false) { $0.removeFillers = $1 }
            if model.settings.removeFillers ?? false {   // オフのときは、言葉の欄を、出さない（空の大きな欄が、目立つ）
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.fillersText)
                        .font(.system(size: 12)).frame(height: 84).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    HStack {
                        Button(tr("保存")) { model.saveFillers() }.buttonStyle(.borderedProminent).tint(Brand.rec1).controlSize(.small)
                        Button(tr("既定に戻す")) { model.resetFillers() }.controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }
}
