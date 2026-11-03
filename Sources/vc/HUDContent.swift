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
    /// 言語モデルの返事。
    var reply: String?
}
