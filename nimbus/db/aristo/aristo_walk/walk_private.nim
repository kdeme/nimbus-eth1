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
  std/[algorithm, sequtils, tables],
  results,
  ".."/[aristo_desc, aristo_get, aristo_init, aristo_utils]

# ------------------------------------------------------------------------------
# Public generic iterators
# ------------------------------------------------------------------------------

iterator walkVtxBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[n: int, vid: VertexID, vtx: VertexRef] =
  ## Generic iterator
  var n = 0

  when T is VoidBackendRef:
    let filter = if db.roFilter.isNil: FilterRef() else: db.roFilter

  else:
    mixin walkVtx

    let filter = FilterRef()
    if not db.roFilter.isNil:
      filter.sTab = db.roFilter.sTab # copy table

    for (_,vid,vtx) in db.backend.T.walkVtx:
      if filter.sTab.hasKey vid:
        let fVtx = filter.sTab.getOrVoid vid
        if fVtx.isValid:
          yield (n,vid,fVtx)
          n.inc
        filter.sTab.del vid
      else:
        yield (n,vid,vtx)
        n.inc

  for vid in filter.sTab.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let vtx = filter.sTab.getOrVoid vid
    if vtx.isValid:
      yield (n,vid,vtx)
      n.inc


iterator walkKeyBeImpl*[T](
    db: AristoDbRef;                   # Database with optional backend filter
      ): tuple[n: int, vid: VertexID, key: HashKey] =
  ## Generic iterator
  var n = 0

  when T is VoidBackendRef:
    let filter = if db.roFilter.isNil: FilterRef() else: db.roFilter

  else:
    mixin walkKey

    let filter = FilterRef()
    if not db.roFilter.isNil:
      filter.kMap = db.roFilter.kMap # copy table

    for (_,vid,key) in db.backend.T.walkKey:
      if filter.kMap.hasKey vid:
        let fKey = filter.kMap.getOrVoid vid
        if fKey.isValid:
          yield (n,vid,fKey)
          n.inc
        filter.kMap.del vid
      else:
        yield (n,vid,key)
        n.inc

  for vid in filter.kMap.keys.toSeq.mapIt(it.uint64).sorted.mapIt(it.VertexID):
    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      yield (n,vid,key)
      n.inc


iterator walkFilBeImpl*[T](
    be: T;                             # Backend descriptor
      ): tuple[n: int, qid: QueueID, filter: FilterRef] =
  ## Generic filter iterator
  when T isnot VoidBackendRef:
    mixin walkFil

    for (n,qid,filter) in be.walkFil:
      yield (n,qid,filter)


iterator walkFifoBeImpl*[T](
    be: T;                             # Backend descriptor
      ): tuple[qid: QueueID, fid: FilterRef] =
  ## Generic filter iterator walking slots in fifo order. This iterator does
  ## not depend on the backend type but may be type restricted nevertheless.
  when T isnot VoidBackendRef:
    proc kvp(chn: int, qid: QueueID): (QueueID,FilterRef) =
      let cid = QueueID((chn.uint64 shl 62) or qid.uint64)
      (cid, be.getFilFn(cid).get(otherwise = FilterRef(nil)))

    if not be.isNil:
      let scd = be.filters
      if not scd.isNil:
        for i in 0 ..< scd.state.len:
          let (left, right) = scd.state[i]
          if left == 0:
            discard
          elif left <= right:
            for j in right.countDown left:
              yield kvp(i, j)
          else:
            for j in right.countDown QueueID(1):
              yield kvp(i, j)
            for j in scd.ctx.q[i].wrap.countDown left:
              yield kvp(i, j)


iterator walkPairsImpl*[T](
   db: AristoDbRef;                   # Database with top layer & backend filter
     ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` in the database. Note that entries
  ## are unsorted.
  for (vid,vtx) in db.top.sTab.pairs:
    if vtx.isValid:
      yield (vid,vtx)
  for (_,vid,vtx) in walkVtxBeImpl[T](db):
    if vid notin db.top.sTab and vtx.isValid:
      yield (vid,vtx)

iterator replicateImpl*[T](
   db: AristoDbRef;                   # Database with top layer & backend filter
     ): tuple[vid: VertexID, key: HashKey, vtx: VertexRef, node: NodeRef] =
  ## Variant of `walkPairsImpl()` for legacy applications.
  for (vid,vtx) in walkPairsImpl[T](db):
    let node = block:
      let rc = vtx.toNode(db)
      if rc.isOk:
        rc.value
      else:
        NodeRef(nil)
    yield (vid, db.getKey vid, vtx, node)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
