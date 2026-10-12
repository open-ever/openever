import Foundation
import EverLiteClient
import EverLiteClientTL
import EverTL

// Wire definitions: https://github.com/ton-blockchain/ton/blob/master/tl/generate/scheme/lite_api.tl
// The existing EverLiteClient.query API provides the ADNL envelope and server error handling.
struct LookupBlockRequest: TLConstructor, TLFunction {
    static let constructorID: UInt32 = 0xfac8f71e
    typealias Reply = BlockHeaderReply
    let workchain: Int32
    let shard: UInt64
    let sequenceNumber: UInt32

    static func readBare(from reader: inout TLReader) throws -> Self {
        let mode = try reader.read(UInt32.self, boxed: false)
        guard mode == 1 else { throw TLCodecError.unsupported("Only sequence-number block lookup is supported.") }
        return try Self(workchain: reader.read(Int32.self, boxed: false),
                        shard: UInt64(bitPattern: reader.read(Int64.self, boxed: false)),
                        sequenceNumber: UInt32(bitPattern: reader.read(Int32.self, boxed: false)))
    }

    func writeBare(to writer: inout TLWriter) throws {
        try writer.write(UInt32(1), boxed: false)
        // tonNode.blockId is a bare constructor in this request.
        try writer.write(workchain, boxed: false)
        try writer.write(Int64(bitPattern: shard), boxed: false)
        try writer.write(Int32(bitPattern: sequenceNumber), boxed: false)
    }
}

struct BlockHeaderReply: TLConstructor {
    static let constructorID: UInt32 = 0x752d8219
    let id: TonNodeBlockIdExtConstructor
    let mode: UInt32
    let headerProof: Data

    static func readBare(from reader: inout TLReader) throws -> Self {
        try Self(id: reader.read(TonNodeBlockIdExtConstructor.self, boxed: false),
                 mode: reader.read(UInt32.self, boxed: false), headerProof: reader.read(Data.self, boxed: false))
    }

    func writeBare(to writer: inout TLWriter) throws {
        try writer.write(id, boxed: false)
        try writer.write(mode, boxed: false)
        try writer.write(headerProof, boxed: false)
    }

    func blockID() throws -> BlockID {
        try BlockID(workchain: id.workchain, shard: UInt64(bitPattern: id.shard),
                    sequenceNumber: UInt32(bitPattern: id.seqno),
                    rootHash: Hash256(id.root_hash.data), fileHash: Hash256(id.file_hash.data))
    }
}

struct RawQueryRequest: TLFunction {
    typealias Reply = RawQueryReply
    let data: Data

    static func read(from reader: inout TLReader, boxed: Bool) throws -> Self {
        Self(data: try reader.readRaw(count: reader.remainingCount))
    }

    func write(to writer: inout TLWriter, boxed: Bool) throws { writer.writeRaw(data) }
}

struct RawQueryReply: TLSerializable {
    let data: Data

    static func read(from reader: inout TLReader, boxed: Bool) throws -> Self {
        guard reader.remainingCount >= 4 else { throw LiteClientError.invalidResponse("A boxed TL response must contain a constructor ID.") }
        return Self(data: try reader.readRaw(count: reader.remainingCount))
    }

    func write(to writer: inout TLWriter, boxed: Bool) throws { writer.writeRaw(data) }
}
