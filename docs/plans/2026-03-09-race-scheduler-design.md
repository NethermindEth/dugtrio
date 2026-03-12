# Race Scheduler for Beacon Proxy

## Goal

Add a `racePaths` configuration option to Dugtrio that fans out matching requests to all ready endpoints simultaneously and returns the first successful (2xx) response to the client. Non-matching paths continue to use the existing round-robin scheduler unchanged.

## Motivation

For latency-sensitive beacon API calls (e.g. blob fetching on the critical block proposal path), sending to a single endpoint introduces unnecessary tail latency risk. Fanning out to all configured endpoints (local Lighthouse, QuickNode, DRPC) and using whichever responds first minimises p99 latency without changing the response semantics.

## Architecture

```
Incoming request
      |
      ├─ path matches racePaths? ──NO──> getEndpointForCall → processProxyCall (unchanged)
      |
      YES
      |
      └─> pool.GetReadyEndpoints(all) → N goroutines (one per endpoint)
               |            |            |
            ep[0]         ep[1]        ep[2]   (all fire simultaneously)
               \            |            /
                first 2xx wins → stream to client
                others → context.Cancel() → bodies closed
```

## Components

### 1. `types/config.go`

Add to `ProxyConfig`:

```go
RacePathsStr string   `envconfig:"PROXY_RACE_PATHS"`
RacePaths    []string `yaml:"racePaths"`
```

`RacePathsStr` accepts comma-separated regex patterns via environment variable, mirroring `BlockedPathsStr`.

### 2. `pool/beaconpool.go`

Add `GetReadyEndpoints` (plural) returning all clients from `canonicalFork.ReadyClients` filtered by `clientType` and `minCgc`. Mirrors the existing `GetReadyEndpoint` (singular).

### 3. `proxy/beaconproxy.go`

- Add `racePaths []*regexp.Regexp` field to `BeaconProxy`
- Parse `config.RacePaths` and `config.RacePathsStr` in `NewBeaconProxy`, same loop as `blockedPaths`
- Add `checkRacePaths(url) bool` helper (mirrors `checkBlockedPaths`)
- In `processCall`, after rate-limit check and before `getEndpointForCall`: if path matches race → call `processRaceProxyCall(w, r, session, clientType)`

### 4. `proxy/racecall.go` (new file)

Core fan-out logic using idiomatic Go channel coordination:

```go
func (proxy *BeaconProxy) processRaceProxyCall(
    w http.ResponseWriter, r *http.Request,
    session *Session, clientType pool.ClientType,
) error {
    endpoints := proxy.pool.GetReadyEndpoints(clientType, 0)
    if len(endpoints) == 0 {
        return fmt.Errorf("no endpoints available")
    }
    if len(endpoints) == 1 {
        return proxy.processProxyCall(w, r, session, endpoints[0])
    }

    ctx, cancel := context.WithCancel(r.Context())
    defer cancel()

    // Buffer body once for fan-out (free for GET, needed for POST)
    body, err := io.ReadAll(r.Body)
    if err != nil {
        return fmt.Errorf("failed to read request body: %w", err)
    }

    type raceResult struct {
        resp     *http.Response
        endpoint *pool.Client
    }
    resultCh := make(chan raceResult, 1)
    var wg sync.WaitGroup

    for _, ep := range endpoints {
        wg.Add(1)
        go func(ep *pool.Client) {
            defer wg.Done()
            resp, err := proxy.doUpstreamRequest(ctx, r, body, ep)
            if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
                if resp != nil {
                    resp.Body.Close()
                }
                return
            }
            select {
            case resultCh <- raceResult{resp, ep}:
            default:
                resp.Body.Close()
            }
        }(ep)
    }

    go func() { wg.Wait(); close(resultCh) }()

    winner, ok := <-resultCh
    if !ok {
        return fmt.Errorf("all race endpoints failed for %s", r.URL.Path)
    }
    cancel()
    return proxy.writeProxyResponse(w, r, session, winner.resp, winner.endpoint)
}
```

`doUpstreamRequest` extracts the HTTP request construction and dispatch from the existing `processProxyCall`. `writeProxyResponse` extracts the header passthrough + body streaming (including SSE) from `processProxyCall`. Both are private helpers called by both `processProxyCall` and `processRaceProxyCall`.

## Configuration Example

```yaml
proxy:
  callTimeout: 60s
  racePaths:
    - "^/eth/v1/beacon/blobs/.*"
```

Via environment variable (comma-separated):

```
PROXY_RACE_PATHS=^/eth/v1/beacon/blobs/.*,^/eth/v1/beacon/genesis$
```

## Error Handling

| Scenario | Behaviour |
|---|---|
| All endpoints fail or return non-2xx | 503 `all race endpoints failed` |
| Client disconnects mid-race | parent context cancelled, all goroutines exit naturally |
| No ready endpoints | 503 `no endpoints available` |
| Single ready endpoint | falls through to `processProxyCall` directly (no overhead) |
| Winner body stream error | logged as warning, connection closed |

## Testing

`proxy/racecall_test.go` — table-driven tests using `httptest.NewServer` mocks:

- Winner is fastest endpoint (others slower)
- All endpoints fail → 503
- One endpoint returns non-2xx, others return 2xx → 2xx wins
- Client disconnects before any response → no panic, goroutines exit
- Single endpoint falls through to `processProxyCall`

Use `testify/require` for fatal assertions, `testify/assert` for property checks.

## Files Changed

| File | Change |
|---|---|
| `types/config.go` | Add `RacePaths`, `RacePathsStr` to `ProxyConfig` |
| `pool/beaconpool.go` | Add `GetReadyEndpoints` method |
| `proxy/beaconproxy.go` | Add `racePaths` field, parse config, route to race handler |
| `proxy/proxycall.go` | Extract `doUpstreamRequest` and `writeProxyResponse` helpers |
| `proxy/racecall.go` | New file: `processRaceProxyCall` |
| `proxy/racecall_test.go` | New file: table-driven tests |
| `dugtrio-config.example.yaml` | Add `racePaths` example |
