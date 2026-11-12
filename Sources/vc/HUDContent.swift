import Foundation

/// 画面の上に出す表示の中身。
struct HUDContent: Sendable {
    enum Phase: Sendable { case recording, working, success, failure, info, confirm }

    /// 実行したコマンド 1 つ。
    struct Step: Sendable {
        enum Status: Sendable { case running, ok, failed(Int32), denied }
        var command: String
        var status: Status = .running
        /// 出力の先頭の 1 行（長いときは切る）。
        var output: String?
    }

    var phase: Phase
    var title: String
    /// タイトルの下の、小さな補足（「離すと認識します」など）。
    var hint: String?
    /// 右上のチップ（トリガーの名前など）。
    var chip: String?
    /// 聞こえた文。
    var heard: String?
    /// 使うスキルの名前（タイトルの横のバッジ）。
    var skill: String?
    var steps: [Step] = []
    /// 録音中の文字（途中経過）の欄を、最初から出す（`vc caption` が on のとき：欄の高さを、決めておく。文字が来るまでは、案内を出す）。
    var captionSlot = false
    /// 使う画像（画像を使うスキルのとき：サムネイルと、大きさ・外へ送るか）。
    var image: HUDImage?
    /// 言語モデルの返事。
    var reply: String?
    /// 「実行する」「やめる」のボタンを出す（確認の問いかけ。声の「はい」と、どちらでも答えられる）。出している間だけ、パネルは、クリックを受ける。
    var choices = false

    /// 小さなカプセルで出すか：録音中と、認識中（実行する前の、題だけの考え中）。本文（聞こえた文・コマンド・返事・ボタン）があれば、カード。
    var isCompact: Bool {
        if phase == .recording { return true }
        return phase == .working && heard == nil && skill == nil && steps.isEmpty && reply == nil && !choices
    }
}

/// 確認（声の流れ）の答え方の案内。画面の上のパネルと、端末で、同じ文を使う。
enum ConfirmGuide {
    static let howToAnswer = "ボタン・キー（← → と Return、y / n）で答えるか、もう一度トリガーを押して「はい」と言う"
}
