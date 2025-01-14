# Bridging content into the Portal beacon network

## Seeding from content bridges

Run a Fluffy node with the JSON-RPC API enabled.

```bash
./build/fluffy --rpc
```

Build & run the `beacon_chain_bridge`:
```bash
make beacon_chain_bridge

TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.
# --rest-url = access to beacon node API, default http://127.0.0.1:5052
./build/beacon_chain_bridge --trusted-block-root:${TRUSTED_BLOCK_ROOT} --rest-url:http://127.0.0.1:5052
```

The `beacon_chain_bridge` will connect to Fluffy node over the JSON-RPC
interface and start gossiping an `LightClientBootstrap` for
given trusted block root and gossip backfill `LightClientUpdate`s.

Next, it will gossip a new `LightClientOptimisticUpdate`,
`LightClientFinalityUpdate` and `LightClientUpdate` as they become available.
