import TestSupport
import Testing
@testable import vc

/// コマンドの一覧と、ヘルプ。
@Suite struct CommandRegistryTests {
    @Test func namesAreUniqueAndFindable() {
        let names = Commands.all.map { $0.info.name }
        #expect(Set(names).count == names.count)
        for name in names { #expect(Commands.find(name)?.info.name == name) }
        #expect(Commands.find("nope") == nil)
    }

    @Test func helpIsNotACommandButIsListed() {
        #expect(Commands.find("help") == nil)
        #expect(Help.commands.last?.name == "help")
        #expect(Help.commands.count == Commands.all.count + 1)
    }

    @Test func overviewListsEveryCommandUnderItsGroup() {
        let lines = plain(Help.overview()).split(separator: "\n").map(String.init)
        for group in CommandGroup.allCases {
            guard let start = lines.firstIndex(of: group.rawValue) else { Issue.record("見出しがない: \(group.rawValue)"); continue }
            let end = lines[(start + 1)...].firstIndex { !$0.hasPrefix("  ") && !$0.isEmpty } ?? lines.endIndex
            let section = lines[(start + 1)..<end].joined(separator: "\n")
            for info in Help.commands where info.group == group {
                #expect(section.contains("  " + pad(info.name, to: 14) + info.summary))
            }
        }
    }
}
