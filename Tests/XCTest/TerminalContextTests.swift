import Testing
import Foundation
@testable import VibeFocusKit

@Suite("TerminalContext Logic")
@MainActor
struct TerminalContextLogicTests {

    // MARK: - isRemote

    @Test("TerminalContext.isRemote: with non-empty machineLabel → remote")
    func isRemoteWithLabel() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: "remote-host"
        )
        #expect(ctx.isRemote)
    }

    @Test("TerminalContext.isRemote: nil machineLabel → not remote")
    func isRemoteNilLabel() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!ctx.isRemote)
    }

    @Test("TerminalContext.isRemote: empty machineLabel → not remote")
    func isRemoteEmptyLabel() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: ""
        )
        #expect(!ctx.isRemote)
    }

    // MARK: - hasUsefulContext (extended coverage beyond ClaudeHookModelsTests)

    @Test("TerminalContext.hasUsefulContext: kittyWindowID alone does not provide context")
    func hasUsefulContextKitty() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: "123",
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: weztermPane alone does not provide context")
    func hasUsefulContextWezterm() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: "pane-1", tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: valid ppid provides context")
    func hasUsefulContextPpid() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: "12345",
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: ppid=1 does not provide context")
    func hasUsefulContextPpidOne() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: "1",
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: invalid ppid string does not provide context")
    func hasUsefulContextPpidInvalid() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: "not-a-number",
            claudeProjectDir: nil, windowID: nil, machineLabel: nil
        )
        #expect(!ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: machineLabel provides context")
    func hasUsefulContextMachineLabel() {
        let ctx = TerminalContext(
            termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
            weztermPane: nil, tty: nil, ppid: nil,
            claudeProjectDir: nil, windowID: nil, machineLabel: "ssh-host"
        )
        #expect(ctx.hasUsefulContext)
    }

    @Test("TerminalContext.hasUsefulContext: empty strings do not provide context")
    func hasUsefulContextEmptyStrings() {
        let ctx = TerminalContext(
            termSessionID: "", itermSessionID: "", kittyWindowID: "",
            weztermPane: "", tty: "", ppid: "",
            claudeProjectDir: "", windowID: "", machineLabel: ""
        )
        #expect(!ctx.hasUsefulContext)
    }

    // MARK: - Codable roundtrip with all fields

    @Test("TerminalContext Codable roundtrip with all fields")
    func codableRoundtripFull() throws {
        let ctx = TerminalContext(
            termSessionID: "ts-1", itermSessionID: "is-2", kittyWindowID: "kw-3",
            weztermPane: "wp-4", tty: "/dev/ttys001", ppid: "1234",
            claudeProjectDir: "/project", windowID: "42", machineLabel: "host"
        )
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(TerminalContext.self, from: data)
        #expect(decoded.termSessionID == "ts-1")
        #expect(decoded.itermSessionID == "is-2")
        #expect(decoded.kittyWindowID == "kw-3")
        #expect(decoded.weztermPane == "wp-4")
        #expect(decoded.tty == "/dev/ttys001")
        #expect(decoded.ppid == "1234")
        #expect(decoded.claudeProjectDir == "/project")
        #expect(decoded.windowID == "42")
        #expect(decoded.machineLabel == "host")
    }

    @Test("TerminalContext CodingKeys map snake_case correctly")
    func codingKeysMapping() throws {
        let json = """
        {
            "term_session_id": "t1",
            "iterm_session_id": "i1",
            "kitty_window_id": "k1",
            "wezterm_pane": "w1",
            "tty": "/dev/tty",
            "ppid": "99",
            "claude_project_dir": "/dir",
            "window_id": "55",
            "machine_label": "ml"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(TerminalContext.self, from: data)
        #expect(decoded.termSessionID == "t1")
        #expect(decoded.itermSessionID == "i1")
        #expect(decoded.kittyWindowID == "k1")
        #expect(decoded.weztermPane == "w1")
        #expect(decoded.claudeProjectDir == "/dir")
        #expect(decoded.windowID == "55")
    }
}
