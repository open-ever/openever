import Foundation
import Testing
import NIOCore
import NIOPosix
import EverLiteClient
import EverLiteClientTL
import EverTL
import EverscaleSdkSwift
import SwiftExtensionsPack
import adnl_swift
@testable import OpenEver

@Suite(.timeLimit(.minutes(1)))
struct CommandIntegrationTests {
    @Test(arguments: [false, true])
    func walletTransfersFetchStateAndSubmitSignedMessages(_ active: Bool) async throws {
        let pair = SEPCrypto.Ed25519.createKeyPair(seed32Byte: Data(repeating: 1, count: 32))
        let wallet = try PWV2(publicKey: pair.public, workchain: -1)
        let seqno: UInt16 = active ? 37 : 0
        let state = try CellBuilder().storeBit(.b1).storeAddress(wallet.address)
            .storeVarUInt(0, 7).storeVarUInt(0, 7).storeVarUInt(0, 7)
            .storeUInt(0, 32).storeBit(.b0).storeUInt(0, 64)
            .storeSlice(CurrencyCollection(grams: 10_000_000_000).cell().parse())
        if active {
            let data = try CellBuilder().storeBytes(pair.public).storeUInt(37, 16).cell()
            let initData = try StateInit(options: StateInitOptions(code: wallet.stateInit.data.code, data: data))
            try state.storeBit(.b1).storeSlice(initData.cell().parse())
        } else { try state.storeBits([.b0, .b0]) }
        let stateBOC = try state.cell().toBoc()
        let account = try AccountID(wallet.address)
        let keyJSON = "{\"privatKey\":\"\(Data(repeating: 1, count: 32).toHexadecimal)\",\"publicKey\":\"\(pair.public.toHexadecimal)\"}"
        let result = try await withCLI(arguments: [
            "send", "--keys", keyJSON, "--w", "-1", "--destination", "0:\(String(repeating: "1", count: 64))",
            "--ever", "1,45"
        ], commandPath: ["wallet", "preprocessedWalletV2"]) { body in
            var reader = TLReader(data: body)
            if try reader.read(UInt32.self, boxed: false) == LiteServerGetAccountStateRequest.constructorID {
                let request = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: body)
                #expect(request.account.workchain == account.workchain)
                #expect(request.account.id.data == account.hash.data)
                #expect(request.id.seqno == -1)
                let id = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 55,
                                                       root_hash: TLBytes256(), file_hash: TLBytes256())
                return try TLCodec.encode(LiteServerAccountStateConstructor(id: id, shardblk: id,
                    shard_proof: Data(), proof: Data(), state: stateBOC))
            }
            let sent = try TLCodec.decode(LiteServerSendMessageRequest.self, from: body)
            let cell = try #require(try BagOfCells(sent.body).singleCell())
            let message = try Message.parse(cs: cell.parse())
            #expect((message.data.stateInit != nil) == !active)
            let signedBody = try #require(message.data.body).parse()
            #expect(try signedBody.loadBytes(size: 64).count == 64)
            let inner = try signedBody.loadRef().parse()
            #expect(try inner.loadBigUInt(size: 64) > 0)
            #expect(try inner.loadBigUInt(size: 16) == seqno)
            return try TLCodec.encode(LiteServerSendMsgStatusConstructor(status: 1))
        }
        #expect(result.status == 0, Comment(rawValue: result.error))
        let json = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        #expect(json["isAccepted"] as? Bool == true)
        #expect(json["nanoEver"] as? String == "1450000000")
        #expect(json["seqno"] as? UInt16 == seqno)
        #expect(json["account"] as? String == wallet.address.toString())
    }

    @Test func walletBalanceHandlesAbsentAccounts() async throws {
        let result = try await withCLI(arguments: ["balance", "--account", "-1:\(String(repeating: "0", count: 64))"],
                                       commandPath: ["wallet", "pwv2"]) { body in
            let request = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: body)
            #expect(request.account.workchain == -1)
            let id = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 55,
                                                   root_hash: TLBytes256(), file_hash: TLBytes256())
            return try TLCodec.encode(LiteServerAccountStateConstructor(id: id, shardblk: id,
                shard_proof: Data(), proof: Data(), state: Data()))
        }
        #expect(result.status == 0, Comment(rawValue: result.error))
        let json = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        #expect(json["nanoEver"] as? String == "0")
        #expect(json["ever"] as? String == "0")
        #expect(json["status"] as? String == "nonexistent")
    }

    @Test(arguments: ["account-state", "run-method", "send-message", "transaction", "transactions", "lookup-block", "query"], CLIConnectionSource.allCases)
    func commandsUseTheirADNLRequestsAndPrintJSON(_ operation: String, _ connectionSource: CLIConnectionSource) async throws {
        let boc = try BagOfCells(cell: Cell(bits: [.b1]))
        let id = try TonNodeBlockIdExtConstructor(
            workchain: -1, shard: Int64.min, seqno: 55,
            root_hash: TLBytes256(Data(repeating: 0x11, count: 32)),
            file_hash: TLBytes256(Data(repeating: 0x22, count: 32))
        )
        let zero = String(repeating: "0", count: 64)
        let arguments: [String]
        switch operation {
        case "account-state": arguments = ["--account", "0:\(zero)", "--latest"]
        case "run-method":
            arguments = ["--account", "0:\(zero)", "--method-id", "42", "--input-base64", boc.data.base64EncodedString(),
                         "--account-proofs", "--state-proof", "--initial-context", "--library-extras"]
        case "send-message": arguments = ["--input-file", "-"]
        case "transaction": arguments = ["--account", "0:\(zero)", "--block", "55", "--lt", String(UInt64.max)]
        case "transactions": arguments = ["--account", "0:\(zero)", "--lt", String(UInt64.max), "--hash", zero, "--count", "2"]
        case "lookup-block": arguments = ["--block", "55"]
        default: arguments = ["--input-hex", "01020304"]
        }
        let result = try await withCLI(arguments: [operation] + arguments, stdin: operation == "send-message" ? boc.data : nil,
                                       connectionSource: connectionSource) { body in
            var reader = TLReader(data: body)
            let constructor = try reader.read(UInt32.self, boxed: false)
            if constructor == LookupBlockRequest.constructorID {
                #expect(["transaction", "lookup-block"].contains(operation))
                return try TLCodec.encode(BlockHeaderReply(id: id, mode: 1, headerProof: Data()))
            }
            switch operation {
            case "account-state":
                let request = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: body)
                #expect(request.id.seqno == -1)
                return try TLCodec.encode(LiteServerAccountStateConstructor(id: id, shardblk: id,
                                                                           shard_proof: Data(), proof: Data(), state: boc.data))
            case "run-method":
                let request = try TLCodec.decode(LiteServerRunSmcMethodRequest.self, from: body)
                #expect(request.mode == 31)
                #expect(request.method_id == 42)
                #expect(request.params == boc.data)
                return try TLCodec.encode(LiteServerRunMethodResultConstructor(
                    id: id, shardblk: id, shard_proof: Data([1]), proof: Data([2]), state_proof: Data([3]),
                    init_c7: Data([4]), lib_extras: Data([5]), exit_code: 0, result: boc.data))
            case "send-message":
                #expect(try TLCodec.decode(LiteServerSendMessageRequest.self, from: body).body == boc.data)
                return try TLCodec.encode(LiteServerSendMsgStatusConstructor(status: 1))
            case "transaction":
                let request = try TLCodec.decode(LiteServerGetOneTransactionRequest.self, from: body)
                #expect(request.id == id)
                #expect(request.lt == -1)
                return try TLCodec.encode(LiteServerTransactionInfoConstructor(id: id, proof: Data(), transaction: boc.data))
            case "transactions":
                let request = try TLCodec.decode(LiteServerGetTransactionsRequest.self, from: body)
                #expect(request.lt == -1)
                #expect(request.count == 2)
                return try TLCodec.encode(LiteServerTransactionListConstructor(ids: [id, id], transactions: boc.data))
            default:
                #expect(body == Data([1, 2, 3, 4]))
                return Data([5, 6, 7, 8])
            }
        }
        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(result.error.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        switch operation {
        case "account-state": #expect((json["state"] as? [String: Any])?["data"] as? String == boc.data.base64EncodedString())
        case "run-method":
            #expect(json["isSuccessful"] as? Bool == true)
            for field in ["result", "shardProof", "proof", "stateProof", "initialContext", "libraryExtras"] {
                #expect(json[field] is [String: Any])
            }
        case "send-message": #expect(json["isAccepted"] as? Bool == true)
        case "transaction": #expect(json["logicalTime"] as? String == String(UInt64.max))
        case "transactions": #expect((json["blocks"] as? [[String: Any]])?.count == 2)
        case "lookup-block": #expect(json["rootHash"] as? String == String(repeating: "11", count: 32))
        default: #expect(json["constructor"] as? String == "0x08070605")
        }
    }

    @Test(arguments: ["send-message", "run-method"])
    func unsuccessfulResponsesKeepJSONAndSetExitStatus(_ operation: String) async throws {
        let zero = String(repeating: "0", count: 64)
        let boc = try BagOfCells(cell: Cell(bits: [.b1]))
        let arguments = operation == "send-message" ? ["--input-base64", boc.data.base64EncodedString()]
            : ["--account", "0:\(zero)", "--method-id", "0", "--empty-params"]
        let result = try await withCLI(arguments: [operation] + arguments) { _ in
            if operation == "send-message" { return try TLCodec.encode(LiteServerSendMsgStatusConstructor(status: -1)) }
            let id = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 55,
                                                  root_hash: TLBytes256(), file_hash: TLBytes256())
            return try TLCodec.encode(LiteServerRunMethodResultConstructor(id: id, shardblk: id, exit_code: -256))
        }
        #expect(result.status == 1)
        #expect(!result.error.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        #expect(json[operation == "send-message" ? "isAccepted" : "isSuccessful"] as? Bool == false)
    }

    @Test func serverErrorsUseStderrAndNonzeroExit() async throws {
        let result = try await withCLI(arguments: ["query", "--input-hex", "01020304"]) { _ in
            try TLCodec.encode(LiteServerErrorConstructor(code: -400, message: "Test server error"))
        }
        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.error.contains("-400"))
        #expect(result.error.contains("Test server error"))
    }
}

enum CLIConnectionSource: String, CaseIterable {
    case arguments, defaultConfiguration, environmentConfiguration, explicitConfiguration, rootConfiguration, liteClientConfiguration
}

private struct CLIResult {
    let status: Int32
    let output: Data
    let error: String
}

private func withCLI(arguments: [String], stdin: Data? = nil, connectionSource: CLIConnectionSource = .arguments,
                     commandPath: [String] = ["liteclient"],
                     reply: @escaping @Sendable (Data) throws -> Data) async throws -> CLIResult {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let listener: any Channel
    do {
        listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CLIPeer(reply: reply))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    } catch {
        try await group.shutdownGracefully()
        throw error
    }
    do {
        let port = try #require(listener.localAddress?.port)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/openever")
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for name in ["OPENEVER_LITE_HOST", "OPENEVER_LITE_PORT", "OPENEVER_LITE_PUBLIC_KEY", "OpenEver_CONFIG"] {
            environment.removeValue(forKey: name)
        }
        let key = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
        var rootArguments: [String] = []
        var liteClientArguments: [String] = []
        var connectionArguments: [String] = []
        if connectionSource == .arguments {
            connectionArguments = ["--host", "127.0.0.1", "--port", String(port), "--public-key", key]
        } else {
            let json = """
            {"liteclient":{"ip":"127.0.0.1","port":\(port),"publicKey":"\(key)"}}
            """
            let fileName = connectionSource == .defaultConfiguration ? "openever.json" : "custom.json"
            try Data(json.utf8).write(to: directory.appendingPathComponent(fileName))
            if connectionSource == .environmentConfiguration { environment["OpenEver_CONFIG"] = fileName }
            if [.explicitConfiguration, .rootConfiguration, .liteClientConfiguration].contains(connectionSource) {
                switch connectionSource {
                case .rootConfiguration: rootArguments = ["--config", fileName]
                case .liteClientConfiguration: liteClientArguments = ["--config", fileName]
                default: connectionArguments = ["--config", fileName]
                }
                environment["OpenEver_CONFIG"] = "missing.json"
            }
        }
        process.environment = environment
        process.arguments = rootArguments + commandPath + liteClientArguments + arguments + connectionArguments + [
            "--connection-timeout", "2", "--request-timeout", "2", "--compact"
        ]
        let output = Pipe(), error = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input
        try process.run()
        if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let result = CLIResult(status: process.terminationStatus,
                               output: try output.fileHandleForReading.readToEnd() ?? Data(),
                               error: String(decoding: try error.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self))
        try await listener.close().get()
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await listener.close().get()
        try? await group.shutdownGracefully()
        throw error
    }
}

private final class CLIPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let reply: @Sendable (Data) throws -> Data
    private var handshake = Data()
    private var pending = Data()
    private var cipher: ADNLCipher?

    init(reply: @escaping @Sendable (Data) throws -> Data) { self.reply = reply }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            var bytes = Data(unwrapInboundIn(data).readableBytesView)
            if cipher == nil {
                let needed = min(256 - handshake.count, bytes.count)
                handshake.append(bytes.prefix(needed))
                bytes.removeFirst(needed)
                guard handshake.count == 256 else { return }
                let server = try ADNLHandshake.adnlHandshakeAssets(
                    handshake, secretKey: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
                cipher = server
                write(try server.encryptor.adnlSerializeMessage(data: Data()), context: context)
            }
            guard let cipher else { return }
            pending.append(try cipher.decryptor.update(bytes))
            while let packet = try ADNLPacket.parse(data: pending) {
                pending.removeFirst(packet.length)
                let query = try TLCodec.decode(AdnlMessageQueryConstructor.self, from: packet.payload)
                let request = try TLCodec.decode(LiteServerQueryRequest.self, from: query.query)
                let answer = try TLCodec.encode(AdnlMessageAnswerConstructor(query_id: query.query_id, answer: reply(request.data)))
                write(try cipher.encryptor.adnlSerializeMessage(data: answer), context: context)
            }
        } catch { context.close(promise: nil) }
    }

    private func write(_ data: Data, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: data)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
