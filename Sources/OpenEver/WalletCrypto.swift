import ArgumentParser
import Foundation
import EverscaleSdkSwift
import SwiftExtensionsPack
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C runtime")
#endif

struct WalletKeys: Codable, Equatable {
    let privatKey: String?
    let publicKey: String

    static func fromMnemonic(_ mnemonic: String) throws -> WalletKeys {
        guard BIP39Mnemonic.isValid(mnemonic) else {
            throw ValidationError("The seed must be a valid BIP39 mnemonic with a valid checksum.")
        }
        let keys = try BIP39Mnemonic.mnemonicToKeyPairs(mnemonic: mnemonic)
        return WalletKeys(privatKey: keys.secret.toHexadecimal, publicKey: keys.public.toHexadecimal)
    }

    func secret() throws -> Data {
        guard let privatKey else { throw ValidationError("The keys JSON must include privatKey to sign a transaction.") }
        let data = try Input.hex(privatKey)
        guard data.count == 32 else { throw ValidationError("privatKey must contain exactly 32 bytes as hexadecimal.") }
        return data
    }

    func publicKeyData() throws -> Data {
        let data = try Input.hex(publicKey)
        guard data.count == 32 else { throw ValidationError("publicKey must contain exactly 32 bytes as hexadecimal.") }
        return data
    }

    func validate(requireSecret: Bool = true) throws {
        let publicBytes = try publicKeyData()
        if requireSecret || privatKey != nil {
            let derived = SEPCrypto.Ed25519.createKeyPair(seed32Byte: try secret())
            guard derived.public == publicBytes else {
                throw ValidationError("publicKey does not match privatKey.")
            }
        }
    }
}

struct WalletSeedInputOptions: ParsableArguments {
    @Option(help: "BIP39 mnemonic; uses the Everscale derivation path m/44'/396'/0'/0/0.")
    var seed: String?

    @Option(help: "Read a BIP39 mnemonic from a UTF-8 file; '-' reads stdin.")
    var seedFile: String?

    var sourceCount: Int { [seed, seedFile].compactMap { $0 }.count }

    mutating func validate() throws {
        guard sourceCount <= 1 else { throw ValidationError("Use only one of --seed or --seed-file.") }
    }

    func read() throws -> String? {
        guard sourceCount <= 1 else { throw ValidationError("Use only one of --seed or --seed-file.") }
        if let seed { return seed }
        if let seedFile {
            guard let text = String(data: try Input.file(seedFile), encoding: .utf8) else {
                throw ValidationError("The seed file must contain a UTF-8 BIP39 mnemonic.")
            }
            return text
        }
        return nil
    }
}

struct WalletKeyInputOptions: ParsableArguments {
    @Option(help: "Keys JSON with hexadecimal privatKey and publicKey fields.")
    var keys: String?

    @Option(help: "Read keys JSON from a file; '-' reads stdin.")
    var keysFile: String?

    @OptionGroup var seedInput: WalletSeedInputOptions

    var sourceCount: Int { [keys, keysFile].compactMap { $0 }.count + seedInput.sourceCount }

    mutating func validate() throws {
        guard sourceCount <= 1 else {
            throw ValidationError("Use only one of --keys, --keys-file, --seed or --seed-file.")
        }
    }

    func requireSource() throws {
        guard sourceCount == 1 else {
            throw ValidationError("Provide exactly one of --keys, --keys-file, --seed or --seed-file.")
        }
    }

    func read(requireSecret: Bool = true) throws -> WalletKeys {
        try requireSource()
        if let mnemonic = try seedInput.read() { return try WalletKeys.fromMnemonic(mnemonic) }
        let data: Data
        if let keys { data = Data(keys.utf8) }
        else if let keysFile { data = try Input.file(keysFile) }
        else { throw ValidationError("Missing keys JSON.") }
        let decoded: WalletKeys
        do { decoded = try JSONDecoder().decode(WalletKeys.self, from: data) }
        catch { throw ValidationError("Invalid keys JSON; expected hexadecimal privatKey and publicKey fields.") }
        try decoded.validate(requireSecret: requireSecret)
        return decoded
    }
}

enum WalletOutput {
    static func write(_ text: String, to path: String?, sensitive: Bool = false) throws {
        try write(Data((text + "\n").utf8), to: path, sensitive: sensitive)
    }

    static func write(_ data: Data, to path: String?, sensitive: Bool = false) throws {
        guard let path, path != "-" else {
            try FileHandle.standardOutput.write(contentsOf: data)
            return
        }
        let permissions: mode_t = sensitive ? 0o600 : 0o644
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ValidationError("Output '\(path)' already exists; choose a new path.") }
            throw ValidationError("Cannot create output '\(path)': \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw ValidationError("Cannot write output '\(path)': \(error.localizedDescription)")
        }
    }
}
