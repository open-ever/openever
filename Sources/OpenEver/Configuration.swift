import ArgumentParser
import Foundation

struct ConfigurationOptions: ParsableArguments {
    @Option(help: ArgumentHelp("JSON configuration path: --config overrides OPENEVER_CONFIG, then ./openever.json. May appear before or after subcommands.",
                               valueName: "path"))
    var config: String?

    func hasExplicitPath(environment: [String: String]) -> Bool {
        config != nil || !(environment["OPENEVER_CONFIG"] ?? "").isEmpty
    }

    func resolvedFile(environment: [String: String] = ProcessInfo.processInfo.environment,
                      directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) throws -> URL? {
        let environmentPath = environment["OPENEVER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        let selectedPath = config ?? environmentPath
        guard selectedPath != "-", selectedPath != "" else {
            throw ValidationError("The configuration requires a nonempty file path; stdin is reserved for other input.")
        }
        let url = URL(fileURLWithPath: selectedPath ?? "openever.json", relativeTo: directory).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return url
        }
        if selectedPath != nil { throw ValidationError("Configuration not found at '\(url.path)'.") }
        return nil
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read, locate or create a JSON configuration.",
        discussion: "--read and --path use --config, then OPENEVER_CONFIG, then ./openever.json in the current directory. A missing selected file is an error. --create prints an empty template; use --out to save it to a new file."
    )

    @OptionGroup var configurationOptions: ConfigurationOptions
    @Flag(help: "Print the selected configuration file as stored.") var read = false
    @Flag(help: "Print an empty default configuration template.") var create = false
    @Flag(help: "Print the absolute path to the selected configuration file.") var path = false
    @Option(help: "Write the template to a new file; requires --create. '-' writes stdout.") var out: String?

    mutating func validate() throws {
        guard [read, create, path].filter({ $0 }).count == 1 else {
            throw ValidationError("Provide exactly one of --read, --create or --path.")
        }
        guard out == nil || create else { throw ValidationError("--out requires --create.") }
    }

    mutating func run() throws {
        if create {
            try WalletOutput.write(OutputOptions.parse([]).encode(OpenEverConfiguration.empty), to: out)
            return
        }
        guard let url = try configurationOptions.resolvedFile() else {
            throw ValidationError("Configuration not found. Set --config or OPENEVER_CONFIG, or create ./openever.json.")
        }
        if path { print(url.path) }
        else { try FileHandle.standardOutput.write(contentsOf: Input.file(url.path)) }
    }
}
