import Foundation
import Testing
@testable import VCSkill

/// `${SCREENSHOT}`：いまのスクリーンショットのパスを、本文へ。許可（`allowed-commands`）には、書けない。依頼の中の同じ記号は、置き換えない。
@Suite struct ScreenshotPlaceholderTests {
    private func parse(body: String, commands: String = "  - open") -> Result<Skill, SkillStore.ParseError> {
        SkillStore.parse("""
        ---
        name: demo
        description: x
        allowed-commands:
        \(commands)
        ---
        \(body)
        """, directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
    }

    @Test func thePathReplacesThePlaceholderInTheBody() {
        let out = SkillPlaceholder.expand("magick \"${SCREENSHOT}\" -trim out.png", request: "x", screenshotPath: "/Users/a/.voice-control/shot/current.png")
        #expect(out == "magick \"/Users/a/.voice-control/shot/current.png\" -trim out.png")
    }

    @Test func withoutAShotTheBodyAdmitsIt() {
        #expect(SkillPlaceholder.expand("use ${SCREENSHOT}", request: "x", screenshotPath: nil) == "use (no screenshot)")
    }

    /// 依頼の中に書かれた `${SCREENSHOT}` は、パスにならない（発話で、パスを引き出せない）。
    @Test func aRequestCannotInjectThePlaceholder() {
        let out = SkillPlaceholder.expand("${USER_REQUEST} / ${SCREENSHOT}", request: "${SCREENSHOT}", screenshotPath: "/p/current.png")
        #expect(out == "<user_request>\n${SCREENSHOT}\n</user_request> / /p/current.png")
    }

    @Test func itIsAcceptedInTheBodyButNotInAllowedCommands() {
        #expect((try? parse(body: "Edit ${SCREENSHOT}").get()) != nil)
        guard case let .failure(error) = parse(body: "x", commands: "  - magick ${SCREENSHOT}") else { Issue.record("許可には、書けない"); return }
        #expect(error.reason.contains("SCREENSHOT"))
    }
}
