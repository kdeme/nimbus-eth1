# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[hashes, os, sequtils],
  eth/common,
  rocksdb,
  ../../nimbus/db/aristo/[
    aristo_constants, aristo_debug, aristo_desc,
    aristo_filter/filter_scheduler, aristo_merge],
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/sync/protocol/snap/snap_types,
  ../test_sync_snap/test_types,
  ../replay/[pp, undump_accounts, undump_storages]

from ../../nimbus/sync/snap/range_desc
  import NodeKey

type
  ProofTrieData* = object
    root*: HashKey
    id*: int
    proof*: seq[SnapProof]
    kvpLst*: seq[LeafTiePayload]

const
  QidSlotLyo* = [(4,0,10),(3,3,10),(3,4,10),(3,5,10)]
  QidSample* = (3 * QidSlotLyo.stats.minCovered) div 2

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toPfx(indent: int): string =
  "\n" & " ".repeat(indent)

proc to(a: NodeKey; T: type HashKey): T =
  a.T

# ------------------------------------------------------------------------------
# Public pretty printing
# ------------------------------------------------------------------------------

proc pp*(
    w: ProofTrieData;
    rootID: VertexID;
    db: AristoDbRef;
    indent = 4;
      ): string =
  let pfx = indent.toPfx
  result = "(" & HashLabel(root: rootID, key: w.root).pp(db)
  result &= "," & $w.id & ",[" & $w.proof.len & "],"
  result &= pfx & " ["
  for n,kvp in w.kvpLst:
    if 0 < n:
      result &= "," & pfx & "  "
    result &= "(" & kvp.leafTie.pp(db) & "," & $kvp.payload.pType & ")"
  result &= "])"

proc pp*(w: ProofTrieData; indent = 4): string =
  var db = AristoDbRef()
  w.pp(VertexID(1), db, indent)

proc pp*(
    w: openArray[ProofTrieData];
    rootID: VertexID;
    db: AristoDbRef;
    indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(rootID, db, indent + 1)).join("," & pfx & " ") & "]"

proc pp*(w: openArray[ProofTrieData]; indent = 4): string =
  let pfx = indent.toPfx
  "[" & w.mapIt(it.pp(indent + 1)).join("," & pfx & " ") & "]"

proc pp*(ltp: LeafTiePayload; db: AristoDbRef): string =
  "(" & ltp.leafTie.pp(db) & "," & ltp.payload.pp(db) & ")"

# ----------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc `==`*[T: AristoError|VertexID](a: T, b: int): bool =
  a == T(b)

proc `==`*(a: (VertexID,AristoError), b: (int,int)): bool =
  (a[0].int,a[1].int) == b

proc `==`*(a: (VertexID,AristoError), b: (int,AristoError)): bool =
  (a[0].int,a[1]) == b

proc `==`*(a: (int,AristoError), b: (int,int)): bool =
  (a[0],a[1].int) == b

proc `==`*(a: (int,VertexID,AristoError), b: (int,int,int)): bool =
  (a[0], a[1].int, a[2].int) == b

proc `==`*(a: (QueueID,Hash), b: (int,Hash)): bool =
  (a[0].int,a[1]) == b

proc to*(sample: AccountsSample; T: type seq[UndumpAccounts]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextAccount:
    let n = w.seenAccounts - 1
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to*(sample: AccountsSample; T: type seq[UndumpStorages]): T =
  ## Convert test data into usable in-memory format
  let file = sample.file.findFilePath.value
  var root: Hash256
  for w in file.undumpNextStorages:
    let n = w.seenAccounts - 1 # storages selector based on accounts
    if n < sample.firstItem:
      continue
    if sample.lastItem < n:
      break
    if sample.firstItem == n:
      root = w.root
    elif w.root != root:
      break
    result.add w

proc to*(ua: seq[UndumpAccounts]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (VOID_HASH_KEY, VertexID(0))
  for w in ua:
    let thisRoot = w.root.to(HashKey)
    if rootKey != thisRoot:
      (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
    if 0 < w.data.accounts.len:
      result.add ProofTrieData(
        root:   rootKey,
        proof:  w.data.proof,
        kvpLst: w.data.accounts.mapIt(LeafTiePayload(
          leafTie: LeafTie(
            root:  rootVid,
            path:  it.accKey.to(HashKey).to(HashID)),
          payload: PayloadRef(pType: RawData, rawBlob: it.accBlob))))

proc to*(us: seq[UndumpStorages]; T: type seq[ProofTrieData]): T =
  var (rootKey, rootVid) = (VOID_HASH_KEY, VertexID(0))
  for n,s in us:
    for w in s.data.storages:
      let thisRoot = w.account.storageRoot.to(HashKey)
      if rootKey != thisRoot:
        (rootKey, rootVid) = (thisRoot, VertexID(rootVid.uint64 + 1))
      if 0 < w.data.len:
        result.add ProofTrieData(
          root:   thisRoot,
          id:     n + 1,
          kvpLst: w.data.mapIt(LeafTiePayload(
            leafTie: LeafTie(
              root:  rootVid,
              path:  it.slotHash.to(HashKey).to(HashID)),
            payload: PayloadRef(pType: RawData, rawBlob: it.slotData))))
    if 0 < result.len:
      result[^1].proof = s.data.proof

proc mapRootVid*(
    a: openArray[LeafTiePayload];
    toVid: VertexID;
      ): seq[LeafTiePayload] =
  a.mapIt(LeafTiePayload(
    leafTie: LeafTie(root: toVid, path: it.leafTie.path),
    payload: it.payload))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
