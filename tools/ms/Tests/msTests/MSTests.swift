import Foundation
import Testing
@testable import ms

@Test func strictCLIParsing() throws {
    #expect(throws: Failure.self) { try Arguments(["--oops"]) }
    #expect(throws: Failure.self) { try Arguments(["--app"], values: ["--app"]) }
    #expect(throws: Failure.self) { try Arguments(["--tree", "--tree"], switches: ["--tree"]) }
    let parsed = try Arguments(["--app", "An app with spaces", "--", "--literal"], values: ["--app"])
    #expect(parsed.options["--app"] == "An app with spaces")
    #expect(parsed.positionals == ["--literal"])
}

@Test func bindPathsAndLiteralLaunchArguments() throws {
    let data = Data(#"{"actions":[{"key":"s","type":"group","actions":[{"key":"s","type":"group","actions":[{"key":"c","label":"Code","type":"command","value":"printf '%s' '$literal'"}]}]},{"key":"f","type":"folder","value":"~/Folder With Spaces"}]}"#.utf8)
    let config = try JSONDecoder().decode(BindConfig.self, from: data)
    let rows = try flattenBinds(config.actions)
    #expect(rows.map(\.path) == ["s", "s/s", "s/s/c", "f"])
    let plan = try launchPlan(rows[2])
    #expect(plan.arguments == ["-lc", "printf '%s' '$literal'"])
    #expect(plan.detached)
    #expect(throws: Failure.self) { try launchPlan(rows[0]) }
    #expect(try launchPlan(rows[3]).arguments == ["--", expandedPath("~/Folder With Spaces")])
}

@Test func schemaRejectsTypeConfusionAndUnexpectedKeys() throws {
    let specs = toolSpecs(allowClipboard: false)
    #expect(!specs.contains { $0.name == "clipboard" })
    #expect(toolSpecs(allowClipboard: true).contains { $0.name == "clipboard" })
    let screenshot = try #require(specs.first { $0.name == "screenshot" })
    #expect(throws: Failure.self) { try screenshot.validate(["screenId": true]) }
    #expect(throws: Failure.self) { try screenshot.validate(["screenId": 1.5]) }
    #expect(throws: Failure.self) { try screenshot.validate(["screenId": 0]) }
    #expect(throws: Failure.self) { try screenshot.validate(["screenId": "1"]) }
    #expect(throws: Failure.self) { try screenshot.validate(["injected": "value"]) }
    try screenshot.validate(["screenId": 1])
    let tmux = try #require(specs.first { $0.name == "tmux" })
    #expect(throws: Failure.self) { try tmux.validate(["action": "kill"]) }
    #expect(throws: Failure.self) { try toolArguments("tmux", ["action": "revive"]) }
    #expect(try toolArguments("focus", ["target": "--all-spaces"]) == ["--", "--all-spaces"])
}

@Test func invalidRectanglesAndFrameTolerance() throws {
    #expect(throws: Failure.self) { try captureRect("0,0,0,20") }
    #expect(throws: Failure.self) { try captureRect("nan,0,10,20") }
    #expect(throws: Failure.self) { try captureRect("0,0,10,20,30") }
    let frame = try captureRect("-100,20,640,480")
    #expect(frame.minX == -100)
    #expect(sameFrame(frame, frame.offsetBy(dx: 1, dy: 1)))
    #expect(!sameFrame(frame, frame.offsetBy(dx: 10, dy: 0)))
}

@Test @MainActor func protocolLifecycleAndErrors() throws {
    let server = MCPServer(allowClipboard: false)
    #expect((server.handle("{")?["error"] as? [String: Any])?["code"] as? Int == -32700)
    #expect((server.handle("[]")?["error"] as? [String: Any])?["code"] as? Int == -32600)
    #expect((server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["error"] as? [String: Any])?["code"] as? Int == -32002)
    let initialized = server.handle(#"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    #expect((initialized?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    let result = server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"] as? [String: Any]
    #expect((result?["tools"] as? [[String: Any]])?.count == 16)
    let disabled = server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"clipboard"}}"#)?["result"] as? [String: Any]
    #expect(disabled?["isError"] as? Bool == true)
    let wrongArgs = server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"windows","arguments":{"allSpaces":1}}}"#)?["result"] as? [String: Any]
    #expect(wrongArgs?["isError"] as? Bool == true)
    #expect((server.handle(#"{"jsonrpc":"2.0","id":5,"method":"nonexistent"}"#)?["error"] as? [String: Any])?["code"] as? Int == -32601)
    #expect(server.handle(#"{"jsonrpc":"2.0","method":"anything"}"#) == nil)
}

@Test func clipboardArchiveDates() throws {
    let archive = try JSONDecoder().decode(ClipboardArchive.self, from: Data(#"{"version":1,"entries":[{"id":"00000000-0000-0000-0000-000000000001","fingerprint":"ignored","kind":"text","text":"example","pinned":false,"date":0}]}"#.utf8))
    #expect(archive.entries[0].date.ISO8601Format() == "2001-01-01T00:00:00Z")
    #expect(archive.entries[0].text == "example")
}
