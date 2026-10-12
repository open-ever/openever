import ArgumentParser
import Foundation
import EverscaleSdkSwift

struct WalletSeedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed", abstract: "Generate an English BIP39 mnemonic."
    )

    @Option(help: "Number of words: 12 or 24.") var count = 12
    @Option(help: "Write the mnemonic as plain text to a new file instead of stdout.") var out: String?

    mutating func validate() throws {
        guard count == 12 || count == 24 else { throw ValidationError("--count must be 12 or 24.") }
    }

    mutating func run() throws {
        let mnemonic = try BIP39Mnemonic.generateMnemonic(wordsCount: count == 12 ? .w12 : .w24)
        try WalletOutput.write(mnemonic, to: out, sensitive: true)
    }
}

struct WalletKeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Derive Everscale Ed25519 keys from a BIP39 mnemonic.",
        discussion: """
        Uses the Everscale derivation path m/44'/396'/0'/0/0. With no seed input, generates a new 12-word mnemonic internally and outputs only its keys. To keep a mnemonic backup, generate it with wallet seed first and pass it with --seed-file.
        """
    )

    @OptionGroup var seedInput: WalletSeedInputOptions
    @Option(help: "Write keys JSON to a new file instead of stdout.") var out: String?

    func mnemonic() throws -> String {
        try seedInput.read() ?? BIP39Mnemonic.generateMnemonic(wordsCount: .w12)
    }

    mutating func run() throws {
        let keys = try WalletKeys.fromMnemonic(mnemonic())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(keys)
        data.append(10)
        try WalletOutput.write(data, to: out, sensitive: true)
    }
}
