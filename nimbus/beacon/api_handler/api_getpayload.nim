# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits],
  eth/common,
  ../web3_eth_conv,
  ../beacon_engine,
  ../execution_types,
  ./api_utils,
  chronicles

{.push gcsafe, raises:[CatchableError].}

proc getPayload*(ben: BeaconEngineRef, id: PayloadID): GetPayloadV2Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var payload: ExecutionPayloadV1OrV2
  var blockValue: UInt256
  if not ben.get(id, blockValue, payload):
    raise unknownPayload("Unknown payload")

  GetPayloadV2Response(
    executionPayload: payload,
    blockValue: blockValue
  )

proc getPayloadV3*(ben: BeaconEngineRef, id: PayloadID): GetPayloadV3Response =
  trace "Engine API request received",
    meth = "GetPayload", id

  var payload: ExecutionPayloadV3
  var blockValue: UInt256
  if not ben.get(id, blockValue, payload):
    raise unknownPayload("Unknown payload")

  let com = ben.com
  if not com.isCancunOrLater(ethTime payload.timestamp):
    raise unsupportedFork("payload timestamp is less than Cancun activation")

  var
    blobsBundle: BlobsBundleV1

  try:
    for ttx in payload.transactions:
      let tx = rlp.decode(distinctBase(ttx), Transaction)
      if tx.networkPayload.isNil.not:
        for blob in tx.networkPayload.blobs:
          blobsBundle.blobs.add Web3Blob(blob)
        for p in tx.networkPayload.proofs:
          blobsBundle.proofs.add Web3KZGProof(p)
        for k in tx.networkPayload.commitments:
          blobsBundle.commitments.add Web3KZGCommitment(k)
  except RlpError:
    doAssert(false, "found TypedTransaction that RLP failed to decode")

  GetPayloadV3Response(
    executionPayload: payload,
    blockValue: blockValue,
    blobsBundle: blobsBundle,
    shouldOverrideBuilder: false
  )
