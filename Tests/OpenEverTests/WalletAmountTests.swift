import ArgumentParser
import BigInt
import Testing
@testable import OpenEver

struct WalletAmountTests {
    @Test func dotAndCommaAmountsConvertExactly() throws {
        #expect(try WalletAmount.ever("1.45") == 1_450_000_000)
        #expect(try WalletAmount.ever("1,45") == 1_450_000_000)
        #expect(try WalletAmount.ever("0.000000001") == 1)
        #expect(try WalletAmount.ever("0,000000001") == 1)
        #expect(try WalletAmount.ever("0") == 0)
        #expect(try WalletAmount.ever("001.45000000000") == 1_450_000_000)
        #expect(try WalletAmount.ever("12.") == 12_000_000_000)
        #expect(try WalletAmount.ever(" 12,\n") == 12_000_000_000)
    }

    @Test func amountsBeyondFloatingPointPrecisionRemainExact() throws {
        let expected = BigUInt("9007199254740993123456789")
        #expect(try WalletAmount.ever("9007199254740993.123456789") == expected)
        #expect(try WalletAmount.nanoEver("9007199254740993123456789") == expected)
        #expect(try WalletAmount.nanoEver("00001") == 1)
    }

    @Test func amountsMustFitTheGramsWireFormat() throws {
        let maximum = (BigUInt(1) << 120) - 1
        #expect(try WalletAmount.nanoEver(String(maximum)) == maximum)
        #expect(try WalletAmount.ever(WalletAmount.format(nanoEver: maximum)) == maximum)
        #expect(throws: ValidationError.self) { try WalletAmount.nanoEver(String(maximum + 1)) }
        #expect(throws: ValidationError.self) {
            try WalletAmount.ever(WalletAmount.format(nanoEver: maximum + 1))
        }
    }

    @Test func formatsExactEverBalanceWithoutTrailingZeros() throws {
        #expect(WalletAmount.format(nanoEver: 0) == "0")
        #expect(WalletAmount.format(nanoEver: 1) == "0.000000001")
        #expect(WalletAmount.format(nanoEver: 1_450_000_000) == "1.45")
        #expect(WalletAmount.format(nanoEver: 10_000_000_000) == "10")
        #expect(WalletAmount.format(nanoEver: BigUInt("9007199254740993123456789"))
            == "9007199254740993.123456789")
    }

    @Test(arguments: [
        "", " ", "-1", "+1", "-0.1", ".", ",", ".1", "1..", "1.,",
        "1.2.3", "1,234.56", "1e2", "1 000", "NaN", "Inf", "1abc",
        "0.0000000001", "1.0000000001", "1.2345678911", "١.٢"
    ])
    func invalidOrInexactEverAmountsAreRejected(_ value: String) throws {
        #expect(throws: ValidationError.self) { try WalletAmount.ever(value) }
    }

    @Test(arguments: ["", " ", "-1", "+1", "1.0", "1,0", "1e2", "0x10", "1 000", "١"])
    func nanoEverRequiresAnUnsignedDecimalInteger(_ value: String) throws {
        #expect(throws: ValidationError.self) { try WalletAmount.nanoEver(value) }
    }
}
