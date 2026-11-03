import Foundation
import VCCore

// 試す用の CLI。引数を読み、コマンド（`Commands.all`）を探して、実行する。コマンドごとの使い方は、`vc --help`。
// 共通のオプション（`CommonOptions`）：--model <dir>（なければ VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b、./models/tiny-jev-0.6b の順）  --length <tokens>（既定 1024）  --floor <0〜1> ほか

@MainActor func runMain() async throws {
    // ヘルプは、モデルの読み込みなど、他の処理より前に出す。
    if Help.handle(Array(CommandLine.arguments.dropFirst())) { exit(0) }
    var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
    let options = CommonOptions(consuming: &arguments)
    guard let name = arguments.command else { print(Help.overview()); exit(0) }
    let context = CommandContext(options: options)
    guard let command = Commands.find(name) else {
        eprint(Style.errRed("不明なコマンド:") + " \(name)")
        eprint("コマンドの一覧: vc --help")
        exit(2)
    }
    try await command.init().run(arguments, context)
}

try await runMain()
