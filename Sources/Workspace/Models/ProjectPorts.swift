import Foundation

/// A TCP port a process rooted in this project is listening on.
struct ListeningPort: Identifiable, Sendable, Hashable {
    var port: Int
    var processName: String
    var pid: Int32

    var id: Int { port }
    var localURL: URL? { URL(string: "http://localhost:\(port)") }
}

/// Finds dev servers started inside a project folder.
///
/// `lsof` lists listening sockets, but says nothing about which project they
/// belong to, so every candidate process is checked for a working directory
/// under the project root.
enum ProjectPorts {
    static func scan(root: URL) async -> [ListeningPort] {
        let listeners = await Shell.runScript(
            "lsof -nP -iTCP -sTCP:LISTEN -F pcn 2>/dev/null",
            timeout: 20
        )
        guard listeners.isSuccess || !listeners.stdout.isEmpty else { return [] }

        // `-F pcn` prints one field per line: p<pid>, c<command>, n<address>.
        var candidates: [Int32: (name: String, ports: Set<Int>)] = [:]
        var pid: Int32?
        var command = ""

        for line in listeners.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let port = port(fromAddress: value) else { continue }
                candidates[pid, default: (command, [])].ports.insert(port)
                candidates[pid]?.name = command
            default:
                continue
            }
        }

        guard !candidates.isEmpty else { return [] }

        // One lsof call for every candidate's cwd, rather than one per process.
        let pids = candidates.keys.map(String.init).joined(separator: ",")
        let directories = await Shell.runScript(
            "lsof -a -p \(pids) -d cwd -Fn 2>/dev/null",
            timeout: 20
        )

        var cwdByPID: [Int32: String] = [:]
        var currentPID: Int32?
        for line in directories.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": currentPID = Int32(value)
            case "n":
                if let currentPID, cwdByPID[currentPID] == nil {
                    cwdByPID[currentPID] = value
                }
            default: continue
            }
        }

        let rootPath = root.standardizedFileURL.path
        var result: [ListeningPort] = []
        for (pid, entry) in candidates {
            guard let cwd = cwdByPID[pid] else { continue }
            guard cwd == rootPath || cwd.hasPrefix(rootPath + "/") else { continue }
            for port in entry.ports {
                result.append(ListeningPort(port: port, processName: entry.name, pid: pid))
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// `*:5173`, `127.0.0.1:3000`, `[::1]:8080` → the port number.
    private static func port(fromAddress address: String) -> Int? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        let tail = address[address.index(after: colon)...]
        return Int(tail)
    }
}
