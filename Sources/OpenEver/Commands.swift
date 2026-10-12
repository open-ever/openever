import ArgumentParser
import Foundation
import EverLiteClient
import EverTL

struct AccountStateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "account-state",
        abstract: "Fetch an account's state BOC and proofs.",
        discussion: """
        Uses the latest applied masterchain block by default, or explicitly with --latest. --block SEQNO resolves an exact block ID before requesting the account state. The response includes the resolved masterchain/shard IDs, state and both proofs.

        Example:
          openever --config openever.json liteclient account-state --account 0:HEX --latest
        """,
        aliases: ["get-account-state"]
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var account: AccountOptions
    @OptionGroup var block: BlockOptions
    @OptionGroup var output: OutputOptions

    mutating func run() async throws {
        let value = try await connection.withClient { client in
            try await client.getAccountState(account: account.account, at: block.resolve(using: client))
        }
        try output.write(AccountStateOutput(value, account: account.account, output: output))
    }
}

struct RunMethodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-method",
        abstract: "Run a getter with a serialized TVM parameter-stack BOC.",
        discussion: """
        Provide a getter's --method-id or --method-name and its parameter-stack BOC using one --input-* option. --empty-params sends zero parameter bytes for servers that support this form. The result stack is requested by default; proof, context and library flags can be combined. --no-result omits the result bit from the mode.

        VM exit codes 0 and 1 succeed. Other VM exit codes print the response JSON and then make the command exit with status 1.

        Example:
          openever liteclient run-method --account 0:HEX --method-name get_balance --input-file stack.boc --block 12345 --account-proofs
        """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var account: AccountOptions
    @OptionGroup var block: BlockOptions
    @OptionGroup var method: MethodOptions
    @OptionGroup var input: BinaryInputOptions
    @OptionGroup var output: OutputOptions
    @Flag(help: "Send empty parameter bytes instead of a BOC; cannot be combined with --input-*.")
    var emptyParams = false

    mutating func validate() throws {
        if emptyParams {
            guard input.sourceCount == 0 else { throw ValidationError("--empty-params cannot be combined with --input-*.") }
        } else { try input.requireSource() }
    }

    mutating func run() async throws {
        let parameters = emptyParams ? BagOfCells(Data()) : try input.boc()
        let value = try await connection.withClient { client in
            try await client.runMethod(account: account.account, at: block.resolve(using: client),
                                       methodID: method.resolvedID, parameters: parameters, options: method.options)
        }
        try output.write(RunMethodOutput(value, account: account.account, methodID: method.resolvedID, output: output))
        if !value.isSuccessful { throw RuntimeError("The VM returned exit code \(value.exitCode).") }
    }
}

struct SendMessageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-message",
        abstract: "Submit a serialized message BOC to the lite server.",
        discussion: """
        Provide a BOC using exactly one --input-* option. The BOC is decoded locally before connecting. Status 1 means accepted by the lite server. Other statuses print the response JSON and make the command exit with status 1.

        Example:
          openever liteclient send-message --input-file message.boc
        """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var input: BinaryInputOptions
    @OptionGroup var output: OutputOptions

    mutating func validate() throws { try input.requireSource() }

    mutating func run() async throws {
        let message = try input.boc()
        let value = try await connection.withClient { try await $0.sendMessage(message) }
        try output.write(MessageOutput(status: value.status, isAccepted: value.isAccepted))
        if !value.isAccepted { throw RuntimeError("The lite server did not accept the message (status \(value.status)).") }
    }
}

struct TransactionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transaction",
        abstract: "Fetch one account transaction at an explicit block and logical time.",
        discussion: """
        --block SEQNO is required. The latest sentinel is supported by the library only for account-state and run-method. Add both block hashes to skip the block lookup.

        Example:
          openever liteclient transaction --account 0:HEX --block 12345 --lt 1000000000
        """,
        aliases: ["get-transaction"]
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var account: AccountOptions
    @OptionGroup var block: BlockOptions
    @OptionGroup var output: OutputOptions
    @Option(name: [.customLong("lt"), .customLong("logical-time")],
            help: "Transaction logical time as unsigned 64-bit decimal or hex.", transform: Input.unsigned64)
    var logicalTime: UInt64

    mutating func validate() throws { try block.requireExplicit() }

    mutating func run() async throws {
        let value = try await connection.withClient { client in
            try await client.getTransaction(account: account.account, at: block.resolve(using: client), logicalTime: logicalTime)
        }
        try output.write(TransactionOutput(value, account: account.account, logicalTime: logicalTime, output: output))
    }
}

struct TransactionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transactions",
        abstract: "Fetch account transactions starting from a logical-time/hash cursor.",
        discussion: """
        Both --lt and --hash are required to identify the starting transaction. The response preserves block order and the original transaction BOC. Logical times are printed as decimal strings to preserve all 64 bits in JSON.

        Example:
          openever liteclient transactions --account 0:HEX --lt 1000000000 --hash HEX --count 10
        """,
        aliases: ["get-transactions"]
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var account: AccountOptions
    @OptionGroup var output: OutputOptions
    @Option(name: [.customLong("lt"), .customLong("logical-time")],
            help: "Starting transaction logical time, unsigned 64-bit decimal or hex.", transform: Input.unsigned64)
    var logicalTime: UInt64
    @Option(name: .customLong("hash"), help: "Starting transaction hash, 64 hex digits or base64.", transform: Input.hash)
    var hash: Hash256
    @Option(help: "Number of transactions to request (1...4294967295).") var count: Int = 10

    mutating func validate() throws {
        guard count > 0, UInt32(exactly: count) != nil else { throw ValidationError("--count must be between 1 and 4294967295.") }
    }

    mutating func run() async throws {
        let cursor = TransactionID(logicalTime: logicalTime, hash: hash)
        let value = try await connection.withClient {
            try await $0.getTransactions(account: account.account, from: cursor, count: count)
        }
        try output.write(TransactionsOutput(value, account: account.account, from: cursor, output: output))
    }
}

struct LookupBlockCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lookup-block",
        abstract: "Resolve a block's full identifier, including root and file hashes.",
        discussion: """
        Provide --block SEQNO and optionally --block-workchain and --shard. The lite server must support liteServer.lookupBlock.

        Example:
          openever liteclient lookup-block --config openever.json --block 12345
        """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var block: BlockOptions
    @OptionGroup var output: OutputOptions

    mutating func validate() throws {
        try block.requireExplicit()
        guard block.rootHash == nil, block.fileHash == nil else {
            throw ValidationError("lookup-block resolves hashes; omit --root-hash and --file-hash.")
        }
    }

    mutating func run() async throws {
        let value = try await connection.withClient { try await block.resolve(using: $0) }
        try output.write(BlockOutput(value))
    }
}

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Send a boxed TL request and print its raw boxed TL response.",
        discussion: """
        Supply a serialized liteServer request using one --input-* option. Include the request constructor ID, without ADNL or liteServer.query envelopes. This command supports response constructors beyond the library's typed API. Server errors still cause a nonzero exit and an error on stderr.
        """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var input: BinaryInputOptions
    @OptionGroup var output: OutputOptions

    mutating func validate() throws { try input.requireSource() }

    mutating func run() async throws {
        let data = try input.read()
        guard data.count >= 4, data.count.isMultiple(of: 4) else {
            throw ValidationError("A boxed TL request must contain a constructor ID and have a length divisible by four.")
        }
        let value = try await connection.withClient { try await $0.query(RawQueryRequest(data: data)) }
        var reader = TLReader(data: value.data)
        let constructor = try reader.read(UInt32.self, boxed: false)
        try output.write(QueryOutput(constructor: String(format: "0x%08x", constructor), reply: output.binary(value.data)))
    }
}
