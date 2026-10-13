import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main
struct GitVersionGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "GitVersionGenerator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected package and output directories"])
        }
        let packageDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let git = findGit().map {
            Git(executable: $0, packageDirectory: packageDirectory, outputDirectory: outputDirectory)
        }
        let version = git.map(version(using:)) ?? "0.0.0"
        let source = "enum BuildVersion {\n    static let value = \(String(reflecting: version))\n}\n"
        let output = outputDirectory.appendingPathComponent("BuildVersion.swift")
        if (try? String(contentsOf: output, encoding: .utf8)) != source {
            try source.write(to: output, atomically: true, encoding: .utf8)
        }
    }

    static func findGit() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        #if os(Windows)
        let separator: Character = ";"
        let name = "git.exe"
        #else
        let separator: Character = ":"
        let name = "git"
        #endif
        return path.split(separator: separator).lazy.compactMap { directory -> URL? in
            let path = String(directory).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let executable = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
            return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
        }.first
    }

    static func version(using git: Git) -> String {
        guard FileManager.default.fileExists(atPath: git.packageDirectory.appendingPathComponent(".git").path),
              let commit = git.run(["rev-parse", "--verify", "HEAD"]), !commit.isEmpty else {
            return "0.0.0"
        }
        // Ignore stat-only changes without refreshing the index or emitting file contents.
        let changes = git.run(["-c", "diff.autoRefreshIndex=false", "diff", "--no-ext-diff",
                               "--no-textconv", "--numstat", "HEAD", "--"]) ?? ""
        let dirty = changes.isEmpty ? "" : "-dirty"
        let localVersion = (git.run(["describe", "--tags"]) ?? "0.0.0") + dirty
        if git.run(["describe", "--tags", "--exact-match", "HEAD"]) != nil {
            return localVersion
        }

        #if os(Linux) || os(Windows)
        if let remote = remote(using: git),
           let refs = git.run(["ls-remote", "--tags", "--sort=-version:refname", remote]),
           let tag = matchingTag(in: refs, commit: commit) {
            let hash = git.run(["rev-parse", "--short", "HEAD"]) ?? String(commit.prefix(7))
            return "\(tag)-g\(hash)\(dirty)"
        }
        #endif
        return localVersion
    }

    static func remote(using git: Git) -> String? {
        let remotes = (git.run(["remote"]) ?? "").split(separator: "\n").map(String.init)
        if let branch = git.run(["symbolic-ref", "--quiet", "--short", "HEAD"]),
           let upstream = git.run(["config", "--get", "branch.\(branch).remote"]),
           remotes.contains(upstream) {
            return upstream
        }
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    static func matchingTag(in refs: String, commit: String) -> String? {
        var tags: [(name: String, object: String)] = []
        var peeled: [String: String] = [:]
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { continue }
            let name = String(fields[1].dropFirst("refs/tags/".count))
            if name.hasSuffix("^{}") {
                peeled[String(name.dropLast(3))] = String(fields[0])
            } else {
                tags.append((name, String(fields[0])))
            }
        }
        return tags.first { (peeled[$0.name] ?? $0.object) == commit }?.name
    }

    struct Git {
        let executable: URL
        let packageDirectory: URL
        let outputDirectory: URL

        func run(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--no-optional-locks", "-C", packageDirectory.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            // Swift Build may point DEVELOPER_DIR at a toolchain instead of Xcode.
            environment.removeValue(forKey: "DEVELOPER_DIR")
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GCM_INTERACTIVE"] = "Never"
            if environment["GIT_SSH_COMMAND"] == nil && environment["GIT_SSH"] == nil {
                environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=3 -o ConnectionAttempts=1"
            }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // A file avoids blocking on pipe capacity when a remote has many tags.
            let output = outputDirectory.appendingPathComponent(".git-output-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  let handle = try? FileHandle(forUpdating: output) else { return nil }
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: output)
            }
            process.standardOutput = handle
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do { try process.run() } catch { return nil }
            if finished.wait(timeout: .now() + 5) == .timedOut {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.5) == .timedOut {
                    #if os(macOS) || os(Linux)
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    #endif
                }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            do {
                try handle.seek(toOffset: 0)
                let data = try handle.readToEnd() ?? Data()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }
    }
}
