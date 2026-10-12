import BigInt
import EverscaleSdkSwift
import EverLiteClient
import Foundation
import SwiftExtensionsPack

struct PWV2 {
    // Compiled ton-preprocessed-wallet-v2 by pyAndr3w, LGPL-3.0-or-later.
    // https://github.com/pyAndr3w/ton-preprocessed-wallet-v2/blob/main/pw-code.fif
    static let codeBOC = "B5EE9C7241010101003D000076FF00DDD40120F90001D0D33FD30FD74CED44D0D3FFD70B0F20A4830FA90822C8CBFFCB0FC9ED5444301046BAF2A1F823BEF2A2F910F2A3F800ED552E766412"
    static let codeHash = "45ebbce9b5d235886cb6bfe1c3ad93b708de058244892365c9ee0dfe439cb7b5"

    let publicKey: Data
    let address: Address
    let stateInit: StateInit

    init(publicKey: Data, workchain: Int = 0) throws {
        guard publicKey.count == 32 else { throw RuntimeError("A PWV2 public key must contain exactly 32 bytes.") }
        guard Int8(exactly: workchain) != nil else { throw RuntimeError("The workchain must be between -128 and 127.") }
        guard let code = try Boc.deserialize(data: Input.hex(Self.codeBOC)).first,
              try code.hash().lowercased() == Self.codeHash else {
            throw RuntimeError("Invalid PWV2 contract code.")
        }
        self.publicKey = publicKey
        let data = try CellBuilder().storeBytes(publicKey).storeUInt(0, 16).cell()
        stateInit = try StateInit(options: StateInitOptions(code: code, data: data))
        address = try Address(address: "\(workchain):\(stateInit.cell().hash())")
    }

    func sequenceNumber(in state: PWV2AccountState) throws -> UInt16 {
        if let stateAddress = state.address, stateAddress != address {
            throw RuntimeError("The returned account state does not match the wallet address.")
        }
        switch state.status {
        case .nonexistent, .uninitialized:
            return 0
        case .frozen:
            throw RuntimeError("The wallet account is frozen.")
        case .active:
            guard let initData = state.stateInit?.data,
                  let code = initData.code, try code.hash().lowercased() == Self.codeHash,
                  let data = initData.data else {
                throw RuntimeError("The active account is not a PWV2 wallet.")
            }
            let storage = try data.ordinarySlice()
            let storedKey = try storage.loadBytes(size: 32)
            let seqno = UInt16(try storage.loadBigUInt(size: 16))
            guard storage.bits.isEmpty, storage.refs.isEmpty, storedKey == publicKey else {
                throw RuntimeError("The wallet storage or public key does not match PWV2.")
            }
            return seqno
        }
    }

    func buildTransfer(
        destination: Address, nanoEver: BigUInt, flag: UInt8, bounce: Bool = false,
        body: Cell? = nil, stateInit destinationStateInit: StateInit? = nil,
        seqno: UInt16, secretKey: Data, deploy: Bool,
        validUntil: UInt64 = UInt64(Date().timeIntervalSince1970) + 60
    ) throws -> Message {
        guard secretKey.count == 32 else { throw RuntimeError("A private key must contain exactly 32 bytes.") }
        let keys = SEPCrypto.Ed25519.createKeyPair(seed32Byte: secretKey)
        guard keys.public == publicKey else { throw RuntimeError("The private key does not match the wallet public key.") }
        let value = try CurrencyCollection(grams: nanoEver)
        let info = CommonMsgInfo.raw(.internalMessage(RawInternalMessageInfo(
            bounce: bounce, dest: MessageAddress(destination), value: value
        )))
        let outgoing = try Message(options: MessageOptions(info: info, stateInit: destinationStateInit, body: body))
        let actions = try OutList(options: OutListOptions(action: [
            .actionSendMsg(OutAction.ActionSendMsg(mode: flag, outMsg: outgoing))
        ])).cell()
        let inner = try CellBuilder().storeUInt(BigUInt(validUntil), 64)
            .storeUInt(BigUInt(seqno), 16).storeRef(actions).cell()
        let signedData = try Input.hex(inner.hash())
        let signature = SEPCrypto.Ed25519.sign(message: signedData, publicKey32byte: keys.public,
                                              secretKey64byte: keys.secret)
        let signedBody = try CellBuilder().storeBytes(signature).storeRef(inner).cell()
        return try Message(options: MessageOptions(
            info: .extInMsgInfo(CommonMsgInfo.ExtInMsgInfo(dest: address)),
            stateInit: deploy ? self.stateInit : nil, body: signedBody
        ))
    }
}

struct PWV2AccountState {
    enum Status: String {
        case nonexistent, uninitialized, active, frozen
    }

    let address: Address?
    let balance: BigUInt
    let status: Status
    let stateInit: StateInit?

    var needsDeployment: Bool { status == .nonexistent || status == .uninitialized }

    static func parse(_ boc: BagOfCells, expectedAddress: Address? = nil) throws -> Self {
        let absent = Self(address: nil, balance: 0, status: .nonexistent, stateInit: nil)
        guard let root = try boc.singleCell() else { return absent }
        let slice = try root.ordinarySlice()
        let originalFormat = try slice.loadBit() == .b1
        if !originalFormat {
            if slice.bits.isEmpty {
                try requireEnd(slice)
                return absent
            }
            let version = try slice.loadBigUInt(size: 3)
            if version == 0 {
                try requireEnd(slice)
                return absent
            }
            guard version == 1 else { throw RuntimeError("Unsupported Everscale account-state version \(version).") }
        }
        guard let address = try MessageAddress.parse(cs: slice).asAddress() else {
            throw RuntimeError("The account state has no internal address.")
        }
        if let expectedAddress, address != expectedAddress {
            throw RuntimeError("The returned account state does not match the requested address.")
        }
        // Everscale StorageUsed: cells, bits and public_cells, all VarUInteger 7.
        for _ in 0..<3 {
            _ = try slice.loadVarBigUInt(length: 7)
        }
        try slice.skipBits(size: 32) // last_paid
        if try slice.loadBit() == .b1 { _ = try slice.loadVarBigUInt(length: 16) }
        try slice.skipBits(size: 64) // last_trans_lt
        let balance = try CurrencyCollection.parse(cs: slice).grams
        let status: Status
        let stateInit: StateInit?
        if try slice.loadBit() == .b1 {
            status = .active
            stateInit = try StateInit.parse(cs: slice)
        } else {
            status = try slice.loadBit() == .b1 ? .frozen : .uninitialized
            if status == .frozen { try slice.skipBits(size: 256) }
            stateInit = nil
        }
        if !originalFormat, try slice.loadBit() == .b1 { try slice.skipBits(size: 256) }
        try requireEnd(slice)
        return Self(address: address, balance: balance, status: status, stateInit: stateInit)
    }

    private static func requireEnd(_ slice: CellSlice) throws {
        guard slice.bits.isEmpty, slice.refs.isEmpty else { throw RuntimeError("Account state contains trailing data.") }
    }
}
