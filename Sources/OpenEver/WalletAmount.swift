import ArgumentParser
import BigInt
import EverscaleSdkSwift
import Foundation

enum WalletAmount {
    static func normalized(_ value: String) -> String {
        // Adapted from ObertonCore String.toNanoCrystals(decimals:).
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    static func ever(_ value: String) throws -> BigUInt {
        let parts = normalized(value).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw ValidationError("Expected a non-negative EVER amount using a dot or comma as the decimal separator.")
        }

        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" { fraction.removeLast() }
        guard fraction.count <= 9 else {
            throw ValidationError("The EVER amount cannot have more than nine non-zero decimal places.")
        }
        let nanoText = String(parts[0]) + fraction + String(repeating: "0", count: 9 - fraction.count)
        return try nanoEver(nanoText)
    }

    static func nanoEver(_ value: String) throws -> BigUInt {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = BigUInt(text) else {
            throw ValidationError("Expected a non-negative integer amount in nanoEVER.")
        }
        guard amount.bitWidth <= 120 else {
            throw ValidationError("The amount must fit the 120-bit Grams field.")
        }
        return amount
    }

    static func format(nanoEver: BigUInt) -> String {
        Coins(nanoValue: nanoEver).toFloatString
    }
}
