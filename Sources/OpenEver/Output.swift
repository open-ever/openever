import ArgumentParser
import Foundation
import EverLiteClient
import SwiftExtensionsPack

enum BinaryEncoding: String, ExpressibleByArgument, CaseIterable {
    case base64, hex
}

struct OutputOptions: ParsableArguments {
    @Option(help: "Encoding for binary BOC/TL fields in JSON.") var binaryEncoding: BinaryEncoding = .base64
    @Flag(help: "Print compact JSON on a single line.") var compact = false

    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.sortedKeys, .prettyPrinted]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    func write<Value: Encodable>(_ value: Value) throws {
        try FileHandle.standardOutput.write(contentsOf: encode(value))
    }

    func binary(_ data: Data) -> BinaryOutput { BinaryOutput(data, encoding: binaryEncoding) }
    func boc(_ boc: BagOfCells) -> BinaryOutput { binary(boc.data) }
    func boc(_ boc: BagOfCells?) -> BinaryOutput? { boc.map { binary($0.data) } }
}

struct BinaryOutput: Encodable {
    let encoding: String
    let byteCount: Int
    let data: String

    init(_ bytes: Data, encoding: BinaryEncoding) {
        self.encoding = encoding.rawValue
        byteCount = bytes.count
        data = encoding == .base64 ? bytes.base64EncodedString() : bytes.toHexadecimal
    }
}

struct BlockOutput: Encodable {
    let workchain: Int32
    let shard: String
    let sequenceNumber: UInt32
    let rootHash: String
    let fileHash: String

    init(_ block: BlockID) {
        workchain = block.workchain
        shard = String(format: "0x%016llx", block.shard)
        sequenceNumber = block.sequenceNumber
        rootHash = block.rootHash.hex
        fileHash = block.fileHash.hex
    }
}

struct AccountStateOutput: Encodable {
    let account: String
    let block: BlockOutput
    let shardBlock: BlockOutput
    let shardProof: BinaryOutput
    let proof: BinaryOutput
    let state: BinaryOutput

    init(_ value: AccountState, account: AccountID, output: OutputOptions) {
        self.account = account.description
        block = BlockOutput(value.block)
        shardBlock = BlockOutput(value.shardBlock)
        shardProof = output.boc(value.shardProof)
        proof = output.boc(value.proof)
        state = output.boc(value.state)
    }
}

struct RunMethodOutput: Encodable {
    let account: String
    let methodID: String
    let mode: UInt32
    let block: BlockOutput
    let shardBlock: BlockOutput
    let exitCode: Int32
    let isSuccessful: Bool
    let result: BinaryOutput?
    let shardProof: BinaryOutput?
    let proof: BinaryOutput?
    let stateProof: BinaryOutput?
    let initialContext: BinaryOutput?
    let libraryExtras: BinaryOutput?

    init(_ value: RunMethodResult, account: AccountID, methodID: Int64, output: OutputOptions) {
        self.account = account.description
        self.methodID = String(methodID)
        mode = value.options.rawValue
        block = BlockOutput(value.block)
        shardBlock = BlockOutput(value.shardBlock)
        exitCode = value.exitCode
        isSuccessful = value.isSuccessful
        result = output.boc(value.result)
        shardProof = output.boc(value.shardProof)
        proof = output.boc(value.proof)
        stateProof = output.boc(value.stateProof)
        initialContext = output.boc(value.initialContext)
        libraryExtras = output.boc(value.libraryExtras)
    }
}

struct MessageOutput: Encodable {
    let status: Int32
    let isAccepted: Bool
}

struct TransactionOutput: Encodable {
    let account: String
    // Decimal strings preserve all 64 bits in JSON consumers such as JavaScript.
    let logicalTime: String
    let block: BlockOutput
    let proof: BinaryOutput
    let transaction: BinaryOutput

    init(_ value: TransactionInfo, account: AccountID, logicalTime: UInt64, output: OutputOptions) {
        self.account = account.description
        self.logicalTime = String(logicalTime)
        block = BlockOutput(value.block)
        proof = output.boc(value.proof)
        transaction = output.boc(value.transaction)
    }
}

struct TransactionsOutput: Encodable {
    let account: String
    let fromLogicalTime: String
    let fromHash: String
    let blocks: [BlockOutput]
    let transactions: BinaryOutput

    init(_ value: TransactionList, account: AccountID, from: TransactionID, output: OutputOptions) {
        self.account = account.description
        fromLogicalTime = String(from.logicalTime)
        fromHash = from.hash.hex
        blocks = value.blocks.map(BlockOutput.init)
        transactions = output.boc(value.transactions)
    }
}

struct QueryOutput: Encodable {
    let constructor: String
    let reply: BinaryOutput
}

struct RuntimeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
