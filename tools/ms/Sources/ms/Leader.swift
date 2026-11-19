import Foundation

struct BindNode: Decodable {
    let key: String?
    let label: String?
    let type: String
    let value: String?
    let actions: [BindNode]?
}

struct BindConfig: Decodable { let actions: [BindNode] }

struct Bind {
    let path: String
    let label: String
    let type: String
    let value: String
    let depth: Int
    var json: [String: Any] { ["path": path, "label": label, "type": type, "value": value] }
}

func flattenBinds(_ nodes: [BindNode], prefix: [String] = [], depth: Int = 0) throws -> [Bind] {
    guard depth < 64 else { throw Failure("Leader Key config nesting exceeds 64 levels") }
    var result: [Bind] = []
    for node in nodes {
        // A keyless action inside a group is not individually addressable by Leader Key.
        guard let key = node.key, !key.isEmpty else { continue }
        let path = prefix + [key]
        let value = node.value ?? ""
        let label = node.label ?? (node.type == "application" || node.type == "folder"
                                  ? URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent : "")
        result.append(Bind(path: path.joined(separator: "/"), label: label, type: node.type, value: value, depth: depth))
        if node.type == "group" {
            result += try flattenBinds(node.actions ?? [], prefix: path, depth: depth + 1)
        }
    }
    return result
}

func liveBinds() throws -> [Bind] {
    let file = homeURL("Library/Application Support/Leader Key/config.json")
    do {
        let config = try JSONDecoder().decode(BindConfig.self, from: Data(contentsOf: file))
        return try flattenBinds(config.actions)
    } catch { throw Failure("cannot read live Leader Key config: \(error.localizedDescription)") }
}

func binds(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, values: ["--grep"], switches: ["--flat", "--tree"])
    try parsed.count(0)
    guard parsed.flags.count <= 1 else { throw Failure("choose --flat or --tree") }
    let tree = parsed.flags.contains("--tree")
    let all = try liveBinds()
    let matching = all.filter { bind in
        guard let query = parsed.options["--grep"] else { return true }
        return [bind.path, bind.label, bind.type, bind.value].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    // Tree searches retain ancestors so matches keep their navigation context.
    let rows = tree ? all.filter { bind in matching.contains { $0.path == bind.path || $0.path.hasPrefix(bind.path + "/") } } : matching
    let lines = rows.map { bind in
        "\(tree ? String(repeating: "  ", count: bind.depth) : "")\(bind.path) | \(oneLine(bind.label)) | \(bind.type)\(bind.value.isEmpty ? "" : " | \(oneLine(bind.value))")"
    }
    return Output(json: ["binds": rows.map(\.json), "format": tree ? "tree" : "flat"], text: lines.joined(separator: "\n"))
}

struct LaunchPlan {
    let executable: String
    let arguments: [String]
    let detached: Bool
}

func launchPlan(_ bind: Bind) throws -> LaunchPlan {
    guard !bind.value.isEmpty else { throw Failure("bind has no executable value") }
    switch bind.type {
    case "application":
        let value = expandedPath(bind.value)
        return LaunchPlan(executable: "/usr/bin/open", arguments: value.hasPrefix("/") ? ["--", value] : ["-a", value], detached: false)
    case "url":
        guard let url = URL(string: bind.value), let scheme = url.scheme else { throw Failure("bind URL requires a scheme") }
        let background = !["http", "https"].contains(scheme.lowercased())
        return LaunchPlan(executable: "/usr/bin/open", arguments: (background ? ["-g"] : []) + ["--", bind.value], detached: false)
    case "folder":
        return LaunchPlan(executable: "/usr/bin/open", arguments: ["--", expandedPath(bind.value)], detached: false)
    case "command":
        return LaunchPlan(executable: "/bin/zsh", arguments: ["-lc", bind.value], detached: true)
    default: throw Failure("bind type \(bind.type) cannot be run; choose an application, url, command or folder leaf")
    }
}

func runBind(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, switches: ["--dry-run"])
    try parsed.count(1)
    let path = parsed.positionals[0]
    let matches = try liveBinds().filter { $0.path == path }
    guard matches.count == 1, let bind = matches.first else {
        throw Failure(matches.isEmpty ? "unknown keypath: \(path)" : "ambiguous keypath: \(path)")
    }
    let plan = try launchPlan(bind)
    let dry = parsed.flags.contains("--dry-run")
    var pid: Int32?
    if !dry {
        pid = try process(plan.executable, plan.arguments, detached: plan.detached).1
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.machinespirit.leader.fired"), object: nil,
            userInfo: ["path": path], deliverImmediately: true)
    }
    var row = bind.json
    row["dryRun"] = dry
    row["executable"] = plan.executable
    row["arguments"] = plan.arguments
    row["detached"] = plan.detached
    row["pid"] = pid as Any? ?? NSNull()
    row["status"] = dry ? "dry-run" : "launched"
    return Output(json: row, text: "\(dry ? "Would run" : "Launched") \(path) [\(bind.type)]: \(plan.executable) \(try jsonString(plan.arguments))\(plan.detached ? " (detached; completion not monitored)" : "")")
}

func tmux(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args)
    let verb = parsed.positionals.first ?? "list"
    guard ["list", "revive", "detach"].contains(verb) else { throw Failure("tmux exposes only list, revive and detach") }
    guard parsed.positionals.count == (verb == "list" ? (parsed.positionals.isEmpty ? 0 : 1) : 2) else {
        throw Failure("usage: ms tmux [list | revive NAME | detach NAME]")
    }
    let core = homeURL("bin/sheol-core").path
    guard FileManager.default.isExecutableFile(atPath: core) else { throw Failure("~/bin/sheol-core is missing or not executable; run the machine-spirit installer") }
    let (raw, _) = try process(core, ["list", "--json"])
    let data = Data((raw.isEmpty ? "[]" : raw).utf8)
    guard let sessions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure("sheol-core returned invalid session JSON") }
    if verb == "list" {
        let text = sessions.map { row in
            "\(row["name"] as? String ?? "?") | \((row["attached"] as? Int ?? 0) > 0 ? "living" : "wandering") | \(row["command"] as? String ?? "?")"
        }.joined(separator: "\n")
        return Output(json: sessions, text: text.isEmpty ? "No tmux sessions." : text)
    }
    let name = parsed.positionals[1]
    guard sessions.contains(where: { $0["name"] as? String == name }) else { throw Failure("no tmux session named \(name)") }
    _ = try process(core, [verb, name])
    // sheol-core intentionally swallows some errors; don't claim verified attachment.
    return Output(json: ["action": verb, "name": name, "status": "requested"], text: "Requested tmux \(verb): \(name)")
}
