import ArgumentParser
import Foundation
import Testing
import EverscaleSdkSwift
@testable import OpenEver

struct WalletCryptoTests {
    private let mnemonic = "squirrel guess pigeon limit fine gorilla general glide pyramid warfare memory decorate"
    private let publicKey = "484447bbdb4bbd79bb9fad089588e7b1d89cdd87f87be5c6d75a5048369e11d0"
    private let privateKey = "de597db582a8f93335be796278f5c87df7e6b16d1c7f4402a0f5c712d5730f81"

    @Test func keysMatchEverscaleWalletReference() throws {
        let keys = try WalletKeys.fromMnemonic(mnemonic)
        #expect(keys.privatKey == privateKey)
        #expect(keys.publicKey == publicKey)
        try keys.validate()
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(keys)) as? [String: String])
        #expect(json == ["privatKey": privateKey, "publicKey": publicKey])
    }

    @Test(arguments: [12, 24])
    func generatedSeedsHaveRequestedLengthAndValidChecksum(_ count: Int) throws {
        try withWalletDirectory { directory in
            let path = directory.appendingPathComponent("seed").path
            var command = try WalletSeedCommand.parse(["--count", String(count), "--out", path])
            try command.run()
            let seed = try String(contentsOfFile: path, encoding: .utf8)
            #expect(seed.split(whereSeparator: \.isWhitespace).count == count)
            #expect(BIP39Mnemonic.isValid(seed))
            #expect(seed.hasSuffix("\n"))
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
            #expect(throws: (any Error).self) { try command.run() }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == seed)
        }
    }

    @Test func seedDefaultAndInvalidCounts() throws {
        #expect(try WalletSeedCommand.parse([]).count == 12)
        for count in [0, 11, 15, 18, 21, 25] {
            #expect(throws: (any Error).self) { try WalletSeedCommand.parse(["--count", String(count)]) }
        }
    }

    @Test func keyInputsRequireExactlyOneSourceAndValidMatchingKeys() throws {
        let empty = try WalletKeyInputOptions.parse([])
        #expect(throws: (any Error).self) { try empty.requireSource() }
        #expect(throws: (any Error).self) { try empty.read() }
        #expect(throws: (any Error).self) {
            try WalletKeyInputOptions.parse(["--keys", "{}", "--keys-file", "keys.json"])
        }
        let json = "{\"privatKey\":\"\(privateKey)\",\"publicKey\":\"\(publicKey)\"}"
        #expect(try WalletKeyInputOptions.parse(["--keys", json]).read().secret() == Input.hex(privateKey))
        let publicOnly = try WalletKeyInputOptions.parse(["--keys", "{\"publicKey\":\"\(publicKey)\"}"])
        #expect(try publicOnly.read(requireSecret: false).publicKey == publicKey)
        #expect(throws: (any Error).self) { try publicOnly.read() }
        for json in ["{}", "not JSON", "{\"privatKey\":\"00\",\"publicKey\":\"\(publicKey)\"}",
                     "{\"privatKey\":\"\(privateKey)\",\"publicKey\":\"\(String(repeating: "00", count: 32))\"}"] {
            #expect(throws: (any Error).self) { try WalletKeyInputOptions.parse(["--keys", json]).read() }
        }
    }

    @Test func keyCommandReadsSeedFileAndRoundTripsKeyFile() throws {
        try withWalletDirectory { directory in
            let seedPath = directory.appendingPathComponent("seed").path
            let keysPath = directory.appendingPathComponent("keys.json").path
            try WalletOutput.write(mnemonic, to: seedPath, sensitive: true)
            var command = try WalletKeysCommand.parse(["--seed-file", seedPath, "--out", keysPath])
            try command.run()
            let keys = try WalletKeyInputOptions.parse(["--keys-file", keysPath]).read()
            #expect(keys.privatKey == privateKey)
            #expect(keys.publicKey == publicKey)
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: keysPath)[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }
        #expect(throws: (any Error).self) {
            try WalletKeysCommand.parse(["--seed", mnemonic, "--seed-file", "seed"])
        }
        #expect(throws: (any Error).self) { try WalletKeys.fromMnemonic(String(repeating: "abandon ", count: 12)) }
    }

    @Test func seedCredentialsMatchKnownKeysAndRejectInvalidFiles() throws {
        let inline = try WalletKeyInputOptions.parse(["--seed", mnemonic]).read()
        #expect(inline.privatKey == privateKey)
        #expect(inline.publicKey == publicKey)
        try withWalletDirectory { directory in
            let seedPath = directory.appendingPathComponent("seed").path
            try WalletOutput.write(" \n" + mnemonic + "\n", to: seedPath, sensitive: true)
            #expect(try WalletKeyInputOptions.parse(["--seed-file", seedPath]).read() == inline)
            let invalidSeeds = [Data([0xff, 0xfe]), Data(String(repeating: "abandon ", count: 12).utf8), Data()]
            for (index, data) in invalidSeeds.enumerated() {
                let path = directory.appendingPathComponent("invalid-\(index)").path
                try WalletOutput.write(data, to: path, sensitive: true)
                #expect(throws: (any Error).self) { try WalletKeyInputOptions.parse(["--seed-file", path]).read() }
                #expect(throws: (any Error).self) {
                    var command = try WalletKeysCommand.parse(["--seed-file", path])
                    try command.run()
                }
            }
        }
    }
}

func withWalletDirectory<Result>(_ operation: (URL) throws -> Result) throws -> Result {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent(".build/tmp/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try operation(directory)
}
