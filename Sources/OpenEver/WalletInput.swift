import ArgumentParser
import Foundation
import EverscaleSdkSwift
import SwiftExtensionsPack

struct WalletAddress {
    let address: Address
    let bounce: Bool

    init(_ value: String) throws {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(":") {
            address = try Address(address: text)
            bounce = false
            return
        }
        // User-friendly addresses follow TEP-2, including the CRC16 checksum.
        let data = try Input.base64(text)
        guard text.count == 48, data.count == 36,
              data[0] & 0x7f == 0x11 || data[0] & 0x7f == 0x51,
              Data(data.prefix(34)).crc16BytesBE() == Data(data.suffix(2)) else {
            throw ValidationError("Expected a workchain:hex address or a base64/base64url address with a valid checksum.")
        }
        address = try Address(address: "\(Int8(bitPattern: data[1])):\(Data(data[2..<34]).toHexadecimal)")
        bounce = data[0] & 0x7f == 0x11
    }
}

struct WalletWorkchainOptions: ParsableArguments {
    @Option(name: [.customLong("workchain"), .customLong("w"), .customShort("w")],
            parsing: .unconditional, help: "Wallet workchain (-128...127); defaults to 0.")
    var workchain: Int = 0

    mutating func validate() throws {
        guard Int8(exactly: workchain) != nil else { throw ValidationError("--workchain must be between -128 and 127.") }
    }
}

struct WalletPayloadOptions: ParsableArguments {
    @Option(help: "Destination message body as a base64 BOC.") var body: String?
    @Option(help: "Read the destination body BOC as base64 text from a file; '-' reads stdin.") var bodyFile: String?
    @Option(name: [.customLong("stateInit"), .customLong("state-init")],
            help: "Destination StateInit as a base64 BOC.") var stateInit: String?
    @Option(name: [.customLong("stateInit-file"), .customLong("state-init-file")],
            help: "Read the destination StateInit BOC as base64 text from a file; '-' reads stdin.") var stateInitFile: String?

    mutating func validate() throws {
        guard body == nil || bodyFile == nil else { throw ValidationError("Use only one of --body or --body-file.") }
        guard stateInit == nil || stateInitFile == nil else {
            throw ValidationError("Use only one of --stateInit or --stateInit-file.")
        }
    }

    func read() throws -> (body: Cell?, stateInit: StateInit?) {
        let bodyCell = try cell(value: body, file: bodyFile)
        let initCell = try cell(value: stateInit, file: stateInitFile)
        let parsedInit: StateInit?
        if let initCell {
            let slice = initCell.parse()
            parsedInit = try StateInit.parse(cs: slice)
            guard slice.bits.isEmpty, slice.refs.isEmpty else {
                throw ValidationError("StateInit contains trailing data.")
            }
        } else { parsedInit = nil }
        return (bodyCell, parsedInit)
    }

    private func cell(value: String?, file: String?) throws -> Cell? {
        let text: String
        if let value { text = value }
        else if let file {
            guard let contents = String(data: try Input.file(file), encoding: .utf8) else {
                throw ValidationError("The BOC file must contain UTF-8 base64 text.")
            }
            text = contents
        } else { return nil }
        let roots = try Boc.deserialize(data: Input.base64(text))
        guard roots.count == 1, let root = roots.first, root.type == .ordinary else {
            throw ValidationError("A message body or StateInit BOC must contain one ordinary root cell.")
        }
        return root
    }
}
