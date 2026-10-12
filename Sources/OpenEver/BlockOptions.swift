import ArgumentParser
import EverLiteClient

struct BlockOptions: ParsableArguments {
    @Flag(help: "Use the latest applied masterchain block (default for account-state and run-method).")
    var latest = false
    @Option(name: [.customLong("block"), .customLong("seqno")],
            help: "Historical block sequence number. Resolves hashes using liteServer.lookupBlock.")
    var sequenceNumber: UInt32?
    @Option(help: "Block workchain; defaults to -1 (masterchain).") var blockWorkchain: Int32?
    @Option(help: "Shard as unsigned decimal or 0x hexadecimal; defaults to 0x8000000000000000.",
            transform: Input.unsigned64)
    var shard: UInt64?
    @Option(help: "Exact block root hash as 64 hex digits or base64; requires --file-hash.", transform: Input.hash)
    var rootHash: Hash256?
    @Option(help: "Exact block file hash as 64 hex digits or base64; requires --root-hash.", transform: Input.hash)
    var fileHash: Hash256?

    mutating func validate() throws {
        if latest && (sequenceNumber != nil || blockWorkchain != nil || shard != nil || rootHash != nil || fileHash != nil) {
            throw ValidationError("--latest cannot be combined with explicit block options.")
        }
        if sequenceNumber == nil && (blockWorkchain != nil || shard != nil || rootHash != nil || fileHash != nil) {
            throw ValidationError("Explicit block options require --block SEQNO.")
        }
        guard (rootHash != nil) == (fileHash != nil) else {
            throw ValidationError("Provide both --root-hash and --file-hash, or omit both to look them up.")
        }
        guard sequenceNumber != UInt32.max else {
            throw ValidationError("4294967295 is reserved for latest selection; use --latest.")
        }
        if let shard, shard == 0 { throw ValidationError("A shard identifier cannot be zero.") }
        if let blockWorkchain, blockWorkchain == -1, let shard, shard != BlockID.fullShard {
            throw ValidationError("Masterchain blocks require the full shard 0x8000000000000000.")
        }
        if blockWorkchain == nil, let shard, shard != BlockID.fullShard {
            throw ValidationError("A non-masterchain shard requires --block-workchain.")
        }
    }

    func requireExplicit() throws {
        guard !latest, sequenceNumber != nil else {
            throw ValidationError("This command requires --block SEQNO; latest selection is supported only by account-state and run-method.")
        }
    }

    func resolve(using client: LiteClient) async throws -> BlockID {
        guard let sequenceNumber else { return .latest }
        let workchain = blockWorkchain ?? -1
        let shard = shard ?? BlockID.fullShard
        if let rootHash, let fileHash {
            return BlockID(workchain: workchain, shard: shard, sequenceNumber: sequenceNumber,
                           rootHash: rootHash, fileHash: fileHash)
        }
        let response = try await client.query(LookupBlockRequest(workchain: workchain, shard: shard,
                                                               sequenceNumber: sequenceNumber))
        let block = try response.blockID()
        guard block.workchain == workchain, block.shard == shard, block.sequenceNumber == sequenceNumber else {
            throw LiteClientError.invalidResponse("Block lookup returned an identifier different from the requested block.")
        }
        return block
    }
}
