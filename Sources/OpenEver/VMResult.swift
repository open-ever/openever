import ArgumentParser
import EverscaleSdkSwift
import Foundation

struct ParseVMResultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parse-vm-result",
        abstract: "Decode an old-format TVM result BOC and print its typed values as JSON.",
        discussion: """
        Provide BOC base64 as an argument, or use one --input-* option. Tuples are
        decoded recursively; integers are decimal strings to preserve all 257 bits.
        Cell and builder values include their BOC. Slices include the backing cell's
        BOC and exclusive bit/reference ranges. Continuations are unsupported.
        This command runs locally and does not require a lite-server connection.

        Example:
          openever liteclient parse-vm-result BOC_BASE64
          openever liteclient parse-vm-result --input-file result.boc
        """
    )

    @Argument(help: "Serialized TVM result as BOC base64 or base64url.")
    var bocBase64: String?
    @OptionGroup var input: BinaryInputOptions
    @OptionGroup var output: OutputOptions

    mutating func validate() throws { _ = try resolvedInput() }

    func decodedResult() throws -> VMValueOutput {
        guard let root = try resolvedInput().boc().singleCell() else {
            throw ValidationError("The BOC must contain a root cell.")
        }
        return try VMResult.deserialize(root, output: output)
    }

    mutating func run() async throws { try output.write(decodedResult()) }

    private func resolvedInput() throws -> BinaryInputOptions {
        guard input.sourceCount + (bocBase64 == nil ? 0 : 1) == 1 else {
            throw ValidationError("Provide BOC base64 or exactly one of --input-file, --input-base64 or --input-hex.")
        }
        var source = input
        if let bocBase64 { source.inputBase64 = bocBase64 }
        return source
    }
}

struct VMValueOutput: Encodable {
    let type: String
    var value: String? = nil
    var items: [VMValueOutput]? = nil
    var boc: BinaryOutput? = nil
    var bitCount: Int? = nil
    var referenceCount: Int? = nil
    var bits: VMRangeOutput? = nil
    var references: VMRangeOutput? = nil
}

struct VMRangeOutput: Encodable {
    let start: Int
    let end: Int
}

enum VMResult {
    static func deserialize(_ cell: Cell, output: OutputOptions) throws -> VMValueOutput {
        do {
            let slice = cell.parse()
            let decoder = Decoder(output: output)
            let value = try decoder.item(from: slice)
            try decoder.requireEnd(slice)
            return value
        } catch {
            throw ValidationError("Invalid serialized VM result: \(error)")
        }
    }

    private struct Decoder {
        let output: OutputOptions

        func item(from slice: CellSlice, depth: Int = 0) throws -> VMValueOutput {
            guard depth <= 128 else { throw ValidationError("Tuple nesting is too deep.") }
            let tag = try slice.loadBigUInt(size: 8)
            switch tag {
            case 0x00:
                return VMValueOutput(type: "none")
            case 0x02:
                let encoding = try slice.loadBigUInt(size: 7)
                if encoding == 0 {
                    return VMValueOutput(type: "integer", value: String(try slice.loadBigInt(size: 257)))
                }
                guard encoding == 0x7f, try slice.loadBit() == .b1 else {
                    throw ValidationError("Invalid integer encoding.")
                }
                return VMValueOutput(type: "integer", value: "NaN")
            case 0x03, 0x05:
                return try binary(type: tag == 0x03 ? "cell" : "builder", cell: slice.loadRef())
            case 0x04:
                let cell = try slice.loadRef()
                let startBit = Int(try slice.loadBigUInt(size: 10))
                let endBit = Int(try slice.loadBigUInt(size: 10))
                let startRef = Int(try slice.loadBigUInt(size: 3))
                let endRef = Int(try slice.loadBigUInt(size: 3))
                guard startBit <= endBit, endBit <= cell.bitLength,
                      startRef <= endRef, endRef <= cell.referencesCount else {
                    throw ValidationError("Invalid slice bit or reference range.")
                }
                var value = try binary(type: "slice", cell: cell)
                value.bits = VMRangeOutput(start: startBit, end: endBit)
                value.references = VMRangeOutput(start: startRef, end: endRef)
                return value
            case 0x06:
                throw ValidationError("Continuations are not supported.")
            case 0x07:
                let length = Int(try slice.loadBigUInt(size: 8))
                // serialize_old emits no list reference for an empty tuple.
                if length == 0 { return VMValueOutput(type: "tuple", items: []) }
                var items = [try item(from: slice, depth: depth + 1)]
                var next = try slice.loadRef()
                for _ in 1..<length {
                    let child = next.parse()
                    items.append(try item(from: child, depth: depth + 1))
                    next = try child.loadRef()
                    try requireEnd(child)
                }
                try requireEnd(next.parse())
                return VMValueOutput(type: "tuple", items: items)
            default:
                throw ValidationError("Unknown TVM item type 0x\(String(tag, radix: 16)).")
            }
        }

        func binary(type: String, cell: Cell) throws -> VMValueOutput {
            VMValueOutput(type: type, boc: output.binary(try cell.toBoc()),
                          bitCount: cell.bitLength, referenceCount: cell.referencesCount)
        }

        func requireEnd(_ slice: CellSlice) throws {
            guard slice.bitsRemainingCount == 0, slice.referencesRemainingCount == 0 else {
                throw ValidationError("Unexpected trailing bits or references in a VM value or tuple list.")
            }
        }
    }
}
