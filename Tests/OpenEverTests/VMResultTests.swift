import ArgumentParser
import BigInt
import EverscaleSdkSwift
import Foundation
import Testing
@testable import OpenEver

struct VMResultTests {
    @Test func oldFormatFixtureProducesTypedJSON() throws {
        let input = try BinaryInputOptions.parse(["--input-hex", "b5ee9c72010102010008000106070100010000"])
        let cell = try #require(try input.boc().singleCell())
        let output = try OutputOptions.parse([])
        let value = try VMResult.deserialize(cell, output: output)
        let json = try #require(try JSONSerialization.jsonObject(with: output.encode(value)) as? [String: Any])
        #expect(json["type"] as? String == "tuple")
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["type"] as? String == "none")
    }

    @Test func supportedTypesRoundTripWithTheirPayloads() throws {
        let payload = try Cell(bits: [.b1, .b0, .b1], refs: [Cell(), Cell(bits: [.b1])])
        let boc = try payload.toBoc().base64EncodedString()
        let cell = try VMParameters.serialize("n, i -1, b \(boc), c \(boc), s \(boc), t(i 23, b \(boc))")
        let result = try VMResult.deserialize(cell, output: OutputOptions.parse([]))
        let items = try #require(result.items)
        #expect(items.map(\.type) == ["none", "integer", "builder", "cell", "slice", "tuple"])
        #expect(items[1].value == "-1")
        for index in 2...4 {
            #expect(items[index].boc?.data == boc)
            #expect(items[index].boc?.encoding == "base64")
            #expect(items[index].bitCount == 3)
            #expect(items[index].referenceCount == 2)
        }
        #expect(items[4].bits?.start == 0)
        #expect(items[4].bits?.end == 3)
        #expect(items[4].references?.start == 0)
        #expect(items[4].references?.end == 2)
        let nested = try #require(items[5].items)
        #expect(nested.map(\.type) == ["integer", "builder"])
        #expect(nested[0].value == "23")
        #expect(nested[1].boc?.data == boc)
    }

    @Test func emptyTuplesDoNotConsumeTheirParentsListReferences() throws {
        let output = try OutputOptions.parse([])
        let empty = try VMResult.deserialize(VMParameters.serialize(""), output: output)
        #expect(empty.type == "tuple")
        #expect(empty.items?.isEmpty == true)
        let result = try VMResult.deserialize(VMParameters.serialize("t(n, t()), t(), i 23"), output: output)
        let items = try #require(result.items)
        #expect(items.count == 3)
        let nested = try #require(items[0].items)
        #expect(nested[0].type == "none")
        #expect(nested[1].items?.isEmpty == true)
        #expect(items[1].items?.isEmpty == true)
        #expect(items[2].value == "23")
    }

    @Test func integersKeep257BitPrecisionAndNaN() throws {
        let bound = BigInt(1) << 256
        let numbers = [-bound, BigInt(-1), BigInt(0), bound - 1]
        let output = try OutputOptions.parse([])
        for number in numbers {
            let cell = try CellBuilder().storeUInt(0x02, 8).storeUInt(0, 7).storeInt(number, 257).cell()
            let value = try VMResult.deserialize(cell, output: output)
            #expect(value.type == "integer")
            #expect(value.value == String(number))
            let json = try #require(try JSONSerialization.jsonObject(with: output.encode(value)) as? [String: Any])
            #expect(json["value"] as? String == String(number))
        }
        let nan = try VMResult.deserialize(Cell(bits: Input.hex("02ff").toBits()), output: output)
        #expect(nan.type == "integer")
        #expect(nan.value == "NaN")
    }

    @Test func slicesPreservePartialBitAndReferenceRanges() throws {
        let payload = try Cell(bits: Input.hex("ab").toBits(), refs: [Cell(), Cell(bits: [.b1])])
        let cell = try CellBuilder().storeUInt(0x04, 8).storeRef(payload)
            .storeUInt(2, 10).storeUInt(6, 10).storeUInt(1, 3).storeUInt(2, 3).cell()
        let result = try VMResult.deserialize(cell, output: OutputOptions.parse(["--binary-encoding", "hex"]))
        #expect(result.type == "slice")
        #expect(result.bits?.start == 2)
        #expect(result.bits?.end == 6)
        #expect(result.references?.start == 1)
        #expect(result.references?.end == 2)
        #expect(result.boc?.encoding == "hex")
        #expect(try Input.hex(#require(result.boc?.data)) == payload.toBoc())
    }

    @Test(arguments: ["01", "02", "0200", "02fe", "03", "04", "05", "06", "0701", "070100", "070200", "0000"])
    func malformedSerializedValuesAreRejected(_ hex: String) throws {
        let cell = try Cell(bits: Input.hex(hex).toBits())
        #expect(throws: ValidationError.self) { try VMResult.deserialize(cell, output: OutputOptions.parse([])) }
    }

    @Test(arguments: [[4, 3, 0, 0], [0, 4, 0, 0], [0, 3, 2, 1], [0, 3, 0, 3]])
    func invalidSliceRangesAreRejected(_ ranges: [Int]) throws {
        let payload = try Cell(bits: [.b1, .b0, .b1], refs: [Cell(), Cell(bits: [.b1])])
        let cell = try CellBuilder().storeUInt(0x04, 8).storeRef(payload)
            .storeUInt(BigUInt(ranges[0]), 10).storeUInt(BigUInt(ranges[1]), 10)
            .storeUInt(BigUInt(ranges[2]), 3).storeUInt(BigUInt(ranges[3]), 3).cell()
        #expect(throws: ValidationError.self) { try VMResult.deserialize(cell, output: OutputOptions.parse([])) }
    }

    @Test func trailingReferencesAndCorruptTupleListsAreRejected() throws {
        let empty = try Cell()
        let extraReference = try Cell(bits: Input.hex("00").toBits(), refs: [empty])
        let nonemptyTerminator = try Cell(bits: Input.hex("070100").toBits(), refs: [Cell(bits: [.b1])])
        let corruptTail = try Cell(bits: Input.hex("0000").toBits(), refs: [empty])
        let corruptTuple = try Cell(bits: Input.hex("070200").toBits(), refs: [corruptTail])
        for cell in [extraReference, nonemptyTerminator, corruptTuple] {
            #expect(throws: ValidationError.self) { try VMResult.deserialize(cell, output: OutputOptions.parse([])) }
        }
    }

    @Test(arguments: [false, true])
    func commandAcceptsBase64ArgumentAndExistingInputOptions(_ useOption: Bool) async throws {
        let boc = try VMParameters.serialize("i -1, t(i 23, n)").toBoc().base64EncodedString()
        let arguments = useOption ? ["--input-base64", boc, "--compact"] : [boc]
        let command = try #require(try await OpenEver.asyncParseAsRoot(
            ["liteclient", "parse-vm-result"] + arguments
        ) as? ParseVMResultCommand)
        let result = try command.decodedResult()
        #expect(result.items?.first?.value == "-1")
        #expect(result.items?.last?.items?.first?.value == "23")
        #expect(command.output.compact == useOption)
        #expect(OpenEver.helpMessage(for: LiteClientCommand.self).contains("parse-vm-result"))
    }

    @Test(arguments: [[], ["AA==", "--input-hex", "00"], ["--input-base64", "AA==", "--input-hex", "00"]])
    func missingOrConflictingInputsAreRejected(_ arguments: [String]) async {
        await #expect(throws: (any Error).self) {
            try await OpenEver.asyncParseAsRoot(["liteclient", "parse-vm-result"] + arguments)
        }
    }

    @Test func invalidBOCsAndMultipleRootsAreRejected() async throws {
        let multipleRoots = try Boc.serialize(root: [Cell(), Cell(bits: [.b1])]).base64EncodedString()
        for boc in ["%%", "AA==", multipleRoots] {
            let command = try #require(try await OpenEver.asyncParseAsRoot(
                ["liteclient", "parse-vm-result", boc]
            ) as? ParseVMResultCommand)
            #expect(throws: (any Error).self) { try command.decodedResult() }
        }
    }
}
