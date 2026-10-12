import ArgumentParser
import Foundation
import Testing
import BigInt
import EverLiteClient
import EverLiteClientTL
import EverTL
import EverscaleSdkSwift
import SwiftExtensionsPack
@testable import OpenEver

struct WalletCLITests {
    private let mnemonic = "squirrel guess pigeon limit fine gorilla general glide pyramid warfare memory decorate"
    private let publicKey = "484447bbdb4bbd79bb9fad089588e7b1d89cdd87f87be5c6d75a5048369e11d0"
    private let privateKey = "de597db582a8f93335be796278f5c87df7e6b16d1c7f4402a0f5c712d5730f81"
    private var keysJSON: String { "{\"privatKey\":\"\(privateKey)\",\"publicKey\":\"\(publicKey)\"}" }
    private var destination: String { "-1:" + String(repeating: "11", count: 32) }

    @Test(arguments: [[], ["pwv2"], ["preprocessedWalletV2"]])
    func walletCommandsAndAliasesParse(_ walletType: [String]) async throws {
        let commandPath = ["wallet"] + walletType
        #expect(try await OpenEver.asyncParseAsRoot(["wallet", "seed"]) is WalletSeedCommand)
        #expect(try await OpenEver.asyncParseAsRoot(["wallet", "keys"]) is WalletKeysCommand)
        let address = try #require(try await OpenEver.asyncParseAsRoot(
            commandPath + ["address", "--keys", keysJSON]
        ) as? PWV2AddressCommand)
        #expect(address.chain.workchain == 0)
        #expect(try await OpenEver.asyncParseAsRoot(
            commandPath + ["balance", "--account", destination]
        ) is PWV2BalanceCommand)
        let send = try #require(try await OpenEver.asyncParseAsRoot(
            commandPath + ["send", "--keys", keysJSON, "--dest", destination, "--ever", "1,45"]
        ) as? PWV2SendCommand)
        #expect(try send.amount() == 1_450_000_000)
        #expect(send.flag == 3)
        #expect(send.bounce == nil)
        #expect(!send.destination.bounce)
    }

    @Test(arguments: ["--workchain", "--w", "-w"])
    func signedWorkchainAliasesAndAddressOutput(_ option: String) throws {
        try withWalletDirectory { directory in
            let path = directory.appendingPathComponent("address").path
            var command = try PWV2AddressCommand.parse([
                "--keys", "{\"publicKey\":\"\(publicKey)\"}", option, "-1", "--out", path
            ])
            #expect(command.chain.workchain == -1)
            try command.run()
            let wallet = try PWV2(publicKey: Input.hex(publicKey), workchain: -1)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == wallet.address.toString() + "\n")
        }
        for workchain in ["-129", "128"] {
            #expect(throws: (any Error).self) { try WalletWorkchainOptions.parse([option, workchain]) }
        }
    }

    @Test(arguments: [[], ["pwv2"], ["preprocessedWalletV2"]], [-1, 0])
    func seedAddressMatchesKeysAndSupportsOutput(_ walletType: [String], _ workchain: Int) async throws {
        var command = try #require(try await OpenEver.asyncParseAsRoot(
            ["wallet"] + walletType + ["address", "--seed", mnemonic, "--workchain", String(workchain), "--out", "address"]
        ) as? PWV2AddressCommand)
        #expect(command.out == "address")
        try withWalletDirectory { directory in
            let seedPath = directory.appendingPathComponent("from-seed").path
            let keysPath = directory.appendingPathComponent("from-keys").path
            command.out = seedPath
            try command.run()
            var fromKeys = try PWV2AddressCommand.parse([
                "--keys", keysJSON, "--workchain", String(workchain), "--out", keysPath
            ])
            try fromKeys.run()
            let seedAddress = try String(contentsOfFile: seedPath, encoding: .utf8)
            #expect(try seedAddress == String(contentsOfFile: keysPath, encoding: .utf8))
            #expect(seedAddress.hasPrefix("\(workchain):"))
            let mnemonicPath = directory.appendingPathComponent("seed").path
            let fileAddressPath = directory.appendingPathComponent("from-seed-file").path
            try WalletOutput.write(mnemonic, to: mnemonicPath, sensitive: true)
            var fromSeedFile = try PWV2AddressCommand.parse([
                "--seed-file", mnemonicPath, "--w", String(workchain), "--out", fileAddressPath
            ])
            try fromSeedFile.run()
            #expect(try seedAddress == String(contentsOfFile: fileAddressPath, encoding: .utf8))
        }
    }

    @Test func addressRequiresOneSourceAndRejectsInvalidSeed() throws {
        for arguments in [[], ["--seed", mnemonic, "--keys", keysJSON],
                          ["--seed", mnemonic, "--keys-file", "keys.json"]] {
            #expect(throws: (any Error).self) { try PWV2AddressCommand.parse(arguments) }
        }
        #expect(throws: (any Error).self) {
            var command = try PWV2AddressCommand.parse(["--seed", String(repeating: "abandon ", count: 12)])
            try command.run()
        }
        #expect(throws: (any Error).self) {
            try PWV2SendCommand.parse(["--dest", destination, "--ever", "1"])
        }
    }

    @Test func credentialSourcesAreMutuallyExclusiveForAddressAndSend() throws {
        let sources = [["--keys", keysJSON], ["--keys-file", "keys.json"],
                       ["--seed", mnemonic], ["--seed-file", "seed"]]
        for left in sources.indices {
            for right in sources.indices where right > left {
                let arguments = sources[left] + sources[right]
                #expect(throws: (any Error).self) { try PWV2AddressCommand.parse(arguments) }
                #expect(throws: (any Error).self) {
                    try PWV2SendCommand.parse(arguments + ["--dest", destination, "--ever", "1"])
                }
            }
        }
    }

    @Test(arguments: [[], ["pwv2"], ["preprocessedWalletV2"]])
    func configIsAcceptedAtEachWalletCommandLevel(_ walletType: [String]) async throws {
        let commandPath = ["wallet"] + walletType + ["send"]
        for level in 0...commandPath.count {
            var arguments = commandPath + ["--keys", keysJSON, "--destination", destination, "--nanoEver", "42"]
            arguments.insert(contentsOf: ["--config", "selected.json"], at: level)
            let command = try #require(try await OpenEver.asyncParseAsRoot(arguments) as? PWV2SendCommand)
            #expect(command.connection.config == "selected.json")
            #expect(try command.amount() == 42)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func friendlyAddressFlagsAndBase64Variants(_ bounce: Bool, _ testOnly: Bool) throws {
        let friendly = try friendlyWalletAddress(raw: destination, bounce: bounce, testOnly: testOnly)
        for address in [friendly, friendly.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")] {
            let parsed = try WalletAddress(address)
            #expect(parsed.address.toString() == destination)
            #expect(parsed.bounce == bounce)
            for name in ["--dest", "--destination"] {
                let command = try PWV2SendCommand.parse(["--keys", keysJSON, name, address, "--nano-ever", "1"])
                #expect(command.destination.address.toString() == destination)
                #expect(command.destination.bounce == bounce)
            }
        }
        var corrupted = try Input.base64(friendly)
        corrupted[35] ^= 1
        #expect(throws: (any Error).self) { try WalletAddress(corrupted.base64EncodedString()) }
    }

    @Test func bounceOverride() throws {
        let base = ["--keys", keysJSON, "--dest", destination, "--ever", "1"]
        #expect(try PWV2SendCommand.parse(base + ["--bounce"]).bounce == true)
        #expect(try PWV2SendCommand.parse(base + ["--no-bounce"]).bounce == false)
    }

    @Test(arguments: [
        [], ["--ever", "1", "--nanoEver", "1"], ["--ever", "-1"], ["--ever", "1.0000000001"],
        ["--nanoEver", "1.5"], ["--ever", "1", "--flag", "256"], ["--ever", "1", "--flag", "192"],
        ["--ever", "1", "--ttl", "0"], ["--ever", "1", "--ttl", "3601"]
    ])
    func invalidSendOptionsAreRejected(_ options: [String]) throws {
        #expect(throws: (any Error).self) {
            try PWV2SendCommand.parse(["--keys", keysJSON, "--dest", destination] + options)
        }
    }

    @Test func payloadInputsAreExclusiveAndStdinIsNotShared() throws {
        #expect(throws: (any Error).self) { try WalletPayloadOptions.parse(["--body", "AA==", "--body-file", "body"]) }
        #expect(throws: (any Error).self) {
            try WalletPayloadOptions.parse(["--stateInit", "AA==", "--stateInit-file", "init"])
        }
        for credential in ["--keys-file", "--seed-file"] {
            for payload in ["--body-file", "--stateInit-file"] {
                #expect(throws: (any Error).self) {
                    try PWV2SendCommand.parse([credential, "-", "--dest", destination, "--ever", "1", payload, "-"])
                }
            }
        }
    }

    @Test func payloadBOCsRoundTripAndRejectMalformedStateInit() throws {
        let body = try CellBuilder().storeUInt(123, 32).cell()
        let stateInit = try StateInit(options: StateInitOptions(code: body, data: CellBuilder().cell())).cell()
        let bodyText = try Boc.serialize(root: [body]).base64EncodedString()
        let initText = try Boc.serialize(root: [stateInit]).base64EncodedString()
        let direct = try WalletPayloadOptions.parse(["--body", bodyText, "--stateInit", initText]).read()
        #expect(direct.body == body)
        #expect(try direct.stateInit?.cell() == stateInit)
        try withWalletDirectory { directory in
            let bodyPath = directory.appendingPathComponent("body").path
            let initPath = directory.appendingPathComponent("stateInit").path
            try WalletOutput.write(bodyText, to: bodyPath)
            try WalletOutput.write(initText, to: initPath)
            let fromFiles = try WalletPayloadOptions.parse(["--body-file", bodyPath, "--stateInit-file", initPath]).read()
            #expect(fromFiles.body == body)
            #expect(try fromFiles.stateInit?.cell() == stateInit)
        }
        let trailing = try CellBuilder().storeSlice(stateInit.parse()).storeBit(.b1).cell()
        let trailingText = try Boc.serialize(root: [trailing]).base64EncodedString()
        #expect(throws: (any Error).self) { try WalletPayloadOptions.parse(["--state-init", trailingText]).read() }
        let multiRoot = try Boc.serialize(root: [body, stateInit]).base64EncodedString()
        for text in ["", "invalid base64", "AA==", multiRoot] {
            #expect(throws: (any Error).self) { try WalletPayloadOptions.parse(["--body", text]).read() }
        }
    }

    @Test(arguments: [false, true], ["--keys", "--keys-file", "--seed", "--seed-file"])
    func submissionFetchesStateAndUsesItsSequenceNumber(_ active: Bool, _ source: String) async throws {
        let (command, keyPair) = try withWalletDirectory { directory in
            let input: String
            if source.hasSuffix("-file") {
                input = directory.appendingPathComponent("credentials").path
                try WalletOutput.write(source == "--seed-file" ? mnemonic : keysJSON, to: input, sensitive: true)
            } else { input = source == "--seed" ? mnemonic : keysJSON }
            let command = try PWV2SendCommand.parse([
                source, input, "--destination", "42:" + String(repeating: "11", count: 32),
                "--ever", "1,45", "--workchain", "-1", "--bounce", "--flag", "1"
            ])
            return (command, try command.keys.read())
        }
        #expect(keyPair.privatKey == privateKey)
        #expect(keyPair.publicKey == publicKey)
        let wallet = try PWV2(publicKey: keyPair.publicKeyData(), workchain: command.chain.workchain)
        let accountHash = wallet.address.hash
        let state = try makePWV2AccountState(wallet: wallet, balance: 10_000_000_000,
                                             seqno: active ? 23 : nil, versioned: active).data
        let block = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 123,
                                                root_hash: TLBytes256(), file_hash: TLBytes256())
        let transport = TestLiteTransport { data in
            var reader = TLReader(data: data)
            if try reader.read(UInt32.self, boxed: false) == LiteServerGetAccountStateRequest.constructorID {
                let request = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: data)
                #expect(request.account.workchain == -1)
                #expect(try request.account.id == TLBytes256(accountHash))
                #expect(request.id.seqno == -1)
                return try TLCodec.encode(LiteServerAccountStateConstructor(id: block, shardblk: block,
                                                                           shard_proof: Data(), proof: Data(), state: state))
            }
            _ = try TLCodec.decode(LiteServerSendMessageRequest.self, from: data)
            return try TLCodec.encode(LiteServerSendMsgStatusConstructor(status: 1))
        }
        let client = try testClient(transport)
        let result = try await command.submit(using: client, wallet: wallet, secret: keyPair.secret(),
                                              amount: command.amount(), body: nil, stateInit: nil)
        #expect(result.isAccepted)
        #expect(result.seqno == (active ? 23 : 0))
        #expect(result.nanoEver == "1450000000")
        #expect(result.account == wallet.address.toString())
        let requests = await transport.requests
        #expect(requests.count == 2)
        let submitted = try TLCodec.decode(LiteServerSendMessageRequest.self, from: #require(requests.last))
        let cell = try #require(Boc.deserialize(data: submitted.body).first)
        #expect(try result.messageHash == cell.hash().lowercased())
        let message = try Message.parse(cs: cell.parse())
        #expect((message.data.stateInit != nil) == !active)
        let body = try #require(message.data.body).parse()
        let signature = try body.loadBytes(size: 64)
        let innerCell = try body.loadRef()
        let signedData = try Input.hex(innerCell.hash())
        #expect(try SEPCrypto.Ed25519.verify(signature: signature, message: signedData, len: signedData.count,
                                           publicKey: Input.hex(publicKey)))
        let inner = innerCell.parse()
        #expect(try inner.loadBigUInt(size: 64) == BigUInt(result.validUntil))
        #expect(try inner.loadBigUInt(size: 16) == BigUInt(active ? 23 : 0))
        let actions = try inner.loadRef().parse()
        _ = try actions.loadRef()
        guard case let .actionSendMsg(send) = try OutAction.parse(cs: actions) else {
            Issue.record("Expected a send action")
            await client.close()
            return
        }
        #expect(send.mode == 1)
        guard case let .internalMessage(info) = try RawCommonMsgInfo.parse(cs: send.outMsg.data.info.cell().parse(), relaxed: true) else {
            Issue.record("Expected an internal message")
            await client.close()
            return
        }
        #expect(try info.dest.asAddress() == command.destination.address)
        #expect(info.value.grams == 1_450_000_000)
        #expect(info.bounce)
        await client.close()
    }

    @Test func emptyWalletIsNotSubmitted() async throws {
        let command = try PWV2SendCommand.parse(["--keys", keysJSON, "--dest", destination, "--ever", "1"])
        let keyPair = try command.keys.read()
        let wallet = try PWV2(publicKey: keyPair.publicKeyData())
        let block = TonNodeBlockIdExtConstructor(workchain: -1, shard: Int64.min, seqno: 123,
                                                root_hash: TLBytes256(), file_hash: TLBytes256())
        let transport = TestLiteTransport { data in
            _ = try TLCodec.decode(LiteServerGetAccountStateRequest.self, from: data)
            return try TLCodec.encode(LiteServerAccountStateConstructor(id: block, shardblk: block,
                                                                       shard_proof: Data(), proof: Data(), state: Data()))
        }
        let client = try testClient(transport)
        await #expect(throws: RuntimeError.self) {
            try await command.submit(using: client, wallet: wallet, secret: keyPair.secret(),
                                     amount: command.amount(), body: nil, stateInit: nil)
        }
        #expect(await transport.requests.count == 1)
        await client.close()
    }
}

private func friendlyWalletAddress(raw: String, bounce: Bool, testOnly: Bool) throws -> String {
    let address = try Address(address: raw)
    var data = Data([UInt8(bounce ? 0x11 : 0x51) | (testOnly ? 0x80 : 0), UInt8(bitPattern: address.workchain)])
    data.append(address.hash)
    data.append(data.crc16BytesBE())
    return data.base64EncodedString()
}
