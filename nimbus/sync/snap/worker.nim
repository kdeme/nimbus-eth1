# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[options, sets, strutils],
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  ../../common as nimcom,
  ../../db/select_backend,
  ../../utils/prettify,
  ".."/[handlers, protocol, sync_desc],
  ./worker/[pivot, ticker],
  ./worker/com/com_error,
  ./worker/db/[hexary_desc, snapdb_desc, snapdb_pivot],
  "."/[range_desc, update_beacon_header, worker_desc]

{.push raises: [].}

logScope:
  topics = "snap-buddy"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc recoveryStepContinue(ctx: SnapCtxRef): Future[bool] {.async.} =
  let recov = ctx.pool.recovery
  if recov.isNil:
    return false

  let
    checkpoint =
      "#" & $recov.state.header.blockNumber & "(" & $recov.level & ")"
    topLevel = recov.level == 0
    env = block:
      let rc = ctx.pool.pivotTable.eq recov.state.header.stateRoot
      if rc.isErr:
        error "Recovery pivot context gone", checkpoint, topLevel
        return false
      rc.value

  # Cosmetics: allow other processes (e.g. ticker) to log the current recovery
  # state. There is no other intended purpose of this wait state.
  await sleepAsync 1100.milliseconds

  #when extraTraceMessages:
  #  trace "Recovery continued ...", checkpoint, topLevel,
  #    nAccounts=recov.state.nAccounts, nDangling=recov.state.dangling.len

  # Update pivot data from recovery checkpoint
  env.recoverPivotFromCheckpoint(ctx, topLevel)

  # Fetch next recovery record if there is any
  if recov.state.predecessor.isZero:
    #when extraTraceMessages:
    #  trace "Recovery done", checkpoint, topLevel
    return false
  let rc = ctx.pool.snapDb.recoverPivot(recov.state.predecessor)
  if rc.isErr:
    when extraTraceMessages:
      trace "Recovery stopped at pivot stale checkpoint", checkpoint, topLevel
    return false

  # Set up next level pivot checkpoint
  ctx.pool.recovery = SnapRecoveryRef(
    state: rc.value,
    level: recov.level + 1)

  # Push onto pivot table and continue recovery (i.e. do not stop it yet)
  ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)

  return true # continue recovery

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.pool.coveredAccounts = NodeTagRangeSet.init()
  noExceptionOops("worker.setup()"):
    ctx.ethWireCtx.txPoolEnabled = false
    ctx.chain.com.syncReqNewHead = ctx.pivotUpdateBeaconHeaderCB
  ctx.pool.snapDb =
    if ctx.pool.dbBackend.isNil: SnapDbRef.init(ctx.chain.db.db)
    else: SnapDbRef.init(ctx.pool.dbBackend)
  if tickerOK:
    ctx.pool.ticker = TickerRef.init(ctx.pool.pivotTable.tickerStats(ctx))
  else:
    trace "Ticker is disabled"

  # Check for recovery mode
  if not ctx.pool.noRecovery:
    let rc = ctx.pool.snapDb.recoverPivot()
    if rc.isOk:
      ctx.pool.recovery = SnapRecoveryRef(state: rc.value)
      ctx.daemon = true

      # Set up early initial pivot
      ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)
      trace "Recovery started",
        checkpoint=("#" & $ctx.pool.pivotTable.topNumber() & "(0)")
      if not ctx.pool.ticker.isNil:
        ctx.pool.ticker.startRecovery()

  if ctx.exCtrlFile.isSome:
    warn "Snap sync accepts pivot block number or hash",
      syncCtrlFile=ctx.exCtrlFile.get
  true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stop()
    ctx.pool.ticker = nil
  noExceptionOops("worker.release()"):
    ctx.ethWireCtx.txPoolEnabled = true
  ctx.chain.com.syncReqNewHead = nil

proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.only.errors = ComErrorStatsRef()
    if not ctx.pool.ticker.isNil:
      ctx.pool.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let ctx = buddy.ctx
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Enabled while `ctx.daemon` is `true`
  ##
  if not ctx.pool.recovery.isNil:
    if not await ctx.recoveryStepContinue():
      # Done, stop recovery
      ctx.pool.recovery = nil
      ctx.daemon = false

      # Update logging
      if not ctx.pool.ticker.isNil:
        ctx.pool.ticker.stopRecovery()


proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctrl.multiOk` is `false`
  ## * `buddy.ctrl.poolMode` is `false`
  ##
  let ctx = buddy.ctx

  # External beacon header updater
  await buddy.updateBeaconHeaderFromFile()

  await buddy.pivotApprovePeer()
  buddy.ctrl.multiOk = true


proc runPool*(buddy: SnapBuddyRef, last: bool): bool =
  ## Enabled when `buddy.ctrl.poolMode` is `true`
  ##
  let ctx = buddy.ctx
  ctx.poolMode = false
  result = true

  # Clean up empty pivot slots (never the top one)
  var rc = ctx.pool.pivotTable.beforeLast
  while rc.isOK:
    let (key, env) = (rc.value.key, rc.value.data)
    if env.fetchAccounts.processed.isEmpty:
      ctx.pool.pivotTable.del key
    rc = ctx.pool.pivotTable.prev(key)


proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Enabled while
  ## * `buddy.ctx.multiOk` is `true`
  ## * `buddy.ctx.poolMode` is `false`
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Set up current state root environment for accounts snapshot
  let
    env = block:
      let rc = ctx.pool.pivotTable.lastValue
      if rc.isErr:
        return # nothing to do
      rc.value
    pivot = "#" & $env.stateHeader.blockNumber # for logging
    nStorQuAtStart = env.fetchStorageFull.len +
                     env.fetchStoragePart.len +
                     env.parkedStorage.len

  buddy.only.pivotEnv = env

  # Full sync processsing based on current snapshot
  # -----------------------------------------------

  # Check whether this pivot is fully downloaded
  if env.fetchAccounts.processed.isFull and nStorQuAtStart == 0:
    trace "Snap full sync -- not implemented yet", peer, pivot
    await sleepAsync(5.seconds)
    # flip over to single mode for getting new instructins
    buddy.ctrl.multiOk = false
    return

  # Snapshot sync processing
  # ------------------------

  # If this is a new pivot, the previous one can be cleaned up. There is no
  # point in keeping some older space consuming state data any longer.
  ctx.pool.pivotTable.beforeTopMostlyClean()

  when extraTraceMessages:
    block:
      let
        nAccounts {.used.} = env.nAccounts
        nSlotLists {.used.} = env.nSlotLists
        processed {.used.} = env.fetchAccounts.processed.fullFactor.toPC(2)
      trace "Multi sync runner", peer, pivot, nAccounts, nSlotLists, processed,
        nStoQu=nStorQuAtStart

  # This one is the syncing work horse which downloads the database
  await env.execSnapSyncAction(buddy)

  # Various logging entries (after accounts and storage slots download)
  let
    nAccounts = env.nAccounts
    nSlotLists = env.nSlotLists
    processed = env.fetchAccounts.processed.fullFactor.toPC(2)
    nStoQuLater = env.fetchStorageFull.len + env.fetchStoragePart.len

  if env.archived:
    # Archive pivot if it became stale
    when extraTraceMessages:
      trace "Mothballing", peer, pivot, nAccounts, nSlotLists
    env.pivotMothball()

  else:
    # Save state so sync can be partially resumed at next start up
    let rc = env.saveCheckpoint(ctx)
    if rc.isErr:
      error "Failed to save recovery checkpoint", peer, pivot, nAccounts,
       nSlotLists, processed, nStoQu=nStoQuLater, error=rc.error
    else:
      when extraTraceMessages:
        trace "Saved recovery checkpoint", peer, pivot, nAccounts, nSlotLists,
          processed, nStoQu=nStoQuLater, blobSize=rc.value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
