import Foundation
import VCCore

/// pi には、**許可の要求の仕組みがない**（公式の文書：「すべての道具の呼び出しの前に、承認を求めない」）。そこで、**こちらが書く小さな拡張**を、pi に読ませる（`-e`）：`write`・`edit`・`bash` が動く前に、`confirm` を求める（RPC では、`extension_ui_request` として届く。`PiRPCDialect` が、ACP の許可の要求に訳す）。
/// 断られたら（断る・取りやめ・時間切れ）、道具を、**止める**（`block`）。許可の判断は、こちら（`ACPPermission`：段階・取り返しのつかないコマンド・作業フォルダ・自動モード）。拡張は、聞くだけ。
/// 第三者のコードではない（この文字列が、全部）。読み込むのは、「すべて」のときだけ（それ以外は、`--tools` で、書き込み・コマンドの道具が、無い）。
enum PiGateExtension {
    static let source = """
    // voice-control: asks the host before write / edit / bash run. The host decides (allow, ask the user, or refuse).
    export default function (pi: any) {
      pi.on("tool_call", async (event: any, ctx: any) => {
        const name = String(event.toolName);
        if (name !== "write" && name !== "edit" && name !== "bash") return;
        let allowed = false;
        try { allowed = await ctx.ui.confirm(name, JSON.stringify(event.input ?? {})); } catch { allowed = false; }
        if (!allowed) return { block: true, reason: "The user declined this action, or it is not allowed in this conversation." };
      });
    }

    """

    /// 拡張を置く場所（`~/.voice-control/pi/vc-gate.ts`）。
    static var path: String { VoiceControlHome.root.appendingPathComponent("pi").appendingPathComponent("vc-gate.ts").path }

    /// 拡張のファイルを、置く（内容が違うときだけ書く。アプリの更新で、内容が変わっても、古いまま使わない）。置けなければ、nil（呼ぶ側は、pi の RPC を、使わない：確認なしで、動かさない）。
    static func install(at path: String = PiGateExtension.path) -> String? {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? String(contentsOf: url, encoding: .utf8)) != source { try source.write(to: url, atomically: true, encoding: .utf8) }
            return path
        } catch { return nil }
    }
}
