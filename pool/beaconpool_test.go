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
