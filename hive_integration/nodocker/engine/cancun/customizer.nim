import
  std/[options, strutils, typetraits, random],
  nimcrypto/sysrand,
  stew/byteutils,
  ./blobs,
  ../tx_sender,
  ../../../../nimbus/constants,
  ../../../../nimbus/utils/utils,
  ../../../../nimbus/common as nimbus_common,
  ../../../../nimbus/beacon/web3_eth_conv,
  ../../../../nimbus/beacon/payload_conv,
  ../../../../nimbus/beacon/execution_types

type
  EngineAPIVersionResolver* = ref object of RootRef
    com: CommonRef

method setEngineAPIVersionResolver*(cust: EngineAPIVersionResolver, v: CommonRef) {.base.} =
  cust.com = v

method forkchoiceUpdatedVersion*(cust: EngineAPIVersionResolver,
  headTimestamp: uint64, payloadAttributesTimestamp: Option[uint64]): Version {.base.} =
  let ts = if payloadAttributesTimestamp.isNone: headTimestamp.EthTime
           else: payloadAttributesTimestamp.get().EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

method newPayloadVersion*(cust: EngineAPIVersionResolver, timestamp: uint64): Version {.base.} =
  let ts = timestamp.EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

method getPayloadVersion*(cust: EngineAPIVersionResolver, timestamp: uint64): Version {.base.} =
  let ts = timestamp.EthTime
  if cust.com.isCancunOrLater(ts):
    Version.V3
  elif cust.com.isShanghaiOrLater(ts):
    Version.V2
  else:
    Version.V1

type
  GetPayloadCustomizer* = ref object of EngineAPIVersionResolver

method getPayloadID*(cust: GetPayloadCustomizer,
         basePayloadID: PayloadID): PayloadID {.base.} =
  doAssert(false, "getPayloadID unimplemented")

method getExpectedError*(cust: GetPayloadCustomizer): int {.base.} =
  doAssert(false, "getExpectedError unimplemented")

type
  BaseGetPayloadCustomizer* = ref object of GetPayloadCustomizer
    customPayloadID: Option[PayloadID]
    expectedError  : int

method getPayloadID(cust: BaseGetPayloadCustomizer,
         basePayloadID: PayloadID): PayloadID =
  if cust.customPayloadID.isSome:
    return cust.customPayloadID.get
  return basePayloadID

method getExpectedError(cust: BaseGetPayloadCustomizer): int =
  cust.expectedError

type
  UpgradegetPayloadVersion* = ref object of GetPayloadCustomizer

method getPayloadVersion(cust: UpgradegetPayloadVersion, timestamp: uint64): Version =
  let version = procCall getPayloadVersion(cust.GetPayloadCustomizer, timestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

type
  DowngradegetPayloadVersion* = ref object of GetPayloadCustomizer

method getPayloadVersion(cust: DowngradegetPayloadVersion, timestamp: uint64): Version =
  let version = procCall getPayloadVersion(cust.GetPayloadCustomizer, timestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

type
  PayloadAttributesCustomizer* = ref object of GetPayloadCustomizer

method getPayloadAttributes*(cust: PayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes {.base.} =
  doAssert(false, "getPayloadAttributes unimplemented")

type
  BasePayloadAttributesCustomizer* = ref object of PayloadAttributesCustomizer
    timestamp             : Option[uint64]
    prevRandao            : Option[common.Hash256]
    suggestedFeeRecipient : Option[common.EthAddress]
    withdrawals           : Option[seq[Withdrawal]]
    removeWithdrawals     : bool
    beaconRoot            : Option[common.Hash256]
    removeBeaconRoot      : bool

method getPayloadAttributes(cust: BasePayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = PayloadAttributes(
    timestamp:             basePayloadAttributes.timestamp,
    prevRandao:            basePayloadAttributes.prevRandao,
    suggestedFeeRecipient: basePayloadAttributes.suggestedFeeRecipient,
    withdrawals:           basePayloadAttributes.withdrawals,
    parentBeaconBlockRoot: basePayloadAttributes.parentBeaconBlockRoot,
  )

  if cust.timestamp.isSome:
    customPayloadAttributes.timestamp = w3Qty cust.timestamp.get

  if cust.prevRandao.isSome:
    customPayloadAttributes.prevRandao = w3Hash cust.prevRandao.get

  if cust.suggestedFeeRecipient.isSome:
    customPayloadAttributes.suggestedFeeRecipient = w3Addr cust.suggestedFeeRecipient.get

  if cust.removeWithdrawals:
    customPayloadAttributes.withdrawals = none(seq[WithdrawalV1])
  elif cust.withdrawals.isSome:
    customPayloadAttributes.withdrawals = w3Withdrawals cust.withdrawals

  if cust.removeBeaconRoot:
    customPayloadAttributes.parentBeaconBlockRoot = none(Web3Hash)
  elif cust.beaconRoot.isSome:
    customPayloadAttributes.parentBeaconBlockRoot = w3Hash cust.beaconRoot

  return customPayloadAttributes

type
  TimestampDeltaPayloadAttributesCustomizer* = ref object of BasePayloadAttributesCustomizer
    timestampDelta: uint64

method getPayloadAttributes(cust: TimestampDeltaPayloadAttributesCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = procCall getPayloadAttributes(cust.BasePayloadAttributesCustomizer, basePayloadAttributes)
  customPayloadAttributes.timestamp = w3Qty(customPayloadAttributes.timestamp, cust.timestampDelta)
  return customPayloadAttributes

type
  ForkchoiceUpdatedCustomizer* = ref object of BasePayloadAttributesCustomizer

method getForkchoiceState*(cust: ForkchoiceUpdatedCustomizer,
  baseForkchoiceUpdate: ForkchoiceStateV1): ForkchoiceStateV1 {.base.} =
  doAssert(false, "getForkchoiceState unimplemented")

method getExpectInvalidStatus*(cust: ForkchoiceUpdatedCustomizer): bool {.base.} =
  doAssert(false, "getExpectInvalidStatus unimplemented")

# Customizer that makes no modifications to the forkchoice directive call.
# Used as base to other customizers.
type
  BaseForkchoiceUpdatedCustomizer* = ref object of ForkchoiceUpdatedCustomizer
    expectedError      : int
    expectInvalidStatus: bool

method getPayloadAttributes(cust: BaseForkchoiceUpdatedCustomizer, basePayloadAttributes: PayloadAttributes): PayloadAttributes =
  var customPayloadAttributes = procCall getPayloadAttributes(cust.BasePayloadAttributesCustomizer, basePayloadAttributes)
  return customPayloadAttributes

method getForkchoiceState(cust: BaseForkchoiceUpdatedCustomizer, baseForkchoiceUpdate: ForkchoiceStateV1): ForkchoiceStateV1 =
  return baseForkchoiceUpdate

method getExpectedError(cust: BaseForkchoiceUpdatedCustomizer): int =
  return cust.expectedError

method getExpectInvalidStatus(cust: BaseForkchoiceUpdatedCustomizer): bool =
  return cust.expectInvalidStatus

# Customizer that upgrades the version of the forkchoice directive call to the next version.
type
  UpgradeforkchoiceUpdatedVersion* = ref object of BaseForkchoiceUpdatedCustomizer

method forkchoiceUpdatedVersion(cust: UpgradeforkchoiceUpdatedVersion, headTimestamp: uint64, payloadAttributesTimestamp: Option[uint64]): Version =
  let version = procCall forkchoiceUpdatedVersion(EngineAPIVersionResolver(cust), headTimestamp, payloadAttributesTimestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

# Customizer that downgrades the version of the forkchoice directive call to the previous version.
type
  DowngradeforkchoiceUpdatedVersion* = ref object of BaseForkchoiceUpdatedCustomizer

method forkchoiceUpdatedVersion(cust: DowngradeforkchoiceUpdatedVersion, headTimestamp: uint64, payloadAttributesTimestamp: Option[uint64]): Version =
  let version = procCall forkchoiceUpdatedVersion(EngineAPIVersionResolver(cust), headTimestamp, payloadAttributesTimestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

type
  VersionedHashRef* = ref object of RootRef
    blobs*: seq[BlobID]
    hashVersions*: seq[byte]

proc getVersionedHashes*(v: VersionedHashRef): seq[common.Hash256] =
  if v.blobs.len == 0:
    return @[]

  result = newSeq[common.Hash256](v.blobs.len)

  var version: byte
  for i, blobID in v.blobs:
    if v.hashVersions.len > i:
      version = v.hashVersions[i]
    result[i] = blobID.getVersionedHash(version)

proc description*(v: VersionedHashRef): string =
  result = "VersionedHashes: "
  for x in v.blobs:
    result.add x.toHex

  if v.hashVersions.len > 0:
    result.add " with versions "
    result.add v.hashVersions.toHex

type
  VersionedHashesCustomizer* = ref object of RootRef
  IncreaseVersionVersionedHashes* = ref object of VersionedHashesCustomizer

method getVersionedHashes*(cust: VersionedHashesCustomizer, baseVersionedHashes: openArray[common.Hash256]): seq[common.Hash256] {.base.} =
  doAssert(false, "getVersionedHashes unimplemented")

method getVersionedHashes(cust: IncreaseVersionVersionedHashes, baseVersionedHashes: openArray[common.Hash256]): seq[common.Hash256] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  result = newSeq[common.Hash256](baseVersionedHashes.len)
  for i, h in baseVersionedHashes:
    result[i] = h
    result[i].data[0] = result[i].data[0] + 1

type
  CorruptVersionedHashes* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: CorruptVersionedHashes, baseVersionedHashes: openArray[common.Hash256]): seq[common.Hash256] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  result = newSeq[common.Hash256](baseVersionedHashes.len)
  for i, h in baseVersionedHashes:
    result[i] = h
    result[i].data[h.data.len-1] = result[i].data[h.data.len-1] + 1

type
  RemoveVersionedHash* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: RemoveVersionedHash, baseVersionedHashes: openArray[common.Hash256]): seq[common.Hash256] =
  doAssert(baseVersionedHashes.len > 0, "no versioned hashes available for modification")

  result = newSeq[common.Hash256](baseVersionedHashes.len - 1)
  for i, h in baseVersionedHashes:
    if i < baseVersionedHashes.len-1:
      result[i] = h
      result[i].data[h.data.len-1] = result[i].data[h.data.len-1] + 1

type
  ExtraVersionedHash* = ref object of VersionedHashesCustomizer

method getVersionedHashes(cust: ExtraVersionedHash, baseVersionedHashes: openArray[common.Hash256]): seq[common.Hash256] =
  result = newSeq[common.Hash256](baseVersionedHashes.len + 1)
  for i, h in baseVersionedHashes:
    result[i] = h

  var extraHash: common.Hash256
  doAssert randomBytes(extraHash.data) == 32
  extraHash.data[0] = VERSIONED_HASH_VERSION_KZG
  result[^1] = extraHash


type
  PayloadCustomizer* = ref object of EngineAPIVersionResolver

  ExecutableData* = object
    basePayload*: ExecutionPayload
    beaconRoot* : Option[common.Hash256]
    attr*       : PayloadAttributes
    versionedHashes*: seq[common.Hash256]

method customizePayload(cust: PayloadCustomizer, data: ExecutableData): ExecutableData {.base.} =
  doAssert(false, "customizePayload unimplemented")

method getTimestamp(cust: PayloadCustomizer, basePayload: ExecutionPayload): uint64 {.base.} =
  doAssert(false, "getTimestamp unimplemented")

type
  NewPayloadCustomizer* = ref object of PayloadCustomizer

method getExpectedError(cust: NewPayloadCustomizer): int {.base.} =
  doAssert(false, "getExpectedError unimplemented")

method getExpectInvalidStatus(cust: NewPayloadCustomizer): bool {.base.} =
  doAssert(false, "getExpectInvalidStatus unimplemented")

type
  CustomPayloadData = object
    parentHash*               : Option[common.Hash256]
    feeRecipient*             : Option[common.EthAddress]
    stateRoot*                : Option[common.Hash256]
    receiptsRoot*             : Option[common.Hash256]
    logsBloom*                : Option[BloomFilter]
    prevRandao*               : Option[common.Hash256]
    number*                   : Option[uint64]
    gasLimit*                 : Option[GasInt]
    gasUsed*                  : Option[GasInt]
    timestamp*                : Option[uint64]
    extraData*                : Option[common.Blob]
    baseFeePerGas*            : Option[UInt256]
    blockHash*                : Option[common.Hash256]
    transactions*             : Option[seq[Transaction]]
    withdrawals*              : Option[seq[Withdrawal]]
    removeWithdrawals*        : bool
    blobGasUsed*              : Option[uint64]
    removeBlobGasUsed*        : bool
    excessBlobGas*            : Option[uint64]
    removeExcessBlobGas*      : bool
    parentBeaconRoot*         : Option[common.Hash256]
    removeParentBeaconRoot*   : bool
    versionedHashesCustomizer*: VersionedHashesCustomizer

func getTimestamp*(cust: CustomPayloadData, basePayload: ExecutionPayload): uint64 =
  if cust.timestamp.isSome:
    return cust.timestamp.get
  return basePayload.timestamp.uint64

# Construct a customized payload by taking an existing payload as base and mixing it CustomPayloadData
# blockHash is calculated automatically.
proc customizePayload*(cust: CustomPayloadData, data: ExecutableData): ExecutableData =
  var customHeader = blockHeader(data.basePayload, data.beaconRoot)

  if cust.transactions.isSome:
    customHeader.txRoot = calcTxRoot(cust.transactions.get)

  # Overwrite custom information
  if cust.parentHash.isSome:
    customHeader.parentHash = cust.parentHash.get

  if cust.feeRecipient.isSome:
    customHeader.coinbase = cust.feeRecipient.get

  if cust.stateRoot.isSome:
    customHeader.stateRoot = cust.stateRoot.get

  if cust.receiptsRoot.isSome:
    customHeader.receiptRoot = cust.receiptsRoot.get

  if cust.logsBloom.isSome:
    customHeader.bloom = cust.logsBloom.get

  if cust.prevRandao.isSome:
    customHeader.mixDigest = cust.prevRandao.get

  if cust.number.isSome:
    customHeader.blockNumber = cust.number.get.u256

  if cust.gasLimit.isSome:
    customHeader.gasLimit = cust.gasLimit.get

  if cust.gasUsed.isSome:
    customHeader.gasUsed = cust.gasUsed.get

  if cust.timestamp.isSome:
    customHeader.timestamp = cust.timestamp.get.EthTime

  if cust.extraData.isSome:
    customHeader.extraData = cust.extraData.get

  if cust.baseFeePerGas.isSome:
    customHeader.fee = cust.baseFeePerGas

  if cust.removeWithdrawals:
    customHeader.withdrawalsRoot = none(common.Hash256)
  elif cust.withdrawals.isSome:
    let h = calcWithdrawalsRoot(cust.withdrawals.get)
    customHeader.withdrawalsRoot = some(h)

  if cust.removeBlobGasUsed:
    customHeader.blobGasUsed = none(uint64)
  elif cust.blobGasUsed.isSome:
    customHeader.blobGasUsed = cust.blobGasUsed

  if cust.removeExcessBlobGas:
    customHeader.excessBlobGas = none(uint64)
  elif cust.excessBlobGas.isSome:
    customHeader.excessBlobGas = cust.excessBlobGas

  if cust.removeParentBeaconRoot:
    customHeader.parentBeaconBlockRoot = none(common.Hash256)
  elif cust.parentBeaconRoot.isSome:
    customHeader.parentBeaconBlockRoot = cust.parentBeaconRoot

  var blk = EthBlock(
    header: customHeader,
  )

  if cust.removeWithdrawals:
    blk.withdrawals = none(seq[Withdrawal])
  elif cust.withdrawals.isSome:
    blk.withdrawals = cust.withdrawals
  elif data.basePayload.withdrawals.isSome:
    blk.withdrawals = ethWithdrawals data.basePayload.withdrawals

  result = ExecutableData(
    basePayload    : executionPayload(blk),
    beaconRoot     : blk.header.parentBeaconBlockRoot,
    attr           : data.attr,
    versionedHashes: data.versionedHashes,
  )

  if cust.versionedHashesCustomizer.isNil.not:
    result.versionedHashes = cust.versionedHashesCustomizer.getVersionedHashes(data.versionedHashes)


# Base new payload directive call cust.
# Used as base to other customizers.
type
  BaseNewPayloadVersionCustomizer* = ref object of NewPayloadCustomizer
    payloadCustomizer*  : CustomPayloadData
    expectedError*      : int
    expectInvalidStatus*: bool

method customizePayload(cust: BaseNewPayloadVersionCustomizer, data: ExecutableData): ExecutableData =
  cust.payloadCustomizer.customizePayload(data)

method getExpectedError(cust: BaseNewPayloadVersionCustomizer): int =
  cust.expectedError

method getExpectInvalidStatus(cust: BaseNewPayloadVersionCustomizer): bool =
  cust.expectInvalidStatus

# Customizer that upgrades the version of the payload to the next version.
type
  UpgradeNewPayloadVersion* = ref object of NewPayloadCustomizer

method newPayloadVersion(cust: UpgradeNewPayloadVersion, timestamp: uint64): Version =
  let version = procCall newPayloadVersion(EngineAPIVersionResolver(cust), timestamp)
  doAssert(version != Version.high, "cannot upgrade version " & $Version.high)
  version.succ

# Customizer that downgrades the version of the payload to the previous version.
type
  DowngradeNewPayloadVersion* = ref object of NewPayloadCustomizer

method newPayloadVersion(cust: DowngradeNewPayloadVersion, timestamp: uint64): Version =
  let version = procCall newPayloadVersion(EngineAPIVersionResolver(cust), timestamp)
  doAssert(version != Version.V1, "cannot downgrade version 1")
  version.pred

proc customizePayloadTransactions*(data: ExecutableData, customTransactions: openArray[Transaction]): ExecutableData =
  let cpd = CustomPayloadData(
    transactions: some(@customTransactions),
  )
  customizePayload(cpd, data)

proc `$`*(cust: CustomPayloadData): string =
  var fieldList = newSeq[string]()

  if cust.parentHash.isSome:
    fieldList.add "parentHash=" & cust.parentHash.get.short

  if cust.feeRecipient.isSome:
    fieldList.add "Coinbase=" & $cust.feeRecipient.get

  if cust.stateRoot.isSome:
    fieldList.add "stateRoot=" & cust.stateRoot.get.short

  if cust.receiptsRoot.isSome:
    fieldList.add "receiptsRoot=" & cust.receiptsRoot.get.short

  if cust.logsBloom.isSome:
    fieldList.add "logsBloom=" & cust.logsBloom.get.toHex

  if cust.prevRandao.isSome:
    fieldList.add "prevRandao=" & cust.prevRandao.get.short

  if cust.number.isSome:
    fieldList.add "Number=" & $cust.number.get

  if cust.gasLimit.isSome:
    fieldList.add "gasLimit=" & $cust.gasLimit.get

  if cust.gasUsed.isSome:
    fieldList.add "gasUsed=" & $cust.gasUsed.get

  if cust.timestamp.isSome:
    fieldList.add "timestamp=" & $cust.timestamp.get

  if cust.extraData.isSome:
    fieldList.add "extraData=" & cust.extraData.get.toHex

  if cust.baseFeePerGas.isSome:
    fieldList.add "baseFeePerGas=" & $cust.baseFeePerGas.get

  if cust.transactions.isSome:
    fieldList.add "transactions=" & $cust.transactions.get.len

  if cust.withdrawals.isSome:
    fieldList.add "withdrawals=" & $cust.withdrawals.get.len

  fieldList.join(", ")

type
  InvalidPayloadBlockField* = enum
    InvalidParentHash
    InvalidStateRoot
    InvalidReceiptsRoot
    InvalidNumber
    InvalidGasLimit
    InvalidGasUsed
    InvalidTimestamp
    InvalidPrevRandao
    RemoveTransaction
    InvalidTransactionSignature
    InvalidTransactionNonce
    InvalidTransactionGas
    InvalidTransactionGasPrice
    InvalidTransactionValue
    InvalidTransactionGasTipPrice
    InvalidTransactionChainID
    InvalidParentBeaconBlockRoot
    InvalidExcessBlobGas
    InvalidBlobGasUsed
    InvalidBlobCountGasUsed
    InvalidVersionedHashesVersion
    InvalidVersionedHashes
    IncompleteVersionedHashes
    ExtraVersionedHashes
    InvalidWithdrawals

func scramble(data: Web3Hash): Option[common.Hash256] =
  var h = ethHash data
  h.data[^1] = byte(255 - h.data[^1])
  some(h)

func scramble(data: common.Hash256): Option[common.Hash256] =
  var h = data
  h.data[^1] = byte(255 - h.data[^1])
  some(h)

# This function generates an invalid payload by taking a base payload and modifying the specified field such that it ends up being invalid.
# One small consideration is that the payload needs to contain transactions and specially transactions using the PREVRANDAO opcode for all the fields to be compatible with this function.
proc generateInvalidPayload*(sender: TxSender, data: ExecutableData, payloadField: InvalidPayloadBlockField): ExecutableData =
  var customPayloadMod: CustomPayloadData
  let basePayload = data.basePayload

  case payloadField
  of InvalidParentHash:
    customPayloadMod = CustomPayloadData(
      parentHash: scramble(basePayload.parentHash),
    )
  of InvalidStateRoot:
    customPayloadMod = CustomPayloadData(
      stateRoot: scramble(basePayload.stateRoot),
    )
  of InvalidReceiptsRoot:
    customPayloadMod = CustomPayloadData(
      receiptsRoot: scramble(basePayload.receiptsRoot),
    )
  of InvalidNumber:
    let modNumber = basePayload.blockNumber.uint64 - 1
    customPayloadMod = CustomPayloadData(
      number: some(modNumber),
    )
  of InvalidGasLimit:
    let modGasLimit = basePayload.gasLimit.GasInt * 2
    customPayloadMod = CustomPayloadData(
      gasLimit: some(modGasLimit),
    )
  of InvalidGasUsed:
    let modGasUsed = basePayload.gasUsed.GasInt - 1
    customPayloadMod = CustomPayloadData(
      gasUsed: some(modGasUsed),
    )
  of InvalidTimestamp:
    let modTimestamp = basePayload.timestamp.uint64 - 1
    customPayloadMod = CustomPayloadData(
      timestamp: some(modTimestamp),
    )
  of InvalidPrevRandao:
    # This option potentially requires a transaction that uses the PREVRANDAO opcode.
    # Otherwise the payload will still be valid.
    var randomHash: common.Hash256
    doAssert randomBytes(randomHash.data) == 32
    customPayloadMod = CustomPayloadData(
      prevRandao: some(randomHash),
    )
  of InvalidParentBeaconBlockRoot:
    doAssert(data.beaconRoot.isSome,
      "no parent beacon block root available for modification")
    customPayloadMod = CustomPayloadData(
      parentBeaconRoot: scramble(data.beaconRoot.get),
    )
  of InvalidBlobGasUsed:
    doAssert(basePayload.blobGasUsed.isSome, "no blob gas used available for modification")
    let modBlobGasUsed = basePayload.blobGasUsed.get.uint64 + 1
    customPayloadMod = CustomPayloadData(
      blobGasUsed: some(modBlobGasUsed),
    )
  of InvalidBlobCountGasUsed:
    doAssert(basePayload.blobGasUsed.isSome, "no blob gas used available for modification")
    let modBlobGasUsed = basePayload.blobGasUsed.get.uint64 + GAS_PER_BLOB
    customPayloadMod = CustomPayloadData(
      blobGasUsed: some(modBlobGasUsed),
    )
  of InvalidExcessBlobGas:
    doAssert(basePayload.excessBlobGas.isSome, "no excess blob gas available for modification")
    let modExcessBlobGas = basePayload.excessBlobGas.get.uint64 + 1
    customPayloadMod = CustomPayloadData(
      excessBlobGas: some(modExcessBlobGas),
    )
  of InvalidVersionedHashesVersion:
    doAssert(data.versionedHashes.len > 0, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: IncreaseVersionVersionedHashes(),
    )
  of InvalidVersionedHashes:
    doAssert(data.versionedHashes.len > 0, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: CorruptVersionedHashes(),
    )
  of IncompleteVersionedHashes:
    doAssert(data.versionedHashes.len > 0, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: RemoveVersionedHash(),
    )
  of ExtraVersionedHashes:
    doAssert(data.versionedHashes.len > 0, "no versioned hashes available for modification")
    customPayloadMod = CustomPayloadData(
      versionedHashesCustomizer: ExtraVersionedHash(),
    )
  of InvalidWithdrawals:
    # These options are not supported yet.
    # TODO: Implement
    doAssert(false, "invalid payload field not supported yet: " & $payloadField)
  of RemoveTransaction:
    let emptyTxs = newSeq[Transaction]()
    customPayloadMod = CustomPayloadData(
      transactions: some(emptyTxs),
    )
  of InvalidTransactionSignature,
    InvalidTransactionNonce,
    InvalidTransactionGas,
    InvalidTransactionGasPrice,
    InvalidTransactionGasTipPrice,
    InvalidTransactionValue,
    InvalidTransactionChainID:

    doAssert(basePayload.transactions.len > 0, "no transactions available for modification")
    let baseTx = rlp.decode(distinctBase basePayload.transactions[0], Transaction)
    var custTx: CustomTransactionData

    case payloadField
    of InvalidTransactionSignature:
      custTx.signature = some(baseTx.R - 1.u256)
    of InvalidTransactionNonce:
      custTx.nonce = some(baseTx.nonce - 1)
    of InvalidTransactionGas:
      custTx.gas = some(0.GasInt)
    of InvalidTransactionGasPrice:
      custTx.gasPriceOrGasFeeCap = some(0.GasInt)
    of InvalidTransactionGasTipPrice:
      custTx.gasTipCap = some(gasTipPrice.GasInt * 2.GasInt)
    of InvalidTransactionValue:
      # Vault account initially has 0x123450000000000000000, so this value should overflow
      custTx.value = some(UInt256.fromHex("0x123450000000000000001"))
    of InvalidTransactionChainID:
      custTx.chainId = some(ChainId(baseTx.chainId.uint64 + 1))
    else: discard

    let modifiedTx = sender.customizeTransaction(baseTx, custTx)
    customPayloadMod = CustomPayloadData(
      transactions: some(@[modifiedTx]),
    )

  customPayloadMod.customizePayload(data)

# Generates an alternative withdrawals list that contains the same
# amounts and accounts, but the order in the list is different, so
# stateRoot of the resulting payload should be the same.

proc randomizeWithdrawalsOrder(src: openArray[Withdrawal]): seq[Withdrawal] =
  result = @src
  result.shuffle
