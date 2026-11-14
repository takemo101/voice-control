import Testing
@testable import VCSpeech

/// 許可が付く先（vc を動かしているアプリ）の候補を、親のプロセスのパスから集める。
@Suite struct HostAppTests {
    @Test func theAppClosestToVcComesFirstAndNestedHelpersAreAllListed() {
        // Tern：シェルは、本体ではなく、ヘルパー（Tern Daemon.app。bundle id が別）の下で動く
        let paths = ["/bin/zsh", "/Applications/Tern.app/Contents/Helpers/Tern Daemon.app/Contents/MacOS/tern", "/Applications/Tern.app/Contents/MacOS/tern"]
        #expect(HostApp.bundlePaths(in: paths) == ["/Applications/Tern.app/Contents/Helpers/Tern Daemon.app", "/Applications/Tern.app"])
    }

    @Test func plainTerminalAppsGiveOneCandidate() {
        #expect(HostApp.bundlePaths(in: ["/bin/zsh", "/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty", "/sbin/launchd"]) == ["/Applications/Ghostty.app"])
        #expect(HostApp.bundlePaths(in: ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]) == ["/Applications/Visual Studio Code.app"])
    }

    @Test func noAppMeansNoGuess() {
        #expect(HostApp.bundlePaths(in: ["/bin/zsh", "/usr/bin/tmux", "/usr/bin/ssh"]).isEmpty)
        #expect(HostApp.bundlePaths(in: []).isEmpty)
    }
}
