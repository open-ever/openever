import Foundation
import PackagePlugin

@main
struct GitVersionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("Generated")
        let packageDirectory = context.package.directoryURL
        let fileManager = FileManager.default
        var inputFiles = [packageDirectory]
        for path in [".git", ".git/HEAD", ".git/index", ".git/config", ".git/packed-refs", ".git/logs/HEAD",
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
        let executable = try context.tool(named: "GitVersionGenerator").url
        let arguments = [
            packageDirectory.path,
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
