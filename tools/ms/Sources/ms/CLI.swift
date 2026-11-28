import Foundation
import Darwin

let usage = """
ms — structured access to this Mac (append --json for machine-readable output)
  screens
  apps
  windows [--app NAME] [--all-spaces] [--all-layers]
  focus <app-name|bundle-id|window-id>
  mouse
  win place <smart|aim|toggle-fullscreen|step|amm|max|left|right|top|bottom|tl|tr|bl|br|center|fullscreen|display-left|display-right|display-up|display-down|display-next|display-previous|half-up|half-down> [--app NAME]
  win rectangle <rectangle://execute-action?name=ACTION>
  win <tile-all|hide-all>
  win cycle [--app NAME]
  binds [--flat|--tree] [--grep TEXT]
  run <keypath> [--dry-run]
  tmux [list | revive NAME | detach NAME]
  stats
  capslock [on|off|toggle|status]
  audio [list|tile]
  translate-area [--to LANG]
  pulse [collect [--alert]|disk [--crash-preview|--explain]|report [--hours N]]
  screenshot [--screen ID | --window ID | --rect x,y,w,h] [--out PATH]
  clipboard [list [-n 20] | get INDEX]  (requires MS_ALLOW_CLIPBOARD=1)
  mcp  (newline-delimited JSON-RPC on stdio; --json has no effect)
"""

@MainActor
func command(_ name: String, _ args: [String]) throws -> Output {
    switch name {
    case "screens": try Arguments(args).count(0); return screens()
    case "apps": try Arguments(args).count(0); return apps()
    case "windows": return try windows(args)
    case "focus": return try focus(args)
    case "mouse": try Arguments(args).count(0); return try mouse()
    case "win": return try win(args)
    case "binds": return try binds(args)
    case "run": return try runBind(args)
    case "tmux": return try tmux(args)
    case "messages-find": return try messagesFind(args)
    case "capslock": return try capslock(args)
    case "audio": return try audio(args)
    case "pulse": return try pulse(args)
    case "stats": try Arguments(args).count(0); return try stats()
    case "screenshot": return try screenshot(args)
    case "clipboard": return try clipboard(args)
    default: throw Failure("unknown command: \(name); see ms --help")
    }
}

@main
struct MS {
    @MainActor static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        // Consume global --json only before `--`, preserving literal positional values.
        let end = args.firstIndex(of: "--") ?? args.count
        let json = args.prefix(end).contains("--json")
        args = args.enumerated().filter { !($0.offset < end && $0.element == "--json") }.map(\.element)
        do {
            guard let name = args.first, name != "--help", name != "help" else {
                print(json ? try jsonString(["help": usage]) : usage)
                return
            }
            if name == "mcp" {
                try Arguments(Array(args.dropFirst())).count(0)
                MCPServer().serve()
            } else {
                let output: Output
                if name == "translate-area" { output = try await translateArea(Array(args.dropFirst())) }
                else if name == "pulse" { output = try await pulseCLI(Array(args.dropFirst())) }
                else if name == "win", args.dropFirst().first == "rectangle" {
                    output = try await runRectangleAction(Array(args.dropFirst(2)))
                }
                else { output = try command(name, Array(args.dropFirst())) }
                print(json ? try jsonString(output.json) : output.text)
            }
        } catch {
            if (error as? Failure)?.message == "", (error as? Failure)?.exitCode == 11 { exit(11) }
            FileHandle.standardError.write(Data(("ms: \(oneLine(error.localizedDescription))\n").utf8))
            exit((error as? Failure)?.exitCode ?? 1)
        }
    }
}
