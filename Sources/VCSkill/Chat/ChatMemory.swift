import Foundation

/// 会話の 1 往復（利用者の発言と、答え）。**添付（画像・文章）の要点は、利用者の発言の中に入っている**（`ChatAttachments`）。会話の記録は、メモリだけに置く（ファイル・ログに残さない）。
public struct ChatTurn: Sendable, Equatable {
    public var user: String
    public var assistant: String
    public init(user: String, assistant: String) { self.user = user; self.assistant = assistant }
}

/// 会話の長さの決まり（Apple のオンデバイスのモデルの文脈は、8,192 トークン）。**要約は、これを超える前に、早めに行う**（要約の入力と出力の余裕を残す）。
/// トークン数は、実際の数え方ではなく、**多めに見積もった概算**（`ChatTokens`）。実際に超えたときは、`ChatConversation` が、もう 1 度、小さくして、やり直す。
public struct ChatBudget: Sendable, Equatable {
    /// 次の発言を足したとき、この見積もりを超えるなら、古い往復を要約する。
    public var trigger: Int
    /// 要約したあとに、そのまま残す、直近の往復の見積もり（これに届くまで、新しいほうから残す）。
    public var keepRecent: Int
    /// 要約の長さの上限（文字数。これを超えたら、短くやり直す）。
    public var summaryMaxCharacters: Int

    /// 利用者が伝えたこと（原文）の合計の上限（文字数。超えたら、古い順に落とす）。
    public var notesMaxCharacters: Int

    public init(trigger: Int = 4800, keepRecent: Int = 2000, summaryMaxCharacters: Int = 700, notesMaxCharacters: Int = 700) {
        self.trigger = trigger; self.keepRecent = keepRecent; self.summaryMaxCharacters = summaryMaxCharacters; self.notesMaxCharacters = notesMaxCharacters
    }

    public static let standard = ChatBudget()
}

/// トークン数の概算。**多めに見積もる**（超えて失敗するより、早めに要約するほうが安全）：日本語などの文字は 0.8、そのほかの文字は 0.35、1 つの発言ごとに 8。
public enum ChatTokens {
    public static func estimate(_ text: String) -> Int {
        var hundredths = 0   // 整数で数える（小数の誤差で、切り上げが、ずれないように）
        for scalar in text.unicodeScalars { hundredths += scalar.value >= 0x2E80 ? 80 : 35 }
        return (hundredths + 99) / 100
    }

    static let perMessage = 8

    static func estimate(_ turn: ChatTurn) -> Int { estimate(turn.user) + estimate(turn.assistant) + 2 * perMessage }
}

/// 要約の計画（piの compaction と同じ考え方）：新しいほうから、`keepRecent` に届くまで残し、それより古い往復を、要約する。**常に、最新の 1 往復は残し、少なくとも 1 往復を要約に回す**。
public enum ChatCompaction {
    /// 要約に回す、古い往復の数（先頭から）。要約が要らなければ nil。
    /// - `fixedTokens`：指示と、これまでの要約の見積もり。`incoming`：これから足す発言の見積もり。
    public static func plan(turns: [ChatTurn], fixedTokens: Int, incoming: Int, budget: ChatBudget) -> Int? {
        let total = fixedTokens + incoming + turns.reduce(0) { $0 + ChatTokens.estimate($1) }
        guard total > budget.trigger, turns.count >= 2 else { return nil }
        var kept = 0
        var cut = turns.count - 1   // 少なくとも最新の 1 往復は残す
        for index in stride(from: turns.count - 1, through: 1, by: -1) {
            kept += ChatTokens.estimate(turns[index])
            if kept >= budget.keepRecent { cut = index; break }
            cut = index
        }
        // 残す往復が、まだ余裕を超えている（1 往復が大きい）ときも、最新の 1 往復は残す
        return max(1, min(cut, turns.count - 1))
    }

    /// 要約に渡す文字：会話を「[利用者]：…」「[答え]：…」の文字列にする（会話の続きと、取り違えさせない）。長い発言は、切る。
    public static func serialize(_ turns: [ChatTurn], maxCharactersPerMessage: Int = 1500) -> String {
        func clip(_ text: String) -> String { text.count > maxCharactersPerMessage ? String(text.prefix(maxCharactersPerMessage)) + "…（以下略）" : text }
        return turns.map { "[利用者]：\(clip($0.user))\n[答え]：\(clip($0.assistant))" }.joined(separator: "\n\n")
    }
}

extension ChatCompaction {
    /// 利用者が**伝えたこと**（質問・依頼ではない文）を、言われたとおりに、取り出す。要約のモデルは、数値・名前・日時を、落とす・混ぜるので（測定：6 回の要約のあと、5 問中 1 問）、**前提は、モデルに要約させず、コードが、原文のまま残す**。
    /// 文の見分けは、粗いルール：「？」を含まない・「教えて」「ください」などの依頼を含まない・「です」「ます」などで終わる。
    public static func statements(in text: String) -> [String] {
        if text.hasPrefix("【添付") { return [] }   // 添付（画像・文章）を含む質問は、対象にしない（添付は、要約へ）
        let requests = ["教えて", "ください", "下さい", "ほしい", "欲しい", "お願い", "して。", "てよ", "でしょうか"]
        let endings = ["です", "ます", "ました", "でした", "ません", "だ", "ある", "いる", "った", "ない"]
        return text.split(whereSeparator: { "。\n".contains($0) }).compactMap { piece in
            let sentence = piece.trimmingCharacters(in: .whitespaces)
            guard sentence.count >= 6, sentence.count <= 200 else { return nil }
            guard !sentence.contains("？"), !sentence.contains("?") else { return nil }
            guard !requests.contains(where: sentence.contains) else { return nil }
            guard endings.contains(where: sentence.hasSuffix) else { return nil }
            return sentence
        }
    }

    /// 伝えたことの一覧を、足す：同じ文は、足さない・合計が `maxCharacters` を超えたら、古い順に落とす。
    public static func merge(notes: [String], adding new: [String], maxCharacters: Int) -> [String] {
        var out = notes
        for sentence in new where !out.contains(sentence) { out.append(sentence) }
        while out.count > 1, out.reduce(0, { $0 + $1.count }) > maxCharacters { out.removeFirst() }
        return out
    }
}

