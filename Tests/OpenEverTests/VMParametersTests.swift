import ArgumentParser
import BigInt
import EverscaleSdkSwift
import Foundation
import Testing
@testable import OpenEver

struct VMParametersTests {
    @Test func noneMatchesOldTupleWireFormat() throws {
        let root = try VMParameters.serialize("n")
        let boc = try root.toBoc(bocOptions: .init(hasIndex: false, hashCrc32: false))
        #expect(boc == (try Input.hex("b5ee9c72010102010008000106070100010000")))
        #expect(try VMParameters.serialize("").bits == Input.hex("0700").toBits())
    }

    @Test func shortAndFullNamesProduceTheSameBOC() throws {
        let cell = try Cell(bits: [.b1, .b0, .b1], refs: [Cell()])
        let boc = try cell.toBoc().base64EncodedString()
        let short = "n, i -1, b \(boc), c \(boc), s \(boc), t (i 23, b \(boc))"
        let full = "none, integer -1, builder \(boc), cell \(boc), slice \(boc), tuple (i 23, b \(boc))"
        #expect(try VMParameters.serialize(short).toBoc() == VMParameters.serialize(full).toBoc())
    }

    @Test func binaryTypesUsePayloadReferenceBeforeTheListTail() throws {
        let cell = try Cell(bits: [.b1, .b0, .b1], refs: [Cell(), Cell(bits: [.b1])])
        let boc = try cell.toBoc().base64EncodedString()
        var slice = try VMParameters.serialize("b \(boc), c \(boc), s \(boc)").parse()
        #expect(try slice.loadBigUInt(size: 8) == 0x07)
        #expect(try slice.loadBigUInt(size: 8) == 3)
        for tag in [BigUInt(0x05), 0x03, 0x04] {
            #expect(try slice.loadBigUInt(size: 8) == tag)
            #expect(try slice.loadRef() == cell)
            if tag == 0x04 {
                #expect(try slice.loadBigUInt(size: 10) == 0)
                #expect(try slice.loadBigUInt(size: 10) == 3)
                #expect(try slice.loadBigUInt(size: 3) == 0)
                #expect(try slice.loadBigUInt(size: 3) == 2)
            }
            let next = try slice.loadRef()
            #expect(slice.bits.isEmpty)
            #expect(slice.refs.isEmpty)
            slice = next.parse()
        }
        #expect(slice.bits.isEmpty)
        #expect(slice.refs.isEmpty)
    }

    @Test func integerOrderAnd257BitEncoding() throws {
        let bound = BigInt(1) << 256
        let values = [BigInt(-1), BigInt(23), BigInt(0), -bound, bound - 1]
        var slice = try VMParameters.serialize(values.map { "i \($0)" }.joined(separator: ", ")).parse()
        #expect(try slice.loadBigUInt(size: 8) == 0x07)
        #expect(try slice.loadBigUInt(size: 8) == BigUInt(values.count))
        for value in values {
            #expect(try slice.loadBigUInt(size: 8) == 0x02)
            #expect(try slice.loadBigUInt(size: 7) == 0)
            #expect(try slice.loadBigInt(size: 257) == value)
            let next = try slice.loadRef()
            #expect(slice.bits.isEmpty)
            #expect(slice.refs.isEmpty)
            slice = next.parse()
        }
        #expect(slice.bits.isEmpty)
        #expect(slice.refs.isEmpty)
        for value in [bound, -bound - 1] {
            #expect(throws: ValidationError.self) { try VMParameters.serialize("i \(value)") }
        }
    }

    @Test func nestedAndEmptyTuplesKeepIndependentListTails() throws {
        let root = try VMParameters.serialize("t(n, t()), integer +23").parse()
        #expect(try root.loadBigUInt(size: 8) == 0x07)
        #expect(try root.loadBigUInt(size: 8) == 2)
        #expect(try root.loadBigUInt(size: 8) == 0x07)
        #expect(try root.loadBigUInt(size: 8) == 2)
        #expect(try root.loadBigUInt(size: 8) == 0x00)
        let nestedTail = try root.loadRef().parse()
        #expect(try nestedTail.loadBigUInt(size: 8) == 0x07)
        #expect(try nestedTail.loadBigUInt(size: 8) == 0)
        let end = try nestedTail.loadRef()
        #expect(end.bits.isEmpty)
        #expect(end.refs.isEmpty)
        #expect(nestedTail.bits.isEmpty)
        #expect(nestedTail.refs.isEmpty)
        let outerTail = try root.loadRef().parse()
        #expect(try outerTail.loadBigUInt(size: 8) == 0x02)
        #expect(try outerTail.loadBigUInt(size: 7) == 0)
        #expect(try outerTail.loadBigInt(size: 257) == 23)
        #expect(root.bits.isEmpty)
        #expect(root.refs.isEmpty)
    }

    @Test func tupleLengthMustFitEightBits() throws {
        let maximum = Array(repeating: "n", count: 255).joined(separator: ",")
        let slice = try VMParameters.serialize(maximum).parse()
        #expect(try slice.loadBigUInt(size: 8) == 0x07)
        #expect(try slice.loadBigUInt(size: 8) == 255)
        #expect(throws: ValidationError.self) { try VMParameters.serialize(maximum + ", n") }
        #expect(throws: ValidationError.self) { try VMParameters.serialize("t(\(maximum), n)") }
    }

    @Test(arguments: [
        ",n", "n,", "n,,n", "n n", "n)", "t", "t(n", "t(n,)", "t(,n)",
        "i", "i --1", "i 1.5", "i 0x10", "cell", "builder %%", "slice AA==",
        "continuation", "unknown", "n extra", "t(n) extra"
    ])
    func malformedInputIsRejected(_ expression: String) throws {
        #expect(throws: ValidationError.self) { try VMParameters.serialize(expression) }
    }

    @Test func multipleBOCRootsAreRejected() throws {
        let boc = try Boc.serialize(root: [Cell(), Cell(bits: [.b1])]).base64EncodedString()
        #expect(throws: ValidationError.self) { try VMParameters.serialize("c \(boc)") }
    }

    @Test func commandAcceptsNegativeIntegersAcrossArguments() async throws {
        let command = try #require(try await OpenEver.asyncParseAsRoot(
            ["liteclient", "make-vm-params", "n,", "i", "-1,", "t", "(i", "23,", "n)"]
        ) as? MakeVMParamsCommand)
        #expect(try VMParameters.serialize(command.parameters.joined(separator: " "))
            == VMParameters.serialize("none, integer -1, tuple(integer 23, none)"))
        #expect(OpenEver.helpMessage(for: LiteClientCommand.self).contains("make-vm-params"))
    }
}
