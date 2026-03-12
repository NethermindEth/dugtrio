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

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", http.NoBody)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.NoError(t, err)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"winner":"fast"`)
	// Background pool health-check goroutines may also hit the server, so
	// assert at least one call rather than exactly one.
	assert.GreaterOrEqual(t, fastHits.Load(), int32(1))
	assert.GreaterOrEqual(t, slowHits.Load(), int32(1))
	assert.NotContains(t, w.Body.String(), `"winner":"slow"`)
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

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", http.NoBody)
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

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", http.NoBody)
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

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", http.NoBody)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, clients)
	require.NoError(t, err)

	assert.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"single":"true"`)
}

func TestRaceProxyCall_NoEndpoints(t *testing.T) {
	proxy := newTestProxy(t)
	session := newTestSession()

	req := httptest.NewRequest(http.MethodGet, "/eth/v1/beacon/blobs/12345", http.NoBody)
	w := httptest.NewRecorder()

	err := proxy.processRaceProxyCall(w, req, session, []*pool.Client{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no endpoints available")
}
