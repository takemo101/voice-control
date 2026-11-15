import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: スキル

struct SkillsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let loaded = model.loadedSkills()
        Card("スキル", footer: "有効・無効は、すぐに効きます（再起動は要りません）。スキルの取得は、下の「スキルをインストール」か、ターミナルの vc skills install。作成は、ターミナルの vc skills（コマンド vc は、「一般」から入れられます）。") {
            if loaded.skills.isEmpty {
                Row("スキルが、まだありません", detail: "下の「スキルをインストール」から入れるか、フォルダに置いてください") { EmptyView() }
            }
            ForEach(Array(loaded.skills.enumerated()), id: \.element.name) { index, skill in
                if index > 0 { RowDivider() }
                Row(skill.name, detail: skill.description) {
                    BrandSwitch(isOn: Binding(get: { model.settings.isEnabled(skill.name) }, set: { model.setSkill(skill.name, enabled: $0) }), tint: [Brand.ok, Color(red: 0.15, green: 0.65, blue: 0.45)])
                }
            }
            ForEach(loaded.problems, id: \.location) { problem in
                RowDivider()
                Label("読めないスキル: \(problem.location)：\(problem.reason)", systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(14)
            }
        }
        CatalogCard(catalog: model.skillCatalog)
        Button { NSWorkspace.shared.open(VoiceControlHome.root.appendingPathComponent("skills")) } label: { Label("スキルのフォルダを開く", systemImage: "folder") }.controlSize(.small)
    }
}

/// インストールできるスキル（GitHub の公開リポジトリ。`vc skills install` と同じ）。一覧の取得は、押したときだけ通信する。入れる前に、許可するコマンドなどを見せて、確かめる。
struct CatalogCard: View {
    @ObservedObject var catalog: SkillCatalog

    var body: some View {
        Card("スキルをインストール", footer: "GitHub（takemo101/voice-control）の公開リポジトリから取ります。一覧を取るときと、入れるときだけ、通信します。許可するコマンドと、外へ送るかは、各行に出ています。") {
            switch catalog.state {
            case .idle:
                Row("インストールできるスキル", detail: "一覧を、GitHub から取ります") {
                    Button("一覧を取得") { catalog.loadCatalog() }.controlSize(.small)
                }
            case .loading:
                Row("取得しています…", detail: nil) { ProgressView().controlSize(.small) }
            case let .failed(reason):
                Row("取得できませんでした", detail: reason) {
                    Button("もう一度") { catalog.loadCatalog() }.controlSize(.small)
                }
            case let .loaded(listing):
                if listing.skills.isEmpty {
                    Row("スキルが、ありません", detail: "リポジトリ（\(listing.source.ref)）に、読めるスキルがありません") { EmptyView() }
                }
                ForEach(Array(listing.skills.enumerated()), id: \.element.name) { index, skill in
                    if index > 0 { RowDivider() }
                    skillRow(skill)
                }
                if listing.skills.contains(where: { !catalog.isInstalled(skill: $0.name) }) {
                    RowDivider()
                    Row("まだ入れていないスキルを、すべて", detail: nil) {
                        Button("すべて入れる") { catalog.installMissing() }.controlSize(.small).disabled(!catalog.installingIsEmpty)
                    }
                }
            }
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        let installed = catalog.isInstalled(skill: skill.name)
        let detail = skill.description + "\n許可するコマンド：" + SkillCatalog.commands(of: skill) + (skill.confirm ? "（実行の前に、確認）" : "")
        return VStack(alignment: .leading, spacing: 0) {
            Row(skill.name, detail: detail) {
                HStack(spacing: 8) {
                    if skill.external != nil { SettingsPill(text: "外へ送る", color: Brand.warn) }
                    if catalog.installing.contains(skill.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        if installed { SettingsPill(text: "入れ済み", color: Brand.ok) }
                        Button(installed ? "更新" : "入れる") { catalog.install(skill) }.controlSize(.small)
                    }
                }
            }
            if let result = catalog.results[skill.name] {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(result.ok ? Brand.ok : .red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }
}
