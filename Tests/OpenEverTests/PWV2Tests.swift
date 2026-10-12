import BigInt
import EverscaleSdkSwift
import EverLiteClient
import Foundation
import SwiftExtensionsPack
import Testing
@testable import OpenEver

struct PWV2Tests {
    private let secret = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    private let publicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"

    @Test func addressMatchesIndependentCellHashVectorAcrossWorkchains() throws {
        let hash = "9ef68d89748874e9794039dd85897a1294afc1e145e38321f8d42a5a26d1130f"
        for workchain in [-128, -1, 0, 42, 127] {
            let wallet = try PWV2(publicKey: Data(repeating: 0, count: 32), workchain: workchain)
            #expect(wallet.address.toString() == "\(workchain):\(hash)")
            #expect(try wallet.stateInit.data.code?.hash().lowercased() == PWV2.codeHash)
        }
        #expect(throws: RuntimeError.self) { try PWV2(publicKey: Data(repeating: 0, count: 31)) }
        #expect(throws: RuntimeError.self) { try PWV2(publicKey: Data(repeating: 0, count: 32), workchain: 128) }
    }

    @Test(arguments: [false, true])
    func parsesEverscaleAccountFormatsAndSequenceNumber(versioned: Bool) throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey), workchain: -1)
        let data = try CellBuilder().storeBytes(wallet.publicKey).storeUInt(65535, 16).cell()
        let stateInit = try StateInit(options: .init(code: wallet.stateInit.data.code, data: data))
        let nanoEver = (BigUInt(1) << 100) + 123456789
        let boc = try makePWV2AccountState(wallet: wallet, balance: nanoEver, stateInit: stateInit, versioned: versioned)
        let state = try PWV2AccountState.parse(boc, expectedAddress: wallet.address)
        #expect(state.status == .active)
        #expect(!state.needsDeployment)
        #expect(state.balance == nanoEver)
        #expect(try wallet.sequenceNumber(in: state) == 65535)
    }

    @Test func absentAndUninitializedAccountsDeployAtZeroSequenceNumber() throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey))
        for boc in [BagOfCells(Data()), try BagOfCells(cell: CellBuilder().storeBit(.b0).cell())] {
            let state = try PWV2AccountState.parse(boc)
            #expect(state.status == .nonexistent)
            #expect(state.balance == 0)
            #expect(state.needsDeployment)
            #expect(try wallet.sequenceNumber(in: state) == 0)
        }
        let state = try PWV2AccountState.parse(makePWV2AccountState(wallet: wallet, balance: 100))
        #expect(state.status == .uninitialized)
        #expect(state.balance == 100)
        #expect(state.needsDeployment)
        #expect(try wallet.sequenceNumber(in: state) == 0)
    }

    @Test func frozenWrongAddressAndChangedCodeAreRejectedForSending() throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey))
        let frozen = try PWV2AccountState.parse(makePWV2AccountState(wallet: wallet, balance: 100, frozen: true))
        #expect(frozen.status == .frozen)
        #expect(throws: RuntimeError.self) { try wallet.sequenceNumber(in: frozen) }
        let otherWallet = try PWV2(publicKey: Data(repeating: 0, count: 32))
        #expect(throws: RuntimeError.self) {
            try PWV2AccountState.parse(makePWV2AccountState(wallet: wallet, balance: 100), expectedAddress: otherWallet.address)
        }
        let wrongCode = try StateInit(options: .init(code: Cell(), data: wallet.stateInit.data.data))
        let changedCode = try PWV2AccountState.parse(makePWV2AccountState(wallet: wallet, balance: 100, stateInit: wrongCode))
        #expect(throws: RuntimeError.self) { try wallet.sequenceNumber(in: changedCode) }
        let wrongKey = try StateInit(options: .init(code: wallet.stateInit.data.code, data: otherWallet.stateInit.data.data))
        let changedKey = try PWV2AccountState.parse(makePWV2AccountState(wallet: wallet, balance: 100, stateInit: wrongKey))
        #expect(throws: RuntimeError.self) { try wallet.sequenceNumber(in: changedKey) }
    }

    @Test func rejectsMalformedAndMultipleRootAccountStates() throws {
        #expect(throws: (any Error).self) { try PWV2AccountState.parse(BagOfCells(cell: Cell())) }
        #expect(throws: (any Error).self) {
            try PWV2AccountState.parse(BagOfCells(cells: [Cell(bits: [.b0]), Cell(bits: [.b0])]))
        }
        #expect(throws: (any Error).self) {
            try PWV2AccountState.parse(BagOfCells(cell: Cell(bits: [.b0], refs: [Cell()])))
        }
        #expect(throws: (any Error).self) {
            try PWV2AccountState.parse(BagOfCells(cell: CellBuilder().storeUInt(2, 4).cell()))
        }
    }

    @Test func signedTransferPreservesFlagsAmountsPayloadAndDestinationState() throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey), workchain: -1)
        let destination = try PWV2(publicKey: Data(repeating: 0, count: 32), workchain: 42)
        let body = try CellBuilder().storeUInt(0xdeadbeef, 32).storeRef(Cell(bits: [.b1])).cell()
        let nanoEver = (BigUInt(1) << 80) + 1450000000
        let message = try wallet.buildTransfer(destination: destination.address, nanoEver: nanoEver, flag: 128,
                                               bounce: true, body: body, stateInit: destination.stateInit,
                                               seqno: 42, secretKey: Input.hex(secret), deploy: true,
                                               validUntil: 1900000000)
        let parsed = try Message.parse(cs: message.cell().parse())
        #expect(try parsed.data.stateInit?.cell().hash() == wallet.stateInit.cell().hash())
        guard case let .extInMsgInfo(info) = parsed.data.info else { Issue.record("Expected an external inbound message"); return }
        #expect(info.dest == wallet.address)
        let signedBody = try #require(parsed.data.body).parse()
        let signature = try signedBody.loadBytes(size: 64)
        let inner = try signedBody.loadRef()
        #expect(signedBody.bits.isEmpty && signedBody.refs.isEmpty)
        let signedData = try Input.hex(inner.hash())
        #expect(signedData.count == 32)
        #expect(SEPCrypto.Ed25519.verify(signature: signature, message: signedData, len: signedData.count,
                                       publicKey: wallet.publicKey))
        let innerSlice = inner.parse()
        #expect(try innerSlice.loadBigUInt(size: 64) == 1900000000)
        #expect(try innerSlice.loadBigUInt(size: 16) == 42)
        let actions = try innerSlice.loadRef().parse()
        let tail = try actions.loadRef()
        #expect(tail.bits.isEmpty && tail.refs.isEmpty)
        let action = try OutAction.parse(cs: actions)
        guard case let .actionSendMsg(send) = action else { Issue.record("Expected a send action"); return }
        #expect(send.mode == 128)
        #expect(try send.outMsg.data.body?.hash() == body.hash())
        #expect(try send.outMsg.data.stateInit?.cell().hash() == destination.stateInit.cell().hash())
        let outgoing = try RawCommonMsgInfo.parse(cs: send.outMsg.data.info.cell().parse(), relaxed: true)
        guard case let .internalMessage(info) = outgoing else { Issue.record("Expected an internal message"); return }
        #expect(try info.dest.asAddress() == destination.address)
        #expect(info.value.grams == nanoEver)
        #expect(info.bounce)
    }

    @Test func signingRejectsMismatchedPrivateKeyAndOverflowingValue() throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey))
        #expect(throws: RuntimeError.self) {
            try wallet.buildTransfer(destination: wallet.address, nanoEver: 1, flag: 3, seqno: 0,
                                     secretKey: Data(repeating: 0, count: 32), deploy: false)
        }
        #expect(throws: (any Error).self) {
            try wallet.buildTransfer(destination: wallet.address, nanoEver: BigUInt(1) << 120, flag: 3, seqno: 0,
                                     secretKey: Input.hex(secret), deploy: false)
        }
    }

    @Test(arguments: [-128, -127, -2, -1, 0, 42, 127], [false, true])
    func workchainBytesAreTwosComplementInBothMessageHeaders(_ workchain: Int, _ deploy: Bool) throws {
        let wallet = try PWV2(publicKey: Input.hex(publicKey), workchain: workchain)
        let destination = try PWV2(publicKey: Data(repeating: 0, count: 32), workchain: workchain)
        let message = try wallet.buildTransfer(destination: destination.address, nanoEver: 1, flag: 3,
                                               seqno: 0, secretKey: Input.hex(secret), deploy: deploy,
                                               validUntil: 1900000000)
        let root = try message.cell()
        let externalHeader = root.parse()
        #expect(try externalHeader.loadBigUInt(size: 7) == 0b1000100)
        #expect(try externalHeader.loadBigUInt(size: 8) == BigUInt(UInt8(bitPattern: Int8(workchain))))
        #expect(try externalHeader.loadBytes(size: 32) == wallet.address.hash)
        let decoded = try Message.parse(cs: root.parse())
        #expect(try decoded.cell().hash() == root.hash())
        let signedBody = try #require(decoded.data.body).parse()
        try signedBody.skipBits(size: 512)
        let inner = try signedBody.loadRef().parse()
        try inner.skipBits(size: 80)
        let actions = try inner.loadRef().parse()
        _ = try actions.skipRefs(size: 1)
        try actions.skipBits(size: 40)
        let outgoing = try actions.loadRef()
        let internalHeader = outgoing.parse()
        #expect(try internalHeader.loadBigUInt(size: 9) == 0b010000100)
        #expect(try internalHeader.loadBigUInt(size: 8) == BigUInt(UInt8(bitPattern: Int8(workchain))))
        #expect(try internalHeader.loadBytes(size: 32) == destination.address.hash)
        #expect(try Message.parse(cs: outgoing.parse()).cell().hash() == outgoing.hash())
        let accountState = try makePWV2AccountState(wallet: wallet, balance: 1, seqno: 7)
        #expect(try wallet.sequenceNumber(in: PWV2AccountState.parse(accountState,
                                                                   expectedAddress: wallet.address)) == 7)
    }
}

func makePWV2AccountState(wallet: PWV2, balance: BigUInt, stateInit: StateInit? = nil, seqno: UInt16? = nil,
                         versioned: Bool = false, frozen: Bool = false) throws -> BagOfCells {
    var stateInit = stateInit
    if let seqno {
        let data = try CellBuilder().storeBytes(wallet.publicKey).storeUInt(BigUInt(seqno), 16).cell()
        stateInit = try StateInit(options: .init(code: wallet.stateInit.data.code, data: data))
    }
    let builder = CellBuilder()
    if versioned { try builder.storeUInt(1, 4) } else { try builder.storeBit(.b1) }
    try builder.storeAddress(wallet.address)
        .storeVarUInt(5, 7).storeVarUInt(500, 7).storeVarUInt(0, 7)
        .storeUInt(1700000000, 32).storeBit(.b1).storeVarUInt(123, 16)
        .storeUInt(123456789, 64)
    var currencies = try CurrencyCollection(grams: balance)
    try currencies.setAmount(500, for: 17)
    try builder.storeSlice(currencies.cell().parse())
    if let stateInit { try builder.storeBit(.b1).storeSlice(stateInit.cell().parse()) }
    else if frozen { try builder.storeUInt(1, 2).storeUInt(0, 256) }
    else { try builder.storeUInt(0, 2) }
    if versioned { try builder.storeBit(.b1).storeBytes(Input.hex(PWV2.codeHash)) }
    return try BagOfCells(cell: builder.cell())
}
