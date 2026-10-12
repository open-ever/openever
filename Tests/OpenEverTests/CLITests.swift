import Foundation
import Testing
import ArgumentParser
import EverLiteClient
import EverLiteClientTL
import EverTL
import EverscaleSdkSwift
@testable import OpenEver

private let zeroHash = String(repeating: "0", count: 64)
private let serverKey = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
private let connectionArguments = ["--host", "localhost", "--port", "3030", "--public-key", serverKey]

@Suite(.timeLimit(.minutes(1)))
struct CLITests {
    @Test func helpListsOptionsAtTheirCommandLevels() {
        let rootHelp = OpenEver.helpMessage()
        let liteHelp = OpenEver.helpMessage(for: LiteClientCommand.self)
        let queryHelp = OpenEver.helpMessage(for: QueryCommand.self)
        let configHelp = OpenEver.helpMessage(for: ConfigCommand.self)
        for help in [rootHelp, liteHelp, queryHelp, configHelp] {
            let options = help.components(separatedBy: "OPTIONS:").last ?? ""
            #expect(options.contains("--config <path>"))
            #expect(options.contains("OPENEVER_CONFIG"))
            #expect(options.contains("./openever.json"))
        }
        for help in [liteHelp, queryHelp] {
            let options = help.components(separatedBy: "OPTIONS:").last ?? ""
            #expect(options.contains("--ip"))
            #expect(options.contains("--port"))
            #expect(options.contains("--public-key"))
        }
        #expect(liteHelp.contains("after liteclient or after its operation"))
        for option in ["--read", "--create", "--path", "--out"] {
            #expect(configHelp.contains(option))
        }
    }

    @Test(arguments: [0, 1, 2])
    func configurationIsSharedAcrossCommandLevels(_ position: Int) async throws {
        try await withConfiguration("""
        {"liteclient":{"ip":"192.0.2.1","port":3030,"publicKey":"\(serverKey)"}}
        """) { directory in
            var arguments = ["liteclient", "query", "--input-hex", "01020304"]
            arguments.insert(contentsOf: ["--config", directory.appendingPathComponent("openever.json").path], at: position)
            let command = try #require(try await OpenEver.asyncParseAsRoot(arguments) as? QueryCommand)
            let server = try command.connection.resolvedServer(environment: [:])
            #expect(server.host == "192.0.2.1")
            #expect(server.port == 3030)
        }
    }

    @Test func connectionOptionsAreSharedBeforeAndAfterTheOperation() async throws {
        let command = try #require(try await OpenEver.asyncParseAsRoot(
            ["liteclient", "--ip", "127.0.0.1", "--connection-timeout", "3", "query",
             "--port", "4321", "--public-key", serverKey, "--request-timeout", "4", "--input-hex", "01020304"]
        ) as? QueryCommand)
        let server = try command.connection.resolvedServer(environment: [:])
        #expect(server.host == "127.0.0.1")
        #expect(server.port == 4321)
        #expect(server.publicKey == (try Input.hash(serverKey)).data)
        #expect(command.connection.connectionTimeout == 3)
        #expect(command.connection.requestTimeout == 4)
    }
    @Test(arguments: [[], ["--latest"]])
    func latestIsTheDefaultAndCanBeExplicit(_ arguments: [String]) async throws {
        let command = try #require(try await OpenEver.asyncParseAsRoot(
            ["liteclient", "account-state", "--account", "0:\(zeroHash)"] + connectionArguments + arguments
        ) as? AccountStateCommand)
        let transport = TestLiteTransport { _ in throw RuntimeError("No request was expected.") }
        let client = try testClient(transport)
        let block = try await command.block.resolve(using: client)
        #expect(block == .latest)
        #expect(await transport.requests.isEmpty)
        await client.close()
    }

    @Test func aliasesAndUnsignedLogicalTimes() async throws {
        let command = try #require(try await OpenEver.asyncParseAsRoot(
            ["liteclient", "get-transactions", "--account", "-1:\(zeroHash)", "--lt", String(UInt64.max),
             "--hash", zeroHash, "--count", String(UInt32.max)] + connectionArguments
        ) as? TransactionsCommand)
        #expect(command.logicalTime == .max)
        #expect(command.count == Int(UInt32.max))
        #expect(command.account.account.workchain == -1)
        #expect(try Input.unsigned64("0xffffffffffffffff") == UInt64.max)
        #expect(throws: (any Error).self) { try Input.unsigned64("18446744073709551616") }
        #expect(throws: (any Error).self) { try Input.unsigned64("-1") }
    }

    @Test(arguments: [0, -1, Int(UInt32.max) + 1])
    func invalidTransactionCountsAreRejected(_ count: Int) async {
        await #expect(throws: (any Error).self) {
            try await OpenEver.asyncParseAsRoot(
                ["liteclient", "transactions", "--account", "0:\(zeroHash)", "--lt", "1",
                 "--hash", zeroHash, "--count", String(count)] + connectionArguments
            )
        }
    }

    @Test(arguments: [
        ["--latest", "--block", "1"],
        ["--latest", "--root-hash", String(repeating: "0", count: 64)],
        ["--block", "1", "--root-hash", String(repeating: "0", count: 64)],
        ["--block", "1", "--file-hash", String(repeating: "0", count: 64)],
        ["--block-workchain", "0"],
        ["--shard", "0x8000000000000000"],
        ["--block", "4294967295"],
        ["--block", "4294967296"],
        ["--block", "1", "--shard", "0"],
        ["--block", "1", "--shard", "0x4000000000000000"],
        ["--block", "1", "--block-workchain=-1", "--shard", "0x4000000000000000"]
    ])
    func invalidBlockCombinations(_ arguments: [String]) throws {
        #expect(throws: (any Error).self) { try BlockOptions.parse(arguments) }
    }

    @Test func exactBlockPreservesHashesAndSkipsLookup() async throws {
        let root = String(repeating: "11", count: 32)
        let file = String(repeating: "22", count: 32)
        let options = try BlockOptions.parse(["--seqno", "17", "--block-workchain", "0", "--shard", "0x4000000000000000",
                                              "--root-hash", root, "--file-hash", file])
        let transport = TestLiteTransport { _ in throw RuntimeError("No request was expected.") }
        let client = try testClient(transport)
        let block = try await options.resolve(using: client)
        #expect(block.sequenceNumber == 17)
        #expect(block.workchain == 0)
        #expect(block.shard == 0x4000000000000000)
        #expect(block.rootHash.hex == root)
        #expect(block.fileHash.hex == file)
        #expect(await transport.requests.isEmpty)
        await client.close()
    }

    @Test(arguments: [[], ["--latest"]])
    func transactionRequiresAnExplicitBlock(_ blockArguments: [String]) async {
        await #expect(throws: (any Error).self) {
            try await OpenEver.asyncParseAsRoot(
                ["liteclient", "transaction", "--account", "0:\(zeroHash)", "--lt", "1"]
                + connectionArguments + blockArguments
            )
        }
    }

    @Test func methodFlagsAndNumericIDs() throws {
        let options = try MethodOptions.parse(["--method-id", "42", "--account-proofs", "--state-proof",
                                               "--initial-context", "--library-extras"])
        #expect(options.resolvedID == 42)
        #expect(options.options.rawValue == 31)
        #expect(try MethodOptions.parse(["--method-id=-1", "--no-result"]).resolvedID == -1)
        #expect(try MethodOptions.parse(["--method-id", "-1"]).resolvedID == -1)
        #expect(try MethodOptions.parse(["--method-id", "0xffffffffffffffff"]).resolvedID == -1)
        #expect(try MethodOptions.parse(["--method-name", "seqno"]).resolvedID == 85143)
        #expect(try MethodOptions.parse(["--method-id", "0", "--no-result"]).options.isEmpty)
        #expect(throws: (any Error).self) { try MethodOptions.parse([]) }
        #expect(throws: (any Error).self) { try MethodOptions.parse(["--method-id", "1", "--method-name", "seqno"]) }
    }

    @Test func mutuallyExclusiveBinaryInputsAndEmptyParameters() async throws {
        #expect(throws: (any Error).self) {
            try BinaryInputOptions.parse(["--input-hex", "00", "--input-base64", "AA=="])
        }
        let prefix = ["liteclient", "run-method", "--account", "0:\(zeroHash)", "--method-id", "0"] + connectionArguments
        await #expect(throws: (any Error).self) { try await OpenEver.asyncParseAsRoot(prefix) }
        _ = try await OpenEver.asyncParseAsRoot(prefix + ["--empty-params"])
        await #expect(throws: (any Error).self) {
            try await OpenEver.asyncParseAsRoot(prefix + ["--empty-params", "--input-hex", "00"])
        }
    }

    @Test func strictBinaryFormatsAndBOCValidation() throws {
        #expect(try Input.hex("0x00FF") == Data([0, 255]))
        #expect(try Input.base64("__8") == Data([255, 255]))
        #expect(throws: (any Error).self) { try Input.hex("abc") }
        #expect(throws: (any Error).self) { try Input.hex("0xgg") }
        #expect(throws: (any Error).self) { try Input.base64("%%AA") }
        #expect(throws: (any Error).self) { try Input.base64("A") }
        #expect(throws: (any Error).self) { try Input.hash("AA==") }
        let boc = try BagOfCells(cell: Cell(bits: [.b1, .b0]))
        let options = try BinaryInputOptions.parse(["--input-base64", boc.data.base64EncodedString()])
        #expect(try options.boc() == boc)
        #expect(throws: (any Error).self) { try BinaryInputOptions.parse(["--input-hex", "00"]).boc() }
    }

    @Test func legacyConnectionEnvironmentIsIgnored() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let settings = try ConnectionOptions.parse(connectionArguments)
        let server = try settings.resolvedServer(environment: ["OPENEVER_LITE_HOST": "wrong", "OPENEVER_LITE_PORT": "invalid"], directory: directory)
        #expect(server.host == "localhost")
        #expect(server.port == 3030)
        var environmentOnly = try ConnectionOptions.parse(connectionArguments)
        environmentOnly.host = nil
        environmentOnly.port = nil
        environmentOnly.publicKey = nil
        #expect(throws: (any Error).self) {
            try environmentOnly.resolvedServer(environment: ["OPENEVER_LITE_HOST": "127.0.0.1",
                                                             "OPENEVER_LITE_PORT": "1234",
                                                             "OPENEVER_LITE_PUBLIC_KEY": serverKey], directory: directory)
        }
        environmentOnly.serverIndex = 1
        #expect(throws: (any Error).self) { try environmentOnly.resolvedServer(environment: [:], directory: directory) }
    }

    @Test(arguments: [
        ([], "192.0.2.1", 3030, serverKey),
        (["--ip", "127.0.0.1"], "127.0.0.1", 3030, serverKey),
        (["--host", "example.test"], "example.test", 3030, serverKey),
        (["--port", "1234"], "192.0.2.1", 1234, serverKey),
        (["--public-key", String(repeating: "11", count: 32)], "192.0.2.1", 3030, String(repeating: "11", count: 32)),
        (["--ip", "127.0.0.1", "--port", "1234", "--public-key", String(repeating: "11", count: 32)],
         "127.0.0.1", 1234, String(repeating: "11", count: 32))
    ])
    func configurationDefaultsAndIndividualOverrides(_ fixture: ([String], String, Int, String)) throws {
        try withConfiguration("""
        {"liteclient":{"ip":"192.0.2.1","port":3030,"publicKey":"\(serverKey)"}}
        """) { directory in
            var settings = try ConnectionOptions.parse(fixture.0 + ["--config", directory.appendingPathComponent("openever.json").path])
            settings.config = nil
            let server = try settings.resolvedServer(environment: ["OPENEVER_LITE_HOST": "wrong",
                                                                   "OPENEVER_LITE_PORT": "invalid",
                                                                   "OPENEVER_LITE_PUBLIC_KEY": "invalid"], directory: directory)
            #expect(server.host == fixture.1)
            #expect(server.port == fixture.2)
            #expect(server.publicKey == (try Input.hash(fixture.3)).data)
        }
    }

    @Test func partialConfigurationRequiresCommandLineOverrides() throws {
        try withConfiguration("""
        {"liteclient":{"ip":null,"port":3030,"publicKey":null}}
        """) { directory in
            var settings = try ConnectionOptions.parse(connectionArguments)
            settings.host = nil
            settings.port = nil
            settings.publicKey = nil
            let environment = ["OPENEVER_LITE_HOST": "127.0.0.1", "OPENEVER_LITE_PORT": "1234",
                               "OPENEVER_LITE_PUBLIC_KEY": serverKey]
            #expect(throws: (any Error).self) { try settings.resolvedServer(environment: environment, directory: directory) }
            settings.host = "127.0.0.1"
            settings.publicKey = serverKey
            let server = try settings.resolvedServer(environment: environment, directory: directory)
            #expect(server.host == "127.0.0.1")
            #expect(server.port == 3030)
            #expect(server.publicKey == (try Input.hash(serverKey)).data)
        }
    }

    @Test(arguments: [
        "{",
        "{}",
        "{\"liteclient\":{}}",
        "{\"liteclient\":{\"ip\":\"127.0.0.1\",\"port\":0,\"publicKey\":\"\(serverKey)\"}}",
        "{\"liteclient\":{\"ip\":\"127.0.0.1\",\"port\":3030,\"publicKey\":\"invalid\"}}"
    ])
    func invalidConfigurationIsRejected(_ json: String) throws {
        try withConfiguration(json) { directory in
            #expect(throws: (any Error).self) {
                try ConnectionOptions.parse(["--config", directory.appendingPathComponent("openever.json").path]).resolvedServer(environment: [:])
            }
        }
    }

    @Test func explicitConfigurationPathsAndServerIndicesAreValidated() throws {
        try withConfiguration("""
        {"liteclient":{"ip":"192.0.2.1","port":3030,"publicKey":"\(serverKey)"}}
        """) { directory in
            var settings = try ConnectionOptions.parse(connectionArguments)
            settings.config = "openever.json"
            #expect(try settings.resolvedServer(environment: [:], directory: directory).host == "localhost")
            settings.config = "missing.json"
            #expect(throws: (any Error).self) { try settings.resolvedServer(environment: [:], directory: directory) }
            settings.config = "-"
            #expect(throws: (any Error).self) { try settings.resolvedServer(environment: [:], directory: directory) }
            settings.config = "openever.json"
            settings.serverIndex = 1
            #expect(throws: (any Error).self) { try settings.resolvedServer(environment: [:], directory: directory) }
            settings.serverIndex = 0
            settings.config = nil
            settings.host = nil
            settings.port = nil
            settings.publicKey = nil
            #expect(throws: (any Error).self) {
                try settings.resolvedServer(environment: [:], directory: directory.appendingPathComponent("missing", isDirectory: true))
            }
        }
    }

    @Test func configurationPathUsesCommandLineThenEnvironmentThenDefault() throws {
        try withConfiguration("""
        {"liteclient":{"ip":"192.0.2.1","port":3030,"publicKey":"\(serverKey)"}}
        """) { directory in
            let environmentPath = directory.appendingPathComponent("custom.json")
            try Data("""
            {"liteclient":{"ip":"192.0.2.2","port":5522,"publicKey":"\(serverKey)"}}
            """.utf8).write(to: environmentPath)
            var settings = try ConnectionOptions.parse(connectionArguments)
            settings.host = nil
            settings.port = nil
            settings.publicKey = nil
            let fromEnvironment = try settings.resolvedServer(environment: ["OPENEVER_CONFIG": environmentPath.path], directory: directory)
            #expect(fromEnvironment.host == "192.0.2.2")
            #expect(fromEnvironment.port == 5522)
            #expect(try settings.resolvedServer(environment: ["OPENEVER_CONFIG": "custom.json"], directory: directory) == fromEnvironment)
            #expect(try settings.resolvedServer(environment: ["OPENEVER_CONFIG": ""], directory: directory).host == "192.0.2.1")
            #expect(try settings.resolvedServer(environment: ["OpenEver_CONFIG": "missing.json"], directory: directory).host == "192.0.2.1")
            #expect(throws: (any Error).self) {
                try settings.resolvedServer(environment: ["OPENEVER_CONFIG": "missing.json"], directory: directory)
            }
            settings.config = "openever.json"
            let fromCommandLine = try settings.resolvedServer(environment: ["OPENEVER_CONFIG": "missing.json"], directory: directory)
            #expect(fromCommandLine.host == "192.0.2.1")
            #expect(fromCommandLine.port == 3030)
        }
    }

    @Test(arguments: ["--read", "--path"])
    func configCommandsUseTheSamePathPriority(_ mode: String) throws {
        let defaultContents = "{\"liteclient\":{\"ip\":\"192.0.2.1\"}}"
        try withConfiguration(defaultContents) { directory in
            let defaultFile = directory.appendingPathComponent("openever.json")
            let environmentFile = directory.appendingPathComponent("environment.json")
            let explicitFile = directory.appendingPathComponent("explicit.json")
            let environmentContents = "{\"liteclient\":{\"ip\":\"192.0.2.2\"}}\n"
            let explicitContents = "{\"liteclient\":{\"ip\":\"192.0.2.3\"}}\n"
            try Data(environmentContents.utf8).write(to: environmentFile)
            try Data(explicitContents.utf8).write(to: explicitFile)
            let cases: [([String], [String: String], URL, String)] = [
                (["config", mode], [:], defaultFile, defaultContents),
                (["config", mode], ["OPENEVER_CONFIG": ""], defaultFile, defaultContents),
                (["config", mode], ["OpenEver_CONFIG": "missing.json"], defaultFile, defaultContents),
                (["config", mode], ["OPENEVER_CONFIG": "environment.json"], environmentFile, environmentContents),
                (["config", mode], ["OPENEVER_CONFIG": environmentFile.path], environmentFile, environmentContents),
                (["--config", "explicit.json", "config", mode], ["OPENEVER_CONFIG": "environment.json"], explicitFile, explicitContents),
                (["config", mode, "--config", "./explicit.json"], ["OPENEVER_CONFIG": "missing.json"], explicitFile, explicitContents)
            ]
            for (arguments, environment, file, contents) in cases {
                let result = try runConfigCLI(arguments, directory: directory, environment: environment)
                #expect(result.status == 0, Comment(rawValue: result.error))
                #expect(result.error.isEmpty)
                #expect(result.output == Data((mode == "--path" ? file.path + "\n" : contents).utf8))
            }
        }
    }

    @Test(arguments: ["--read", "--path"])
    func configCommandsReportMissingFilesWithoutFallingBack(_ mode: String) throws {
        try withConfiguration("{}") { directory in
            for (arguments, environment) in [
                (["config", mode], ["OPENEVER_CONFIG": "missing.json"]),
                (["config", mode, "--config", "missing.json"], ["OPENEVER_CONFIG": "openever.json"]),
                (["config", mode, "--config", "."], [:])
            ] {
                let result = try runConfigCLI(arguments, directory: directory, environment: environment)
                #expect(result.status != 0)
                #expect(result.output.isEmpty)
                #expect(result.error.contains("Configuration not found"))
            }
            let emptyDirectory = directory.appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
            let result = try runConfigCLI(["config", mode], directory: emptyDirectory)
            #expect(result.status != 0)
            #expect(result.output.isEmpty)
            #expect(result.error.contains("Configuration not found"))
        }
    }

    @Test func configReadAndPathDoNotRequireValidJSON() throws {
        try withConfiguration("{") { directory in
            let read = try runConfigCLI(["config", "--read"], directory: directory)
            #expect(read.status == 0)
            #expect(read.output == Data("{".utf8))
            let path = try runConfigCLI(["config", "--path"], directory: directory)
            #expect(path.status == 0)
            #expect(path.output == Data((directory.appendingPathComponent("openever.json").path + "\n").utf8))
        }
    }

    @Test func configTemplateUsesEmptyFieldsAndSupportsFileOutput() throws {
        try withConfiguration("{\"liteclient\":{\"ip\":\"192.0.2.1\"}}") { directory in
            let printed = try runConfigCLI(["config", "--create"], directory: directory,
                                           environment: ["OPENEVER_CONFIG": "missing.json"])
            #expect(printed.status == 0, Comment(rawValue: printed.error))
            let template = try JSONDecoder().decode(OpenEverConfiguration.self, from: printed.output)
            #expect(template.liteclient?.ip == "")
            #expect(template.liteclient?.port == 0)
            #expect(template.liteclient?.publicKey == "")
            #expect(template.liteservers == nil)
            #expect(printed.output.last == 10)
            let stdout = try runConfigCLI(["config", "--create", "--out", "-"], directory: directory)
            #expect(stdout.status == 0)
            #expect(stdout.output == printed.output)
            let written = try runConfigCLI(["config", "--create", "--out", "./template.json"], directory: directory)
            #expect(written.status == 0, Comment(rawValue: written.error))
            #expect(written.output.isEmpty)
            let templateFile = directory.appendingPathComponent("template.json")
            #expect(try Data(contentsOf: templateFile) == printed.output)
            let repeated = try runConfigCLI(["config", "--create", "--out", "./template.json"], directory: directory)
            #expect(repeated.status != 0)
            #expect(repeated.error.contains("already exists"))
            #expect(try Data(contentsOf: templateFile) == printed.output)
            #expect(try String(contentsOf: directory.appendingPathComponent("openever.json"), encoding: .utf8)
                    == "{\"liteclient\":{\"ip\":\"192.0.2.1\"}}")
        }
    }

    @Test(arguments: [[], ["--read", "--path"], ["--create", "--read"], ["--create", "--path"],
                      ["--read", "--create", "--path"], ["--out", "file"],
                      ["--read", "--out", "file"], ["--path", "--out", "file"]])
    func invalidConfigModesAreRejected(_ arguments: [String]) throws {
        #expect(throws: (any Error).self) { try ConfigCommand.parse(arguments) }
    }

    @Test func globalConfigurationStillSupportsSelectionAndOverrides() throws {
        try withConfiguration("""
        {"liteservers":[{"ip":-1062731519,"port":3030,"id":{"key":"\(serverKey)"}},
        {"host":"example.test","port":1234,"id":{"key":"\(serverKey)"}}]}
        """) { directory in
            let path = directory.appendingPathComponent("openever.json").path
            let settings = try ConnectionOptions.parse(["--config", path, "--server-index", "1", "--port", "4321"])
            let server = try settings.resolvedServer(environment: [:])
            #expect(server.host == "example.test")
            #expect(server.port == 4321)
            #expect(server.publicKey == (try Input.hash(serverKey)).data)
            #expect(throws: (any Error).self) {
                try ConnectionOptions.parse(["--config", path, "--server-index", "2"]).resolvedServer(environment: [:])
            }
        }
    }

    @Test(arguments: ["0", "-1", "nan", "inf", "86401"])
    func invalidTimeouts(_ timeout: String) throws {
        #expect(throws: (any Error).self) {
            try ConnectionOptions.parse(connectionArguments + ["--request-timeout", timeout])
        }
        #expect(throws: (any Error).self) {
            try ConnectionOptions.parse(connectionArguments + ["--connection-timeout", timeout])
        }
    }

    @Test func signedIPv4Configuration() throws {
        let data = Data("""
        {"liteservers":[{"ip":-1062731519,"port":3030,"id":{"@type":"pub.ed25519","key":"\(serverKey)"}},
        {"host":"example.test","port":1234,"id":{"key":"\(serverKey)"}}]}
        """.utf8)
        let config = try JSONDecoder().decode(OpenEverConfiguration.self, from: data)
        let servers = try #require(config.liteservers)
        #expect(try servers[0].server().host == "192.168.1.1")
        #expect(try servers[1].server().host == "example.test")
    }

    @Test func lookupWireFormatHasTheCorrectBareBlockID() throws {
        let request = LookupBlockRequest(workchain: -1, shard: BlockID.fullShard, sequenceNumber: 12345)
        let encoded = try TLCodec.encode(request)
        #expect(encoded.count == 24)
        #expect(encoded == Data([0x1e, 0xf7, 0xc8, 0xfa, 1, 0, 0, 0, 255, 255, 255, 255,
                                0, 0, 0, 0, 0, 0, 0, 128, 0x39, 0x30, 0, 0]))
    }

    @Test func lookupResolvesBeforeAccountStateAndPreservesEveryField() async throws {
        let root = try TLBytes256(Data(repeating: 0x11, count: 32))
        let file = try TLBytes256(Data(repeating: 0x22, count: 32))
        let id = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 12345, root_hash: root, file_hash: file)
        let transport = TestLiteTransport { body in
            var reader = TLReader(data: body)
            let constructor = try reader.read(UInt32.self, boxed: false)
            if constructor == LookupBlockRequest.constructorID {
                let request = try TLCodec.decode(LookupBlockRequest.self, from: body)
                #expect(request.sequenceNumber == 12345)
                return try TLCodec.encode(BlockHeaderReply(id: id, mode: 1, headerProof: Data([7])))
            }
            let request = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: body)
            #expect(request.id == id)
            return try TLCodec.encode(LiteServerAccountStateConstructor(id: id, shardblk: id,
                                                                       shard_proof: Data([1]), proof: Data([2]), state: Data()))
        }
        let client = try testClient(transport)
        let block = try await BlockOptions.parse(["--block", "12345"]).resolve(using: client)
        let account = try AccountID("0:\(zeroHash)")
        let state = try await client.getAccountState(account: account, at: block)
        let output = try OutputOptions.parse(["--binary-encoding", "hex", "--compact"])
        let json = try #require(try JSONSerialization.jsonObject(with: output.encode(AccountStateOutput(state, account: account, output: output))) as? [String: Any])
        #expect((json["state"] as? [String: Any])?["data"] as? String == "")
        #expect((json["proof"] as? [String: Any])?["data"] as? String == "02")
        #expect((json["block"] as? [String: Any])?["rootHash"] as? String == String(repeating: "11", count: 32))
        #expect(await transport.requests.count == 2)
        await client.close()
        #expect(await transport.closed)
    }

    @Test func lookupRejectsMismatchedBlock() async throws {
        let transport = TestLiteTransport { _ in
            let id = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 99,
                                                  root_hash: TLBytes256(), file_hash: TLBytes256())
            return try TLCodec.encode(BlockHeaderReply(id: id, mode: 1, headerProof: Data()))
        }
        let client = try testClient(transport)
        await #expect(throws: LiteClientError.self) { try await BlockOptions.parse(["--block", "100"]).resolve(using: client) }
        await client.close()
    }

    @Test func rawQueriesSupportUnknownRepliesAndTypedServerErrors() async throws {
        let transport = TestLiteTransport { data in
            if data == Data([1, 2, 3, 4]) { return Data([5, 6, 7, 8]) }
            return try TLCodec.encode(LiteServerErrorConstructor(code: -400, message: "Test server error"))
        }
        let client = try testClient(transport)
        let reply = try await client.query(RawQueryRequest(data: Data([1, 2, 3, 4])))
        #expect(reply.data == Data([5, 6, 7, 8]))
        await #expect(throws: LiteClientError.server(code: -400, message: "Test server error")) {
            try await client.query(RawQueryRequest(data: Data([9, 10, 11, 12])))
        }
        await client.close()
    }
}

private func runConfigCLI(_ arguments: [String], directory: URL, environment: [String: String] = [:]) throws
    -> (status: Int32, output: Data, error: String) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = root.appendingPathComponent(".build/debug/openever")
    process.currentDirectoryURL = directory
    var variables = ProcessInfo.processInfo.environment
    for name in ["OPENEVER_CONFIG", "OpenEver_CONFIG", "OPENEVER_LITE_HOST", "OPENEVER_LITE_PORT", "OPENEVER_LITE_PUBLIC_KEY"] {
        variables.removeValue(forKey: name)
    }
    variables.merge(environment) { _, selected in selected }
    process.environment = variables
    process.arguments = arguments
    let output = Pipe(), error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            try output.fileHandleForReading.readToEnd() ?? Data(),
            String(decoding: try error.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self))
}

private func withConfiguration(_ json: String, _ operation: (URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent(".build/tmp/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(json.utf8).write(to: directory.appendingPathComponent("openever.json"))
    try operation(directory)
}

private func withConfiguration(_ json: String, _ operation: (URL) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent(".build/tmp/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(json.utf8).write(to: directory.appendingPathComponent("openever.json"))
    try await operation(directory)
}
