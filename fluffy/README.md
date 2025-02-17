# Fluffy: The Nimbus Portal Network Client

[![Fluffy CI](https://github.com/status-im/nimbus-eth1/actions/workflows/fluffy.yml/badge.svg)](https://github.com/status-im/nimbus-eth1/actions/workflows/fluffy.yml)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)
[![License: Apache](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/Discord-Nimbus-blue.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/Status-nimbus--general-blue.svg)](https://join.status.im/nimbus-general)

## Introduction
This folder holds the development of the Nimbus client implementation supporting
the Portal Network: Fluffy. The Portal Network is a project still heavily in
research phase and fully in flux. This client is thus still highly experimental.

Current status of specifications can be found in the
[portal-network-specs repository](https://github.com/ethereum/portal-network-specs/blob/master/portal-network.md).


## Development Updates

Monthly development updates are shared
[here](https://hackmd.io/jRpxY4WBQJ-hnsKaPDYqTw).

To keep up to date with changes and development progress, follow the
[Nimbus blog](https://our.status.im/tag/nimbus/).

## How to Build & Run

### Prerequisites
- GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.

### Build the Fluffy client
```bash
git clone git@github.com:status-im/nimbus-eth1.git
cd nimbus-eth1
make fluffy

# See available command line options
./build/fluffy --help

# Example command: Run the client and connect to a bootstrap node.
./build/fluffy --bootstrap-node:enr:<base64 encoding of ENR>
```

### Update and rebuild the Fluffy client
```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
make update

make fluffy
```

### Run a Fluffy client on the public testnet

```bash
# Connect to the Portal testnet bootstrap nodes and enable the JSON-RPC APIs
./build/fluffy --rpc --table-ip-limit:1024 --bucket-ip-limit:24
```

The `table-ip-limit` and `bucket-ip-limit` options are needed to allow more
nodes with the same IPs in the routing tables. The default limits are there
as security measure. It is currently needed to increase the limits for the testnet
because the fleet of Fluffy nodes runs on only 2 machines / network interfaces.

There is a public [Portal testnet](https://github.com/ethereum/portal-network-specs/blob/master/testnet.md#portal-network-testnet)
which contains nodes of different clients.

Fluffy will default join the network through these bootstrap nodes.
You can also explicitly provide the `--network:testnet0` option to join this
network, or `--network:none` to not connect to any of these bootstrapn odes.

> **_Note:_** The `--network` option selects automatically a static set of
specific bootstrap nodes belonging to a "testnet". Currently `testnet0` is the
only option, which results in connecting to the
[testnet bootstrap nodes](https://github.com/ethereum/portal-network-specs/blob/master/testnet.md#bootnodes).
It should be noted that there is currently no real way to distinguish a "specific" Portal
network, and as long as the same Portal protocols are supported, nodes can
simply connect to it and no real separation can be made.
When testing locally the `--network:none` option can be provided to avoid
connecting to any of the testnet bootstrap nodes.

<!-- TODO: Update this once we have the headersWithProof type merged and data on the network -->

The Portal testnet is slowly being filled up with historical data through bridge nodes.
Because of this, more recent history data is more likely to be available.. This can
be tested by using the JSON-RPC call `eth_getBlockByHash`:
```
# Get the hash of a block from your favorite block explorer, e.g.:
BLOCKHASH=0x34eea44911b19f9aa8c72f69bdcbda3ed933b11a940511b6f3f58a87427231fb # Replace this to the block hash of your choice
# Run this command to get this block:
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"eth_getBlockByHash","params":["'${BLOCKHASH}'", true]}' http://localhost:8545 | jq
```

One can also use the `blockwalk` tool to walk down the blocks one by one, e.g:
```bash
make blockwalk

BLOCKHASH=0x34eea44911b19f9aa8c72f69bdcbda3ed933b11a940511b6f3f58a87427231fb # Replace this to the block hash of your choice
./build/blockwalk --block-hash:${BLOCKHASH}
```

### Run Fluffy test suite
```bash
# From the nimbus-eth1 repository
make fluffy-test
```

### Run Fluffy local testnet script
```bash
./fluffy/scripts/launch_local_testnet.sh
```

Find more details on the usage and workings of the local testnet script
[here](./docs/local_testnet.md).

### Windows support

Follow the steps outlined [here](../README.md#windows) to build fluffy on Windows.


## Development tools and documentation

The fluffy directory also holds several tools to help development of the Portal
networks.

Command to build the tools:

```bash
make fluffy-tools -j6
```

Additional documention on the tools or on what you can use them for:

- [eth_data_exporter](./docs/eth_data_exporter.md): tool to extract content from
EL or CL and prepare it as Portal content and content keys.
- [Content seeding](./docs/content_seeding.md): Documentation on how to retrieve & generate history data and how to seed it into the network
- [Manual protocol interop testing](./docs/protocol_interop.md): commands on how to manually test the discv5 and Portal protocol request and responses
- [Local testnet script](./docs/local_testnet.md): Documentation on the local testnet script and how to use it


## The basics for developers

When working on this repository, you can run the `env.sh` script to run a
command with the right environment variables set. This means the vendored
Nim and Nim modules will be used, just as when you use `make`.

E.g.:

```bash
# start a new interactive shell with the right env vars set
./env.sh bash
```

More [development tips](../README.md#devel-tips)
can be found on the general nimbus-eth1 readme.

The code follows the
[Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).


## Build local dev container for portal-hive

To develop code against portal-hive tests you will need:

1) Clone and build portal-hive ([#1](https://github.com/ethereum/portal-hive))

2) Modify `Dockerfile` for fluffy in `portal-hive/clients/fluffy/Dockerfile` ([#2](https://github.com/ethereum/portal-hive/blob/main/docs/overview.md#running-a-client-built-from-source))

3) Build local dev container using following command: ```docker build --tag fluffy-dev --file ./fluffy/tools/docker/Dockerfile.portalhive .``` You may need to change fluffy-dev to the tag you using in portal-hive client dockerfile.

4) Run the tests

Also keep in mind that `./vendors` is dockerignored and cached. If you have to make local changes to one of the dependencies in that directory you'll have to remove `vendors/` from `./fluffy/tools/docker/Dockerfile.portalhive.dockerignore`.


## Metrics and their visualisation

To enable metrics run Fluffy with the `--metrics` flag:
```bash
./build/fluffy --metrics
```
Default the metrics are available at http://127.0.0.1:8008/metrics.

The address can be changed with the `--metrics-address` and `--metrics-port` options.

This provides only a snapshot of the current metrics. In order track the metrics over
time and to also visualise them one can use for example Prometheus and Grafana.

The steps on how to set up such system is explained in [this guide](https://nimbus.guide/metrics-pretty-pictures.html#prometheus-and-grafana).

A Fluffy specific dashboard can be found [here](./grafana/fluffy_grafana_dashboard.json).

This is the dashboard used for our Fluffy testnet fleet.
In order to use it locally, you will have to remove the
`{job="nimbus-fluffy-metrics"}` part from the `instance` and `container`
variables queries in the dashboard settings. Or they can also be changed to a
constant value.

The other option would be to remove those variables and remove their usage in
each panel query.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](../LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](../LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
