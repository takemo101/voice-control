import Foundation
import VCCore

// 試す用の CLI。引数を読み、コマンド（`Commands.all`）を探して、実行する。コマンドごとの使い方は、`vc --help`。
// 共通のオプション（`CommonOptions`）：--model <dir>（なければ VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b、./models/tiny-jev-0.6b の順）  --length <tokens>（既定 1024）  --floor <0〜1> ほか

@MainActor func runMain() async throws {
    AppLocalization.bootstrap(settings: Settings.loadOrDefault().settings)   // 表示言語：ヘルプより前に決める（設定が壊れていれば、警告は、あとの `CommandContext` が 1 回出す）
    // ヘルプは、モデルの読み込みなど、他の処理より前に出す。
    // アプリ（….app の中の vc）を、引数なしで起動したら、メニューバーのアプリ。引数があれば、CLI（スキルが使うコマンド）
    let raw: [String]
    switch AppLaunch.mode(arguments: Array(CommandLine.arguments.dropFirst()), executablePath: AppLaunch.executablePath, isTerminal: isatty(STDIN_FILENO) == 1) {
    case .gui:
        AppEntry.launch()
        exit(0)
    case let .openApp(bundle):
        if AppLaunch.open(bundle: bundle) { print(tr("Voice Control: メニューバーのアプリを起動しました（すでに起動中なら、そのままです）")); exit(0) }
        raw = []
    case let .cli(arguments):
        raw = arguments
    }
    if Help.handle(raw) { exit(0) }
    var arguments = Arguments(raw)
    let options = CommonOptions(consuming: &arguments)
    guard let name = arguments.command else { print(Help.overview()); exit(0) }
    let context = CommandContext(options: options)
    guard let command = Commands.find(name) else {
        eprint(Style.errRed(tr("不明なコマンド:")) + " \(name)")
        eprint(tr("コマンドの一覧: vc --help"))
        exit(2)
    }
    try await command.init().run(arguments, context)
}

try await runMain()
