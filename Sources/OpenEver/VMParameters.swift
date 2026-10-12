import ArgumentParser
import BigInt
import EverscaleSdkSwift
import Foundation

struct MakeVMParamsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "make-vm-params",
        abstract: "Serialize comma-separated TVM parameters and print their BOC as base64.",
        discussion: """
        Types: n/none, i/integer DECIMAL, b/builder BOC_BASE64, c/cell BOC_BASE64,
        s/slice BOC_BASE64, t/tuple (...). Tuples may be nested. Continuations are unsupported.
        This command runs locally and does not require a lite-server connection.

        Example:
          openever liteclient make-vm-params 'n, i -1, t (i 23, n)'
        """
    )

    @Argument(parsing: .allUnrecognized, help: "Comma-separated parameters; quote parentheses for your shell.")
    var parameters: [String] = []

    mutating func run() async throws {
        print(try VMParameters.serialize(parameters.joined(separator: " ")).toBoc().base64EncodedString())
    }
}

enum VMParameters {
    static func serialize(_ expression: String) throws -> Cell {
        var parser = Parser(text: Array(expression))
        return try tuple(parser.parseList()).cell()
    }

    private static func tuple(_ items: [CellBuilder]) throws -> CellBuilder {
        guard items.count <= 255 else { throw ValidationError("A tuple can contain at most 255 items.") }
        var list = CellBuilder()
        for item in items.reversed() {
            list = try CellBuilder().storeSlice(item.cell().parse()).storeRef(list.cell())
        }
        return try CellBuilder().storeUInt(0x07, 8).storeUInt(BigUInt(items.count), 8)
            .storeSlice(list.cell().parse())
    }

    private struct Parser {
        let text: [Character]
        var position = 0

        mutating func parseList(inTuple: Bool = false, depth: Int = 0) throws -> [CellBuilder] {
            guard depth <= 128 else { throw error("Tuple nesting is too deep.") }
            var items: [CellBuilder] = []
            skipWhitespace()
            if inTuple, consume(")") { return items }
            if position == text.count {
                guard !inTuple else { throw error("Expected ')' to close the tuple.") }
                return items
            }
            while true {
                items.append(try parseItem(depth: depth))
                skipWhitespace()
                if inTuple, consume(")") { return items }
                if position == text.count {
                    guard !inTuple else { throw error("Expected ')' to close the tuple.") }
                    return items
                }
                guard consume(",") else { throw error("Expected ',' between parameters.") }
                skipWhitespace()
                guard position < text.count, text[position] != ")" else {
                    throw error("Expected a parameter after ','.")
                }
            }
        }

        mutating func parseItem(depth: Int) throws -> CellBuilder {
            let type = token()
            switch type {
            case "n", "none":
                return try CellBuilder().storeUInt(0x00, 8)
            case "i", "integer":
                let value = token()
                let digits = value.first == "-" || value.first == "+" ? value.dropFirst() : value[...]
                guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                      let integer = BigInt(value) else {
                    throw error("Expected a signed decimal integer after '\(type)'.")
                }
                let bound = BigInt(1) << 256
                guard integer >= -bound, integer < bound else {
                    throw error("The integer must fit in signed 257 bits (-2^256...2^256-1).")
                }
                return try CellBuilder().storeUInt(0x02, 8).storeUInt(0, 7).storeInt(integer, 257)
            case "b", "builder", "c", "cell", "s", "slice":
                let value = token()
                let cells: [Cell]
                do { cells = try Boc.deserialize(data: Input.base64(value)) }
                catch let cause { throw error("Invalid BOC after '\(type)': \(cause)") }
                guard cells.count == 1, let cell = cells.first else {
                    throw error("The BOC after '\(type)' must contain exactly one root cell.")
                }
                let builder = CellBuilder()
                if type == "b" || type == "builder" {
                    return try builder.storeUInt(0x05, 8).storeRef(cell)
                }
                if type == "c" || type == "cell" {
                    return try builder.storeUInt(0x03, 8).storeRef(cell)
                }
                return try builder.storeUInt(0x04, 8).storeRef(cell)
                    .storeUInt(0, 10).storeUInt(BigUInt(cell.bitLength), 10)
                    .storeUInt(0, 3).storeUInt(BigUInt(cell.referencesCount), 3)
            case "t", "tuple":
                skipWhitespace()
                guard consume("(") else { throw error("Expected '(' after '\(type)'.") }
                return try VMParameters.tuple(parseList(inTuple: true, depth: depth + 1))
            case "continuation":
                throw error("Continuations are not supported.")
            default:
                throw error("Unknown parameter type '\(type)'; expected n, i, b, c, s or t (or their full names).")
            }
        }

        mutating func token() -> String {
            skipWhitespace()
            let start = position
            while position < text.count, !text[position].isWhitespace,
                  text[position] != ",", text[position] != "(", text[position] != ")" {
                position += 1
            }
            return String(text[start..<position])
        }

        mutating func skipWhitespace() {
            while position < text.count, text[position].isWhitespace { position += 1 }
        }

        mutating func consume(_ character: Character) -> Bool {
            guard position < text.count, text[position] == character else { return false }
            position += 1
            return true
        }

        func error(_ message: String) -> ValidationError {
            ValidationError("\(message) (character \(position + 1))")
        }
    }
}
