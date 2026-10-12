import ArgumentParser
import Foundation
import BigInt
import EverLiteClient
import EverscaleSdkSwift
import SwiftExtensionsPack

struct WalletCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wallet", abstract: "Generate wallet keys and use Everscale wallets.",
        discussion: "Uses PreprocessedWalletV2 by default. Connection options may appear before or after the operation. Address generation works offline.",
        subcommands: [WalletSeedCommand.self, WalletKeysCommand.self]
            + PWV2Command.configuration.subcommands + [PWV2Command.self]
    )
    @OptionGroup var connection: ConnectionOptions
}

struct PWV2Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pwv2", abstract: "Use PreprocessedWalletV2.",
        discussion: "Connection options may appear before or after the operation. Address generation works offline.",
        subcommands: [PWV2BalanceCommand.self, PWV2AddressCommand.self, PWV2SendCommand.self],
        aliases: ["preprocessedWalletV2"]
    )
    @OptionGroup var connection: ConnectionOptions
}

struct PWV2AddressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "address", abstract: "Derive a PWV2 address from a BIP39 seed or public key.")
    @OptionGroup var keys: WalletKeyInputOptions
    @OptionGroup var chain: WalletWorkchainOptions
    @Option(help: "Write the raw address as plain text to a new file instead of stdout.") var out: String?

    mutating func validate() throws { try keys.requireSource() }

    mutating func run() throws {
        let keyPair = try keys.read(requireSecret: false)
        let wallet = try PWV2(publicKey: keyPair.publicKeyData(), workchain: chain.workchain)
        try WalletOutput.write(wallet.address.toString(), to: out)
    }
}

struct PWV2BalanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "balance", abstract: "Read the account balance and deployment status.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: OutputOptions
    @Option(parsing: .unconditional, help: "Account in workchain:hex, base64 or base64url format.",
            transform: WalletAddress.init) var account: WalletAddress

    mutating func run() async throws {
        let state = try await connection.withClient { client in
            let response = try await client.getAccountState(account: AccountID(account.address))
            return try PWV2AccountState.parse(response.state, expectedAddress: account.address)
        }
        try output.write(WalletBalanceOutput(account: account.address.toString(),
                                             nanoEver: String(state.balance), ever: WalletAmount.format(nanoEver: state.balance),
                                             status: state.status.rawValue))
    }
}

struct PWV2SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send", abstract: "Sign and submit one PWV2 transfer through the lite server.",
        discussion: """
        Fetches the wallet state and seqno automatically. A funded, uninitialized wallet is deployed with its first transfer. Exactly one of --ever and --nanoEver is required. --stateInit belongs to the destination contract. The bounce flag defaults to the friendly address flag, or false for raw addresses. A successful submission means the lite server accepted the message; it does not confirm a blockchain transaction.
        """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var keys: WalletKeyInputOptions
    @OptionGroup var chain: WalletWorkchainOptions
    @OptionGroup var payload: WalletPayloadOptions
    @OptionGroup var output: OutputOptions
    @Option(name: [.customLong("nanoEver"), .customLong("nano-ever")], help: "Amount as an integer number of nanoEVER.")
    var nanoEver: String?
    @Option(help: "Amount in EVER, with a dot or comma and up to nine fractional digits.") var ever: String?
    @Option(name: [.customLong("dest"), .customLong("destination")], parsing: .unconditional,
            help: "Destination in workchain:hex, base64 or base64url format.", transform: WalletAddress.init)
    var destination: WalletAddress
    @Option(help: "TVM send mode (0...255); default 3 pays fees separately and ignores action errors.") var flag: UInt8 = 3
    @Flag(inversion: .prefixedNo, help: "Override the destination message's bounce flag.") var bounce: Bool?
    @Option(help: "Message lifetime in seconds (1...3600).") var ttl: UInt64 = 60

    mutating func validate() throws {
        try keys.requireSource()
        _ = try amount()
        guard (1...3600).contains(ttl) else { throw ValidationError("--ttl must be between 1 and 3600 seconds.") }
        guard [keys.keysFile, keys.seedInput.seedFile, payload.bodyFile, payload.stateInitFile].filter({ $0 == "-" }).count <= 1 else {
            throw ValidationError("Only one input file may read stdin ('-').")
        }
        guard flag & 0xc0 != 0xc0 else { throw ValidationError("Send mode bits 64 and 128 cannot be combined.") }
    }

    func amount() throws -> BigUInt {
        guard (ever != nil) != (nanoEver != nil) else { throw ValidationError("Provide exactly one of --ever or --nanoEver.") }
        if let ever { return try WalletAmount.ever(ever) }
        guard let nanoEver else { throw ValidationError("Missing transfer amount.") }
        return try WalletAmount.nanoEver(nanoEver)
    }

    mutating func run() async throws {
        let keyPair = try keys.read()
        let wallet = try PWV2(publicKey: keyPair.publicKeyData(), workchain: chain.workchain)
        let amount = try amount()
        let contents = try payload.read()
        let result = try await connection.withClient { client in
            try await submit(using: client, wallet: wallet, secret: keyPair.secret(), amount: amount,
                             body: contents.body, stateInit: contents.stateInit)
        }
        try output.write(result)
        if !result.isAccepted { throw RuntimeError("The lite server did not accept the message (status \(result.status)).") }
    }

    func submit(using client: LiteClient, wallet: PWV2, secret: Data, amount: BigUInt,
                body: Cell?, stateInit: StateInit?) async throws -> WalletSendOutput {
        let response = try await client.getAccountState(account: AccountID(wallet.address))
        let state = try PWV2AccountState.parse(response.state, expectedAddress: wallet.address)
        let seqno = try wallet.sequenceNumber(in: state)
        guard state.balance > 0 else { throw RuntimeError("Fund the wallet address before sending its first transaction.") }
        let validUntil = UInt64(Date().timeIntervalSince1970) + ttl
        let message = try wallet.buildTransfer(destination: destination.address, nanoEver: amount, flag: flag,
                                              bounce: bounce ?? destination.bounce, body: body, stateInit: stateInit,
                                              seqno: seqno, secretKey: secret, deploy: state.needsDeployment,
                                              validUntil: validUntil).cell()
        let submission = try await client.sendMessage(message)
        return WalletSendOutput(account: wallet.address.toString(), destination: destination.address.toString(),
                                nanoEver: String(amount), seqno: seqno, messageHash: try message.hash(),
                                validUntil: validUntil, status: submission.status, isAccepted: submission.isAccepted)
    }
}

struct WalletBalanceOutput: Encodable {
    let account: String
    let nanoEver: String
    let ever: String
    let status: String
}

struct WalletSendOutput: Encodable {
    let account: String
    let destination: String
    let nanoEver: String
    let seqno: UInt16
    let messageHash: String
    let validUntil: UInt64
    let status: Int32
    let isAccepted: Bool
}
