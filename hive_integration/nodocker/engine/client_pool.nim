import
  json_rpc/rpcclient,
  ./engine_env

type
  ClientPool* = ref object
    clients: seq[EngineEnv]

proc add*(pool: ClientPool, client: EngineEnv) =
  pool.clients.add client

func first*(pool: ClientPool): EngineEnv =
  pool.clients[0]

func len*(pool: ClientPool): int =
  pool.clients.len

func `[]`*(pool: ClientPool, idx: int): EngineEnv =
  pool.clients[idx]

iterator items*(pool: ClientPool): EngineEnv =
  for x in pool.clients:
    yield x
