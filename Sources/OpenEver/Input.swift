import ArgumentParser
import Foundation
import EverLiteClient
import EverscaleSdkSwift
import SwiftExtensionsPack

enum Input {
    static func hex(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        guard text.utf8.count.isMultiple(of: 2),
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let bytes = Data(hexString: text) else {
            throw ValidationError("Expected an even number of hexadecimal digits (optional 0x prefix).")
        }
        return bytes
    }

    static func base64(_ value: String) throws -> Data {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.utf8.count % 4
        guard remainder != 1 else { throw ValidationError("Invalid base64 data.") }
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        guard let bytes = Data(base64Encoded: text) else { throw ValidationError("Invalid base64 data.") }
        return bytes
    }

    static func hash(_ value: String) throws -> Hash256 {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("0x") || (text.count == 64 && text.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })) {
            return try Hash256(hex(text))
        }
        return try Hash256(base64(text))
    }

    static func unsigned64(_ value: String) throws -> UInt64 {
        let isHex = value.lowercased().hasPrefix("0x")
        let text = isHex ? String(value.dropFirst(2)) : value
        guard let number = UInt64(text, radix: isHex ? 16 : 10) else {
            throw ValidationError("Expected an unsigned 64-bit integer in decimal or 0x hexadecimal format.")
        }
        return number
    }

    static func methodID(_ value: String) throws -> Int64 {
        if value.lowercased().hasPrefix("0x") { return Int64(bitPattern: try unsigned64(value)) }
        guard let number = Int64(value) else { throw ValidationError("Expected a signed 64-bit method ID or 0x hexadecimal value.") }
        return number
    }

    static func file(_ path: String) throws -> Data {
        do {
            if path == "-" { return try FileHandle.standardInput.readToEnd() ?? Data() }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ValidationError("Cannot read input '\(path)': \(error.localizedDescription)")
        }
    }
}

struct BinaryInputOptions: ParsableArguments {
    @Option(help: "Read binary input from a file; '-' reads stdin.")
    var inputFile: String?

    @Option(help: "Input bytes as base64 or base64url.")
    var inputBase64: String?

    @Option(help: "Input bytes as hexadecimal (optional 0x prefix).")
    var inputHex: String?

    var sourceCount: Int { [inputFile, inputBase64, inputHex].compactMap { $0 }.count }

    mutating func validate() throws {
        guard sourceCount <= 1 else {
            throw ValidationError("Use exactly one of --input-file, --input-base64 or --input-hex.")
        }
        if let inputBase64 { _ = try Input.base64(inputBase64) }
        if let inputHex { _ = try Input.hex(inputHex) }
    }

    func requireSource() throws {
        guard sourceCount == 1 else {
            throw ValidationError("Provide --input-file, --input-base64 or --input-hex.")
        }
    }

    func read() throws -> Data {
        try requireSource()
        if let inputFile { return try Input.file(inputFile) }
        if let inputBase64 { return try Input.base64(inputBase64) }
        if let inputHex { return try Input.hex(inputHex) }
        throw ValidationError("Missing binary input.")
    }

    func boc() throws -> BagOfCells {
        let boc = try BagOfCells(read())
        do {
            guard !boc.isEmpty, !(try boc.cells()).isEmpty else { throw ValidationError("The BOC must contain a root cell.") }
        } catch {
            throw ValidationError("Invalid BOC: \(error)")
        }
        return boc
    }
}

struct AccountOptions: ParsableArguments {
    @Option(parsing: .unconditional, help: "Account in workchain:64-hex-digits format; masterchain addresses start with -1:.",
            transform: { try AccountID($0) })
    var account: AccountID
}

struct MethodOptions: ParsableArguments {
    @Option(parsing: .unconditional, help: "Signed 64-bit method ID in decimal or hexadecimal.", transform: Input.methodID)
    var methodID: Int64?

    @Option(help: "Getter name; its ID is CRC16(name) | 0x10000.")
    var methodName: String?

    @Flag(help: "Request account and shard proofs.") var accountProofs = false
    @Flag(help: "Request the state proof.") var stateProof = false
    @Flag(help: "Request the initial c7 context.") var initialContext = false
    @Flag(help: "Request library extras.") var libraryExtras = false
    @Flag(help: "Omit the result stack from the requested fields.") var noResult = false

    mutating func validate() throws {
        guard (methodID != nil) != (methodName != nil) else {
            throw ValidationError("Provide exactly one of --method-id or --method-name.")
        }
        if let methodName, methodName.isEmpty { throw ValidationError("The method name cannot be empty.") }
    }

    var resolvedID: Int64 {
        if let methodID { return methodID }
        return Int64(Data((methodName ?? "").utf8).crc16()) | 0x10000
    }

    var options: RunMethodOptions {
        var result: RunMethodOptions = noResult ? [] : .result
        if accountProofs { result.insert(.accountProofs) }
        if stateProof { result.insert(.stateProof) }
        if initialContext { result.insert(.initialContext) }
        if libraryExtras { result.insert(.libraryExtras) }
        return result
    }
}
