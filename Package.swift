// swift-tools-version:6.2
import PackageDescription

// ターゲットの依存の向きは、ここで宣言し、コンパイラが強制する（宣言していない依存の `import` は、`--explicit-target-dependency-import-check=error` を付けたビルドで失敗する。付けない差分ビルドは、警告だけのことがある。scripts/test.sh・scripts/package.sh・just build は付けている）。
//   VCCore ← VCDecision ← VCSkill、 VCCore ← VCSpeech ← CTranscribe（VCSkill・VCSpeech は、互いに依存しない）
//   テスト専用の TestSupport（偽物）は、VCDecision に依存し、テストターゲットだけが依存する（本番のターゲットは、依存しない）。
// scripts/build-native.sh の出力先（transcribe.cpp の C のヘッダと静的ライブラリ）。ダウンロードして使う音声認識モデルの、推論の実行環境。
let native = "\(Context.packageDirectory)/build/native"

let package = Package(
    name: "voice-control",
    platforms: [.macOS("26.0")],
    targets: [
        // 設定・置き場所・取りやめの合図・外部コマンドの実行・モデルの取得（ModelStore）。どのターゲットも使ってよい。
        .target(name: "VCCore", path: "Sources/VCCore"),
        // 選択（Chooser・Gate）と Tiny-Jev のモデルの定義。Tiny-Jev の実行（MPSGraph。Decision/）は meeting-analyzer からの複製を含む（docs/architecture.md）。
        .target(name: "VCDecision", dependencies: ["VCCore"], path: "Sources/VCDecision"),
        // 音声認識の推論の実行環境 transcribe.cpp（C のヘッダ）。ヘッダと静的ライブラリは、scripts/build-native.sh が build/native に作る（固定した commit）。
        .target(name: "CTranscribe", path: "Sources/CTranscribe", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-I", "\(native)/include"])]),
        // 音声入力（ホットキー・録音・文字起こし）。文字起こしは、Apple の SpeechTranscriber と、ダウンロードしたモデル（CTranscribe）。
        .target(
            name: "VCSpeech", dependencies: ["VCCore", "CTranscribe"], path: "Sources/VCSpeech",
            linkerSettings: [
                // 静的ライブラリは、Objective-C の実行時情報（Metal）を落とさないよう、丸ごと取り込む（`-force_load`）。
                .unsafeFlags(["libtranscribe.a", "libggml.a", "libggml-cpu.a", "libggml-metal.a", "libggml-base.a"].flatMap { ["-Xlinker", "-force_load", "-Xlinker", "\(native)/lib/\($0)"] }),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
            ]),
        // スキル（SKILL.md の読み込み・ルーティング・コマンドの実行）。
        .target(name: "VCSkill", dependencies: ["VCCore", "VCDecision"], path: "Sources/VCSkill"),
        // 試す用の CLI（アプリではない）。
        .executableTarget(name: "vc", dependencies: ["VCCore", "VCDecision", "VCSpeech", "VCSkill"], path: "Sources/vc"),
        // 検証用の自作ウィンドウ（ボタン・入力欄・スクロール領域・状態を持つ部品）。
        .executableTarget(name: "Fixture", path: "Sources/Fixture"),
        // テストだけが使う偽物（`OptionScorer` など）。公開 API だけで作る。テストターゲットだけが依存し、本番のターゲット・成果物（`vc`）には入らない。
        .target(name: "TestSupport", dependencies: ["VCDecision"], path: "Tests/TestSupport"),
        .testTarget(name: "VCCoreTests", dependencies: ["VCCore"], path: "Tests/VCCoreTests"),
        .testTarget(name: "VCDecisionTests", dependencies: ["VCCore", "VCDecision", "TestSupport"], path: "Tests/VCDecisionTests"),
        .testTarget(name: "VCSpeechTests", dependencies: ["VCCore", "VCSpeech"], path: "Tests/VCSpeechTests"),
        .testTarget(name: "VCSkillTests", dependencies: ["VCCore", "VCDecision", "VCSkill", "TestSupport"], path: "Tests/VCSkillTests"),
        // 試す用の CLI の引数の読み方・コマンドの一覧（`@testable import vc`）。
        .testTarget(name: "vcTests", dependencies: ["vc", "TestSupport"], path: "Tests/vcTests"),
    ],
    swiftLanguageModes: [.v5]
)
