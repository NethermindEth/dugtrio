# Race Scheduler Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `racePaths` config to Dugtrio that fans out matching requests to all ready endpoints simultaneously and returns the first 2xx response.

**Architecture:** Per-path regex config mirrors existing `blockedPaths` pattern. Matching requests call `processRaceProxyCall` which fans out to all ready endpoints via goroutines sharing a `raceCtx`. First 2xx winner is streamed using a fresh `callCtx` derived from `r.Context()` (not `raceCtx`). Losing goroutines are cancelled via `raceCtx`. Non-matching paths use the existing round-robin flow unchanged.

**Tech Stack:** Go 1.25, `net/http`, `sync`, `context`, `httptest` for tests, `testify/assert` + `testify/require`

---

## Task 1: Add testify dependency

**Files:**
- Modify: `go.mod`, `go.sum`

**Step 1: Add testify**

```bash
go get github.com/stretchr/testify@latest
```

Expected: `go.mod` and `go.sum` updated with testify.

**Step 2: Verify build**

```bash
go build ./...
```

Expected: PASS.

**Step 3: Commit**

```bash
git add go.mod go.sum
git commit -m "chore(dugtrio): add testify dependency"
```

---

## Task 2: Add `GetReadyEndpoints` to pool

**Files:**
- Modify: `pool/beaconpool.go`
- Create: `pool/beaconpool_test.go`

**Step 1: Write the failing test**

Create `pool/beaconpool_test.go`:

```go
package pool

import (
	"testing"

	"github.com/ethpandaops/dugtrio/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestPool(t *testing.T) *BeaconPool {
	t.Helper()
	p, err := NewBeaconPool(&types.PoolConfig{
		FollowDistance:  10,
		MaxHeadDistance: 100,
		SchedulerMode:   "rr",
	})
	require.NoError(t, err)
	return p
}

func TestGetReadyEndpoints_NilWhenNoClients(t *testing.T) {
	p := newTestPool(t)
	assert.Nil(t, p.GetReadyEndpoints(UnspecifiedClient, 0))
}

func TestGetReadyEndpoints_NilWhenNoCanonicalFork(t *testing.T) {
	p := newTestPool(t)
	_, err := p.AddEndpoint(&types.EndpointConfig{Name: "ep1", URL: "http://localhost:5052/"})
	require.NoError(t, err)

	// canonical fork is nil until health monitoring runs
	assert.Nil(t, p.GetReadyEndpoints(UnspecifiedClient, 0))
}
```

**Step 2: Run test to verify it fails**

```bash
go test ./pool/... -run TestGetReadyEndpoints -v
```

Expected: FAIL — `GetReadyEndpoints` undefined.

**Step 3: Add `GetReadyEndpoints` to `pool/beaconpool.go`**

Add after `GetReadyEndpoint` (after line 99):

```go
func (pool *BeaconPool) GetReadyEndpoints(clientType ClientType, minCgc uint16) []*Client {
	canonicalFork := pool.GetCanonicalFork()
	if canonicalFork == nil {
		return nil
	}

	readyClients := canonicalFork.ReadyClients
	if len(readyClients) == 0 {
		return nil
	}

	if clientType == UnspecifiedClient && minCgc == 0 {
		result := make([]*Client, len(readyClients))
		copy(result, readyClients)
		return result
	}

	result := make([]*Client, 0, len(readyClients))
	for _, client := range readyClients {
		if clientType != UnspecifiedClient && client.clientType != clientType {
			continue
		}
		if minCgc > 0 && client.GetCustodyGroupCount() < minCgc {
			continue
		}
		result = append(result, client)
	}

	return result
}
```

**Step 4: Run test to verify it passes**

```bash
go test ./pool/... -run TestGetReadyEndpoints -v
```

Expected: PASS.

**Step 5: Commit**

```bash
git add pool/beaconpool.go pool/beaconpool_test.go
git commit -m "chore(dugtrio): add GetReadyEndpoints to BeaconPool"
```

---

## Task 3: Add `RacePaths` config fields

**Files:**
- Modify: `types/config.go`

**Step 1: Add fields to `ProxyConfig`**

In `types/config.go`, add after the `BlockedPaths` fields (after line 56):

```go
RacePathsStr string   `envconfig:"PROXY_RACE_PATHS"`
RacePaths    []string `yaml:"racePaths"`
```

**Step 2: Verify build**

```bash
go build ./...
```

Expected: PASS.

**Step 3: Commit**

```bash
git add types/config.go
git commit -m "chore(dugtrio): add RacePaths config fields to ProxyConfig"
```

---

## Task 4: Refactor `proxycall.go` — extract helpers

Extract two private helpers from `processProxyCall`:
- `doUpstreamRequest(ctx context.Context, r, body, endpoint)` — builds and executes the HTTP request. Takes `context.Context` directly so it can be used by both single-call and race-call paths without shared state.
- `writeProxyResponse(w, r, session, resp, endpoint, callCtx)` — writes response headers and streams body.

**Critical design note:** `doUpstreamRequest` takes `context.Context`, NOT `*proxyCallContext`. This avoids shared-state bugs in the race path where multiple goroutines would otherwise share a single `callCtx.cancelled` flag and `streamReader` field.

**Files:**
- Modify: `proxy/proxycall.go`

**Step 1: Replace `proxy/proxycall.go` with the refactored version**

```go
package proxy

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/ethpandaops/dugtrio/pool"
	"github.com/ethpandaops/dugtrio/utils"
)

type proxyCallContext struct {
	context      context.Context
	cancelFn     context.CancelFunc
	cancelled    bool
	deadline     time.Time
	updateChan   chan time.Duration
	streamReader io.ReadCloser
}

func (proxy *BeaconProxy) newProxyCallContext(parent context.Context, timeout time.Duration) *proxyCallContext {
	callCtx := &proxyCallContext{
		deadline:   time.Now().Add(timeout),
		updateChan: make(chan time.Duration, 5),
	}
	callCtx.context, callCtx.cancelFn = context.WithCancel(parent)

	go callCtx.processCallContext()

	return callCtx
}

func (callContext *proxyCallContext) processCallContext() {
ctxLoop:
	for {
		timeout := time.Until(callContext.deadline)
		select {
		case newTimeout := <-callContext.updateChan:
			callContext.deadline = time.Now().Add(newTimeout)
		case <-callContext.context.Done():
			break ctxLoop
		case <-time.After(timeout):
			callContext.cancelFn()
			callContext.cancelled = true

			time.Sleep(10 * time.Millisecond)
		}
	}

	callContext.cancelled = true

	if callContext.streamReader != nil {
		callContext.streamReader.Close()
	}
}

func (proxy *BeaconProxy) processProxyCall(w http.ResponseWriter, r *http.Request, session *Session, endpoint *pool.Client) error {
	callCtx := proxy.newProxyCallContext(r.Context(), proxy.config.CallTimeout)
	contextID := session.addActiveContext(callCtx.cancelFn)

	defer func() {
		callCtx.cancelFn()
		session.removeActiveContext(contextID)
	}()

	var body []byte

	if r.Body != nil {
		var err error

		body, err = io.ReadAll(r.Body)
		if err != nil {
			return fmt.Errorf("failed to read request body: %w", err)
		}
	}

	resp, err := proxy.doUpstreamRequest(callCtx.context, r, body, endpoint)
	if err != nil {
		return err
	}

	_, err = proxy.writeProxyResponse(w, r, session, resp, endpoint, callCtx)

	return err
}

// doUpstreamRequest builds and dispatches an HTTP request to endpoint.
// Takes context.Context directly so it works for both single-call and fan-out race paths.
func (proxy *BeaconProxy) doUpstreamRequest(ctx context.Context, r *http.Request, body []byte, endpoint *pool.Client) (*http.Response, error) {
	endpointConfig := endpoint.GetEndpointConfig()

	hh := http.Header{}

	for _, hk := range passthruRequestHeaderKeys {
		if hv, ok := r.Header[hk]; ok {
			hh[hk] = hv
		}
	}

	for hk, hv := range endpointConfig.Headers {
		hh.Add(hk, hv)
	}

	proxyIPChain := []string{}
	if forwardedFor := r.Header.Get("X-Forwarded-For"); forwardedFor != "" {
		proxyIPChain = strings.Split(forwardedFor, ", ")
	}

	proxyIPChain = append(proxyIPChain, r.RemoteAddr)
	hh.Set("X-Forwarded-For", strings.Join(proxyIPChain, ", "))

	queryArgs := ""
	if r.URL.RawQuery != "" {
		queryArgs = fmt.Sprintf("?%s", r.URL.RawQuery)
	}

	proxyURL, err := url.Parse(fmt.Sprintf("%s%s%s", endpointConfig.URL, r.URL.EscapedPath(), queryArgs))
	if err != nil {
		return nil, fmt.Errorf("error parsing proxy url: %w", err)
	}

	var bodyReader io.ReadCloser
	if len(body) > 0 {
		bodyReader = io.NopCloser(bytes.NewReader(body))
	}

	req := &http.Request{
		Method:        r.Method,
		URL:           proxyURL,
		Header:        hh,
		Body:          bodyReader,
		ContentLength: int64(len(body)),
		Close:         r.Close,
	}
	req = req.WithContext(ctx)

	start := time.Now()

	client := &http.Client{Timeout: 0}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("proxy request error: %w", err)
	}

	if proxy.proxyMetrics != nil {
		proxy.proxyMetrics.AddCall(endpoint.GetName(), fmt.Sprintf("%s%s", r.Method, r.URL.EscapedPath()), time.Since(start), resp.StatusCode)
	}

	return resp, nil
}

// writeProxyResponse writes upstream response headers and streams the body to w.
func (proxy *BeaconProxy) writeProxyResponse(w http.ResponseWriter, r *http.Request, session *Session, resp *http.Response, endpoint *pool.Client, callCtx *proxyCallContext) (int64, error) {
	callCtx.streamReader = resp.Body

	respContentType := resp.Header.Get("Content-Type")
	isEventStream := respContentType == "text/event-stream" || strings.HasPrefix(r.URL.EscapedPath(), "/eth/v1/events")

	respH := w.Header()

	for _, hk := range passthruResponseHeaderKeys {
		if hv, ok := resp.Header[hk]; ok {
			respH[hk] = hv
		}
	}

	respH.Set("X-Dugtrio-Version", fmt.Sprintf("dugtrio/%v", utils.GetVersion()))
	respH.Set("X-Dugtrio-Session-Ip", session.GetIPAddr())
	respH.Set("X-Dugtrio-Session-Tokens", fmt.Sprintf("%.2f", session.getCallLimitTokens()))
	respH.Set("X-Dugtrio-Endpoint-Name", endpoint.GetName())
	respH.Set("X-Dugtrio-Endpoint-Type", endpoint.GetClientType().String())
	respH.Set("X-Dugtrio-Endpoint-Version", endpoint.GetVersion())

	if isEventStream {
		respH.Set("X-Accel-Buffering", "no")
	}

	w.WriteHeader(resp.StatusCode)

	var respLen int64

	if isEventStream {
		callCtx.updateChan <- proxy.config.CallTimeout

		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}

		rspLen, err := proxy.processEventStreamResponse(callCtx, w, resp.Body, session)
		if err != nil {
			proxy.logger.Warnf("proxy event stream error: %v", err)
		}

		respLen = rspLen
	} else {
		rspLen, err := io.Copy(w, resp.Body)
		if err != nil {
			return respLen, fmt.Errorf("proxy response stream error: %w", err)
		}

		respLen = rspLen
	}

	proxy.logger.Debugf("proxied %v %v call (ip: %v, status: %v, length: %v, endpoint: %v)",
		r.Method, r.URL.EscapedPath(), session.GetIPAddr(), resp.StatusCode, respLen, endpoint.GetName())

	return respLen, nil
}

func (proxy *BeaconProxy) processEventStreamResponse(callContext *proxyCallContext, w http.ResponseWriter, r io.ReadCloser, session *Session) (int64, error) {
	rd := bufio.NewReader(r)
	written := int64(0)

	for {
		for {
			evt, err := rd.ReadSlice('\n')
			if err != nil {
				return written, err
			}

			wb, err := w.Write(evt)
			if err != nil {
				return written, err
			}

			written += int64(wb)

			if wb == 1 {
				break
			}
		}

		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}

		if callContext.cancelled {
			return written, nil
		}

		session.updateLastSeen()

		callContext.updateChan <- proxy.config.CallTimeout
	}
}
```

**Step 2: Verify build**

```bash
go build ./...
```

Expected: PASS.

**Step 3: Commit**

```bash
git add proxy/proxycall.go
git commit -m "chore(dugtrio): extract doUpstreamRequest and writeProxyResponse helpers"
```

---

## Task 5: Implement `processRaceProxyCall` with tests

**Files:**
- Create: `proxy/racecall_test.go`
- Create: `proxy/racecall.go`

**Step 1: Write the failing tests**

Create `proxy/racecall_test.go`:

```go
package proxy

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethpandaops/dugtrio/pool"
	"github.com/ethpandaops/dugtrio/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestSession creates a minimal session suitable for unit tests.
// Calls session.init() to initialise the activeContexts map.
func newTestSession() *Session {
	s := &Session{
		ipAddr:    "127.0.0.1",
		firstSeen: time.Now(),
		lastSeen:  time.Now(),
	}
	s.init()

	return s
}

// newTestClients creates pool clients pointing at the given httptest servers.
// The clients start background health loops that will fail against test servers
// (not real beacon nodes) — that is expected and harmless for these tests.
func newTestClients(t *testing.T, servers []*httptest.Server) []*pool.Client {
	t.Helper()

	p, err := pool.NewBeaconPool(&types.PoolConfig{
		FollowDistance:  10,
		MaxHeadDistance: 100,
		SchedulerMode:   "rr",
	})
	require.NoError(t, err)

	clients := make([]*pool.Client, 0, len(servers))

	for i, srv := range servers {
		c, err := p.AddEndpoint(&types.EndpointConfig{
			Name: fmt.Sprintf("ep%d", i),
			URL:  srv.URL + "/",
		})
		require.NoError(t, err)

		clients = append(clients, c)
	}

	return clients
}

// newTestProxy creates a BeaconProxy with no endpoints configured.
func newTestProxy(t *testing.T) *BeaconProxy {
	t.Helper()

	p, err := pool.NewBeaconPool(&types.PoolConfig{
		FollowDistance:  10,
		MaxHeadDistance: 100,
		SchedulerMode:   "rr",
	})
	require.NoError(t, err)

	proxy, err := NewBeaconProxy(
		&types.ProxyConfig{CallTimeout: 5 * time.Second},
		p,
		nil,
	)
	require.NoError(t, err)

	return proxy
}

func TestRaceProxyCall_FastestWins(t *testing.T) {
	var slowHits, fastHits atomic.Int32

	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		slowHits.Add(1)
		time.Sleep(300 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"winner":"slow"}`)
	}))
	defer slow.Close()

	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fastHits.Add(1)
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"winner":"fast"}`)
	}))
	defer fast.Close()

	proxy := newTestProxy(t)
	clients := newTestClients(t, []*httptest.Server{slow, fast})
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", nil)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.NoError(t, err)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"winner":"fast"`)
	assert.Equal(t, int32(1), fastHits.Load())
}

func TestRaceProxyCall_AllFail(t *testing.T) {
	ep0 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer ep0.Close()

	ep1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer ep1.Close()

	proxy := newTestProxy(t)
	clients := newTestClients(t, []*httptest.Server{ep0, ep1})
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", nil)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "all race endpoints failed")
}

func TestRaceProxyCall_OneFailsOneSucceeds(t *testing.T) {
	ep0 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer ep0.Close()

	ep1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"data":"ok"}`)
	}))
	defer ep1.Close()

	proxy := newTestProxy(t)
	clients := newTestClients(t, []*httptest.Server{ep0, ep1})
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", nil)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.NoError(t, err)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"data":"ok"`)
}

func TestRaceProxyCall_SingleEndpointFallthrough(t *testing.T) {
	ep0 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"single":"true"}`)
	}))
	defer ep0.Close()

	proxy := newTestProxy(t)
	clients := newTestClients(t, []*httptest.Server{ep0})
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", nil)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.NoError(t, err)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"single":"true"`)
}

func TestRaceProxyCall_NoEndpoints(t *testing.T) {
	proxy := newTestProxy(t)
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", nil)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, []*pool.Client{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no endpoints available")
}
```

**Step 2: Run tests to verify they fail**

```bash
go test ./proxy/... -run TestRaceProxyCall -v
```

Expected: FAIL — `processRaceProxyCall` undefined.

**Step 3: Create `proxy/racecall.go`**

```go
package proxy

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync"

	"github.com/ethpandaops/dugtrio/pool"
)

// processRaceProxyCall fans out r to all endpoints simultaneously and streams
// the first 2xx response back to w. Losing requests are cancelled via raceCtx.
// The winner is streamed using a fresh callCtx derived from r.Context() so that
// cancelling raceCtx does not interrupt the response stream.
func (proxy *BeaconProxy) processRaceProxyCall(w http.ResponseWriter, r *http.Request, session *Session, endpoints []*pool.Client) error {
	if len(endpoints) == 0 {
		return fmt.Errorf("no endpoints available")
	}

	if len(endpoints) == 1 {
		return proxy.processProxyCall(w, r, session, endpoints[0])
	}

	// Read body once; safe for GET (body is nil/empty).
	var body []byte

	if r.Body != nil {
		var err error

		body, err = io.ReadAll(r.Body)
		if err != nil {
			return fmt.Errorf("failed to read request body: %w", err)
		}
	}

	// raceCtx is cancelled once a winner is found, stopping losing requests.
	raceCtx, raceCancel := context.WithCancel(r.Context())
	defer raceCancel()

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

			resp, err := proxy.doUpstreamRequest(raceCtx, r, body, ep)
			if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
				if resp != nil {
					resp.Body.Close()
				}

				return
			}

			select {
			case resultCh <- raceResult{resp, ep}:
			default:
				// Another goroutine already won.
				resp.Body.Close()
			}
		}(ep)
	}

	// Close resultCh after all goroutines finish so the receive below unblocks.
	go func() {
		wg.Wait()
		close(resultCh)
	}()

	winner, ok := <-resultCh
	if !ok {
		return fmt.Errorf("all race endpoints failed for %s", r.URL.Path)
	}

	// Cancel remaining in-flight requests.
	raceCancel()

	// Stream the winner using a fresh callCtx derived from r.Context() —
	// NOT from raceCtx, which is already cancelled.
	callCtx := proxy.newProxyCallContext(r.Context(), proxy.config.CallTimeout)
	contextID := session.addActiveContext(callCtx.cancelFn)

	defer func() {
		callCtx.cancelFn()
		session.removeActiveContext(contextID)
	}()

	_, err := proxy.writeProxyResponse(w, r, session, winner.resp, winner.endpoint, callCtx)

	return err
}
```

**Step 4: Run tests to verify they pass**

```bash
go test ./proxy/... -run TestRaceProxyCall -v
```

Expected: PASS all 5 tests.

**Step 5: Commit**

```bash
git add proxy/racecall.go proxy/racecall_test.go
git commit -m "chore(dugtrio): implement processRaceProxyCall with fan-out first-wins logic"
```

---

## Task 6: Wire `racePaths` into `BeaconProxy`

**Files:**
- Modify: `proxy/beaconproxy.go`

**Step 1: Add `racePaths` field to `BeaconProxy` struct**

Add after `blockedPaths`:

```go
type BeaconProxy struct {
	config       *types.ProxyConfig
	pool         *pool.BeaconPool
	proxyMetrics *metrics.ProxyMetrics
	logger       *logrus.Entry
	blockedPaths []*regexp.Regexp
	racePaths    []*regexp.Regexp

	sessionMutex sync.Mutex
	sessions     map[string]*Session
}
```

**Step 2: Parse `racePaths` in `NewBeaconProxy`**

Add after the existing `blockedPaths` parsing loop:

```go
racePaths := []string{}
racePaths = append(racePaths, config.RacePaths...)

for _, racePath := range strings.Split(config.RacePathsStr, ",") {
	racePath = strings.Trim(racePath, " ")
	if racePath == "" {
		continue
	}

	racePaths = append(racePaths, racePath)
}

for _, racePath := range racePaths {
	racePathPattern, err := regexp.Compile(racePath)
	if err != nil {
		proxy.logger.Errorf("error parsing race path pattern '%v': %v", racePath, err)
		continue
	}

	proxy.racePaths = append(proxy.racePaths, racePathPattern)
}
```

**Step 3: Add `checkRacePaths` helper**

Add after `checkBlockedPaths`:

```go
func (proxy *BeaconProxy) checkRacePaths(reqURL *url.URL) bool {
	for _, pattern := range proxy.racePaths {
		if pattern.MatchString(reqURL.EscapedPath()) {
			return true
		}
	}

	return false
}
```

**Step 4: Route race requests in `processCall`**

In `processCall`, after the rate-limit check and before `getEndpointForCall`, insert:

```go
if proxy.checkRacePaths(r.URL) {
	if endpoints := proxy.pool.GetReadyEndpoints(clientType, 0); len(endpoints) > 0 {
		session.requests.Add(1)

		err := proxy.processRaceProxyCall(w, r, session, endpoints)
		if err != nil {
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(http.StatusInternalServerError)

			proxy.logger.WithFields(logrus.Fields{
				"method": r.Method,
				"url":    utils.GetRedactedURL(r.URL.String()),
			}).Warnf("race proxy error: %v", err)

			_, err = w.Write([]byte("Internal Server Error"))
			if err != nil {
				proxy.logger.Warnf("error writing race error response: %v", err)
			}
		}

		return
	}
	// No ready endpoints in pool — fall through to normal routing.
}
```

**Step 5: Verify full build and tests**

```bash
go build ./... && go test ./...
```

Expected: PASS.

**Step 6: Commit**

```bash
git add proxy/beaconproxy.go
git commit -m "chore(dugtrio): wire racePaths config into BeaconProxy request routing"
```

---

## Task 7: Update example config and final validation

**Files:**
- Modify: `dugtrio-config.example.yaml`

**Step 1: Add `racePaths` to the `proxy` section**

Locate the `proxy:` block and add `racePaths` alongside `blockedPaths`:

```yaml
proxy:
  callTimeout: 60s
  sessionTimeout: 10m
  stickyEndpoint: true
  racePaths:
    - "^/eth/v1/beacon/blobs/.*"
  # blockedPaths:
  #   - "^/eth/v[0-9]+/debug/.*"
```

**Step 2: Full build and test**

```bash
go build ./... && go test ./...
```

Expected: PASS, all tests green.

**Step 3: Commit**

```bash
git add dugtrio-config.example.yaml
git commit -m "chore(dugtrio): add racePaths example to config"
```

---

## Deployment note

Point Catalyst `L1_BEACON_URL` to the Dugtrio proxy. Example Dugtrio config for Hoodi:

```yaml
endpoints:
  - name: lighthouse-local
    url: http://l1-stack-hoodi-execution-beacon-svc:5052/
  - name: quicknode
    url: https://hoodi-beacon.quicknode.pro/<key>/
  - name: drpc
    url: https://lb.drpc.org/eth-beacon-chain-hoodi/<key>/

proxy:
  callTimeout: 10s
  racePaths:
    - "^/eth/v1/beacon/blobs/.*"
```
