# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Portal bridge to inject beacon chain content into the network
# The bridge act as a middle man between a consensus full node, through the,
# Eth Beacon Node API REST-API), and a Portal node, through the Portal
# JSON-RPC API.
#
# Portal Network <-> Portal Client (e.g. fluffy) <--JSON-RPC--> bridge <--REST--> consensus client (e.g. Nimbus-eth2)
#
# The Consensus client must support serving the Beacon LC data.
#
# Bootstraps and updates can be backfilled, however how to do this for multiple
# bootstraps is still unsolved.
#
# Updates, optimistic updates and finality updates are injected as they become
# available.
#

{.push raises: [].}

import
  std/os,
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  json_rpc/clients/httpclient,
  chronos,
  stew/byteutils,
  eth/async_utils,
  beacon_chain/spec/eth2_apis/rest_beacon_client,
  ../../network/beacon/beacon_content,
  ../../rpc/portal_rpc_client,
  ../../logging,
  ../eth_data_exporter/cl_data_exporter,
  ./beacon_chain_bridge_conf

const
  restRequestsTimeout = 30.seconds

# TODO: From nimbus_binary_common, but we don't want to import that.
proc sleepAsync(t: TimeDiff): Future[void] =
  sleepAsync(nanoseconds(
    if t.nanoseconds < 0: 0'i64 else: t.nanoseconds))

proc gossipLCBootstrapUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    trustedBlockRoot: Eth2Digest,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[void, string]] {.async.} =
  var bootstrap =
    try:
      info "Downloading LC bootstrap"
      awaitWithTimeout(
        restClient.getLightClientBootstrap(
          trustedBlockRoot,
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC bootstrap timed out")
    except CatchableError as exc:
      return err("Unable to download LC bootstrap: " & exc.msg)

  withForkyObject(bootstrap):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.header.beacon.slot
        contentKey = encode(bootstrapContentKey(trustedBlockRoot))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(slot), cfg)
        content = encodeBootstrapForked(
          forkDigest,
          bootstrap
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC bootstrap gossiped", peers,
            contentKey = contentKeyHex
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok()
      else:
        return err(res.error)

    else:
      return err("No LC bootstraps pre Altair")

proc gossipLCUpdates*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    startPeriod: uint64, count: uint64,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[void, string]] {.async.} =
  var updates =
    try:
      info "Downloading LC updates", count
      awaitWithTimeout(
        restClient.getLightClientUpdatesByRange(
          SyncCommitteePeriod(startPeriod), count, cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC updates timed out")
    except CatchableError as exc:
      return err("Unable to download LC updates: " & exc.msg)

  if updates.len() > 0:
    withForkyObject(updates[0]):
      when lcDataFork > LightClientDataFork.None:
        let
          slot = forkyObject.attested_header.beacon.slot
          period = forkyObject.attested_header.beacon.slot.sync_committee_period
          contentKey = encode(updateContentKey(period.uint64, count))
          forkDigest = forkDigestAtEpoch(
            forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)

          content = encodeLightClientUpdatesForked(
            forkDigest,
            updates
          )

        proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
          try:
            let
              contentKeyHex = contentKey.asSeq().toHex()
              peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
            info "Beacon LC update gossiped", peers,
              contentKey = contentKeyHex, period, count
            return ok()
          except CatchableError as e:
            return err("JSON-RPC error: " & $e.msg)

        let res = await GossipRpcAndClose()
        if res.isOk():
          return ok()
        else:
          return err(res.error)
      else:
        return err("No LC updates pre Altair")
  else:
    # TODO:
    # currently only error if no updates at all found. This might be due
    # to selecting future period or too old period.
    # Might want to error here in case count != updates.len or might not want to
    # error at all and perhaps return the updates.len.
    return err("No updates downloaded")

proc gossipLCFinalityUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[Slot, string]] {.async.} =
  var update =
    try:
      info "Downloading LC finality update"
      awaitWithTimeout(
        restClient.getLightClientFinalityUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC finality update timed out")
    except CatchableError as exc:
      return err("Unable to download LC finality update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        finalizedSlot = forkyObject.finalized_header.beacon.slot
        contentKey = encode(finalityUpdateContentKey(finalizedSlot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeFinalityUpdateForked(
          forkDigest,
          update
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC finality update gossiped", peers,
            contentKey = contentKeyHex, finalizedSlot
          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok(finalizedSlot)
      else:
        return err(res.error)

    else:
      return err("No LC updates pre Altair")

proc gossipLCOptimisticUpdate*(
    restClient: RestClientRef, portalRpcClient: RpcHttpClient,
    cfg: RuntimeConfig, forkDigests: ref ForkDigests):
    Future[Result[Slot, string]] {.async.} =
  var update =
    try:
      info "Downloading LC optimistic update"
      awaitWithTimeout(
        restClient.getLightClientOptimisticUpdate(
          cfg, forkDigests),
        restRequestsTimeout
      ):
        return err("Attempt to download LC optimistic update timed out")
    except CatchableError as exc:
      return err("Unable to download LC optimistic update: " & exc.msg)

  withForkyObject(update):
    when lcDataFork > LightClientDataFork.None:
      let
        slot = forkyObject.signature_slot
        contentKey = encode(optimisticUpdateContentKey(slot.uint64))
        forkDigest = forkDigestAtEpoch(
          forkDigests[], epoch(forkyObject.attested_header.beacon.slot), cfg)
        content = encodeOptimisticUpdateForked(
          forkDigest,
          update
        )

      proc GossipRpcAndClose(): Future[Result[void, string]] {.async.} =
        try:
          let
            contentKeyHex = contentKey.asSeq().toHex()
            peers = await portalRpcClient.portal_beaconRandomGossip(
                contentKeyHex,
                content.toHex())
          info "Beacon LC optimistic update gossiped", peers,
            contentKey = contentKeyHex, slot

          return ok()
        except CatchableError as e:
          return err("JSON-RPC error: " & $e.msg)

      let res = await GossipRpcAndClose()
      if res.isOk():
        return ok(slot)
      else:
        return err(res.error)

    else:
      return err("No LC updates pre Altair")

proc run(config: BeaconBridgeConf) {.raises: [CatchableError].} =
  setupLogging(config.logLevel, config.logStdout)

  notice "Launching Fluffy beacon chain bridge",
    cmdParams = commandLineParams()

  let
    (cfg, forkDigests, beaconClock) = getBeaconData()
    getBeaconTime = beaconClock.getBeaconTimeFn()
    portalRpcClient = newRpcHttpClient()
    restClient = RestClientRef.new(config.restUrl).valueOr:
      fatal "Cannot connect to server", error = $error
      quit 1

  proc backfill(
      beaconRestClient: RestClientRef, rpcAddress: string, rpcPort: Port,
      backfillAmount: uint64, trustedBlockRoot: Option[TrustedDigest])
      {.async.} =
    # Bootstrap backfill, currently just one bootstrap selected by
    # trusted-block-root, could become a selected list, or some other way.
    if trustedBlockRoot.isSome():
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCBootstrapUpdate(
        beaconRestClient, portalRpcClient,
        trustedBlockRoot.get(),
        cfg, forkDigests)

      if res.isErr():
        warn "Error gossiping LC bootstrap", error = res.error

      await portalRpcClient.close()

    # Updates backfill, selected by backfillAmount
    # Might want to alter this to default backfill to the
    # `MIN_EPOCHS_FOR_BLOCK_REQUESTS`.
    # TODO: This can be up to 128, but our JSON-RPC requests fail with a value
    # higher than 16. TBI
    const updatesPerRequest = 16

    let
      wallSlot = getBeaconTime().slotOrZero()
      currentPeriod =
        wallSlot div (SLOTS_PER_EPOCH * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)
      requestAmount = backfillAmount div updatesPerRequest
      leftOver = backFillAmount mod updatesPerRequest

    for i in 0..<requestAmount:
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCUpdates(
        beaconRestClient, portalRpcClient,
        currentPeriod - updatesPerRequest * (i + 1) + 1, updatesPerRequest,
        cfg, forkDigests)

      if res.isErr():
        warn "Error gossiping LC updates", error = res.error

      await portalRpcClient.close()

    if leftOver > 0:
      await portalRpcClient.connect(rpcAddress, rpcPort, false)

      let res = await gossipLCUpdates(
        beaconRestClient, portalRpcClient,
        currentPeriod - updatesPerRequest * requestAmount - leftOver + 1, leftOver,
        cfg, forkDigests)

      if res.isErr():
        warn "Error gossiping LC updates", error = res.error

      await portalRpcClient.close()

  var
    lastOptimisticUpdateSlot = Slot(0)
    lastFinalityUpdateEpoch = epoch(lastOptimisticUpdateSlot)
    lastUpdatePeriod = sync_committee_period(lastOptimisticUpdateSlot)

  proc onSlotGossip(wallTime: BeaconTime, lastSlot: Slot) {.async.} =
    let
      wallSlot = wallTime.slotOrZero()
      wallEpoch = epoch(wallSlot)
      wallPeriod = sync_committee_period(wallSlot)

    notice "Slot start info",
      slot = wallSlot,
      epoch = wallEpoch,
      period = wallPeriod,
      lastOptimisticUpdateSlot,
      lastFinalityUpdateEpoch,
      lastUpdatePeriod,
      slotsTillNextEpoch =
        SLOTS_PER_EPOCH - (wallSlot mod SLOTS_PER_EPOCH),
      slotsTillNextPeriod =
        SLOTS_PER_SYNC_COMMITTEE_PERIOD -
          (wallSlot mod SLOTS_PER_SYNC_COMMITTEE_PERIOD)

    if wallSlot > lastOptimisticUpdateSlot + 1:
      # TODO: If this turns out to be too tricky to not gossip old updates,
      # then an alternative could be to verify in the gossip calls if the actual
      # slot number received is the correct one, before gossiping into Portal.
      # And/or look into possibly using eth/v1/events for
      # light_client_finality_update and light_client_optimistic_update if that
      # is something that works.

      # Or basically `lightClientOptimisticUpdateSlotOffset`
      await sleepAsync((SECONDS_PER_SLOT div INTERVALS_PER_SLOT).int.seconds)

      await portalRpcClient.connect(
        config.rpcAddress, Port(config.rpcPort), false)

      let res = await gossipLCOptimisticUpdate(
        restClient, portalRpcClient,
        cfg, forkDigests)

      if res.isErr():
        warn "Error gossiping LC optimistic update", error = res.error
      else:
        if wallEpoch > lastFinalityUpdateEpoch + 2 and
            wallSlot > start_slot(wallEpoch):
          let res = await gossipLCFinalityUpdate(
            restClient, portalRpcClient,
            cfg, forkDigests)

          if res.isErr():
            warn "Error gossiping LC finality update", error = res.error
          else:
            lastFinalityUpdateEpoch = epoch(res.get())

        if wallPeriod > lastUpdatePeriod and
            wallSlot > start_slot(wallEpoch):
          # TODO: Need to delay timing here also with one slot?
          let res = await gossipLCUpdates(
            restClient, portalRpcClient,
            sync_committee_period(wallSlot).uint64, 1,
            cfg, forkDigests)

          if res.isErr():
            warn "Error gossiping LC update", error = res.error
          else:
            lastUpdatePeriod = wallPeriod

        lastOptimisticUpdateSlot = res.get()

  proc runOnSlotLoop() {.async.} =
    var
      curSlot = getBeaconTime().slotOrZero()
      nextSlot = curSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()
    while true:
      await sleepAsync(timeToNextSlot)

      let
        wallTime = getBeaconTime()
        wallSlot = wallTime.slotOrZero()

      await onSlotGossip(wallTime, curSlot)

      curSlot = wallSlot
      nextSlot = wallSlot + 1
      timeToNextSlot = nextSlot.start_beacon_time() - getBeaconTime()

  waitFor backfill(
    restClient, config.rpcAddress, config.rpcPort,
    config.backfillAmount, config.trustedBlockRoot)

  asyncSpawn runOnSlotLoop()

  while true:
    poll()

when isMainModule:
  {.pop.}
  let config = BeaconBridgeConf.load()
  {.push raises: [].}

  case config.cmd
  of BeaconBridgeCmd.noCommand:
    run(config)
