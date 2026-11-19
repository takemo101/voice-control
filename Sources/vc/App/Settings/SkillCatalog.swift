import AppKit
import Foundation
import VCCore
import VCSkill

/// インストールできるスキルの一覧の状態（GitHub の公開リポジトリ。取得は、利用者が押したときだけ）。
enum CatalogState {
    case idle
    case loading
    case loaded(RemoteInstall.Listing)
    case failed(String)
}


/// インストールできるスキルの一覧と、インストール（`vc skills install` と同じ流れ：`RemoteInstall`。設定ウィンドウ > スキル）。
/// 一覧の取得は、利用者が押したときだけ（GitHub の公開リポジトリへ通信する）。確認のダイアログは、出さない（許可するコマンド・外へ送るかは、一覧の各行に出す）。
@MainActor final class SkillCatalog: ObservableObject {
    @Published private(set) var state = CatalogState.idle
    /// インストール中のスキルの名前。
    @Published private(set) var installing: Set<String> = []
    /// インストールの結果（成功・失敗）。名前ごとに、最後の 1 件。
    @Published private(set) var results: [String: (ok: Bool, text: String)] = [:]
    private let onInstalled: () -> Void

    init(onInstalled: @escaping () -> Void) { self.onInstalled = onInstalled }

    private var installRef: String { "v\(AppInfo.version)" }

    /// インストールできるスキルの一覧を取る（GitHub への通信：押したときだけ）。
    func loadCatalog() {
        if case .loading = state { return }
        state = .loading
        let ref = installRef
        Task {
            do {
                let listing = try await RemoteInstall.list(explicitRef: nil, defaultRef: ref)
                state = .loaded(listing)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    var installingIsEmpty: Bool { installing.isEmpty }

    /// 許可するコマンドの表示：取得のための一時フォルダの名前は出さず、`${SKILL_DIR}`（スキルのフォルダ）にする。
    static func commands(of skill: Skill) -> String {
        let directory = skill.file.deletingLastPathComponent().resolvingSymlinksInPath().path
        let raw = skill.allowedCommands.map { $0.replacingOccurrences(of: skill.file.deletingLastPathComponent().path, with: "${SKILL_DIR}").replacingOccurrences(of: directory, with: "${SKILL_DIR}") }
        return raw.isEmpty ? tr("（なし）") : raw.joined(separator: tr("、"))
    }

    func isInstalled(skill name: String) -> Bool {
        FileManager.default.fileExists(atPath: VoiceControlHome.skillsDirectory.appendingPathComponent(name).path)
    }

    /// 1 つ入れる（同名があれば、置き換える：「更新」）。確認のダイアログは、出さない（許可するコマンド・外へ送るかは、一覧の各行に出ている）。
    func install(_ skill: Skill) {
        guard !installing.contains(skill.name), case let .loaded(listing) = state else { return }
        run(names: [skill.name], listing: listing, overwrite: isInstalled(skill: skill.name))
    }

    /// 一覧の、まだ入れていないスキルを、すべて入れる。
    func installMissing() {
        guard case let .loaded(listing) = state, installing.isEmpty else { return }
        let missing = listing.skills.filter { !isInstalled(skill: $0.name) }
        guard !missing.isEmpty else { return }
        run(names: missing.map(\.name).sorted(), listing: listing, overwrite: false)
    }

    private func run(names: [String], listing: RemoteInstall.Listing, overwrite: Bool) {
        installing.formUnion(names)
        names.forEach { results[$0] = nil }
        Task {
            do {
                // 一覧と同じ版で取る（タグがなく、main に切り替えた場合も、同じ）
                let report = try await RemoteInstall.install(names: names, explicitRef: listing.source.ref, defaultRef: installRef, overwrite: overwrite)
                for outcome in report.outcomes {
                    switch outcome.result {
                    case let .success(installed): results[outcome.name] = (true, installed.overwritten ? tr("置き換えました") : tr("入れました"))
                    case let .failure(failure): results[outcome.name] = (false, Self.describe(failure))
                    }
                }
            } catch {
                names.forEach { results[$0] = (false, Self.describe(error)) }
            }
            installing.subtract(names)
            onInstalled()   // スキルの一覧（有効・無効）を、読み直す
        }
    }

    private static func describe(_ failure: SkillInstaller.Failure) -> String {
        switch failure {
        case .notFound: return tr("リポジトリに、読めるスキルがありません")
        case let .unreadable(_, why): return tr("SKILL.md が読めません（\(why)）")
        case .alreadyInstalled: return tr("すでに入っています")
        case let .containsSymlink(_, path): return tr("シンボリックリンク（\(path)）を含むので、置きません")
        case let .copyFailed(_, why): return tr("置けません（\(why)）")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? RemoteSkills.Failure else { return tr("取得できません：\(error.localizedDescription)") }
        switch failure {
        case let .network(reason): return tr("GitHub から取得できません（\(reason)）。ネットワークを確かめてください")
        case let .refNotFound(missing): return tr("版 \(missing) が、リポジトリにありません")
        default: return tr("取得できません：\(failure)")
        }
    }
}
