import Testing
@testable import VCSpeech

/// 許可が付く先（vc を動かしている端末アプリ）を、親のプロセスのパスから見つける。
@Suite struct HostAppTests {
    @Test func theFirstAppAboveVcIsTheOneThatNeedsPermission() throws {
        let found = try #require(HostApp.find(in: ["/bin/zsh", "/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty", "/sbin/launchd"]))
        #expect(found.name == "Ghostty" && found.bundlePath == "/Applications/Ghostty.app")
    }

    @Test func nestedHelpersResolveToTheOutermostApp() throws {
        let found = try #require(HostApp.find(in: ["/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"]))
        // 先に見つかる .app は、外側（パスの先頭側）
        #expect(found.name == "Visual Studio Code")
    }

    @Test func noAppMeansNoGuess() {
        #expect(HostApp.find(in: ["/bin/zsh", "/usr/bin/tmux", "/usr/bin/ssh"]) == nil)
        #expect(HostApp.find(in: []) == nil)
    }
}
