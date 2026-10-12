import Foundation
import PackagePlugin

@main
struct GitVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("Generated")
        let packageDirectory = context.package.directoryURL
        let fileManager = FileManager.default
        var inputFiles = [packageDirectory]
        for path in [".git", ".git/HEAD", ".git/index", ".git/packed-refs", ".git/logs/HEAD",
                     ".git/refs", ".git/refs/heads", ".git/refs/tags"] {
            let url = packageDirectory.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) {
                inputFiles.append(url)
            }
        }
        if let files = fileManager.enumerator(at: packageDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in files {
                if [".git", ".build", ".swiftpm"].contains(url.lastPathComponent) {
                    files.skipDescendants()
                } else if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                    inputFiles.append(url)
                }
            }
        }
        let executable = URL(fileURLWithPath: "/bin/sh")
        let arguments = [
            "-c",
            #"""
            set -eu
            version=0.0.0
            if [ -e "$1/.git" ]; then
                version=$(git --no-optional-locks -C "$1" describe --tags --dirty 2>/dev/null) || version=0.0.0
            fi
            version=$(printf '%s' "$version" | sed 's/\\/\\\\/g; s/"/\\"/g')
            source=$(printf 'enum BuildVersion {\n    static let value = "%s"\n}\n' "$version")
            output="$2/BuildVersion.swift"
            mkdir -p "$2"
            if [ ! -f "$output" ] || [ "$(cat "$output")" != "$source" ]; then
                printf '%s\n' "$source" > "$output"
            fi
            """#,
            "GitVersionPlugin",
            context.package.directoryURL.path,
            outputDirectory.path
        ]
        return [
            .buildCommand(
                displayName: "Generate Git version",
                executable: executable,
                arguments: arguments,
                inputFiles: inputFiles,
                outputFiles: [outputDirectory.appendingPathComponent("BuildVersion.swift")]
            )
        ]
    }
}
