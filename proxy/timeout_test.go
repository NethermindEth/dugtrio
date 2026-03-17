package proxy

import (
	"testing"
	"time"

	"github.com/ethpandaops/dugtrio/types"
	"github.com/stretchr/testify/assert"
)

func TestEffectiveTimeout_UsesGlobalWhenEndpointNotSet(t *testing.T) {
	ep := &types.EndpointConfig{Timeout: 0}
	result := effectiveTimeout(10*time.Second, ep)
	assert.Equal(t, 10*time.Second, result)
}

func TestEffectiveTimeout_UsesEndpointWhenSet(t *testing.T) {
	ep := &types.EndpointConfig{Timeout: 2 * time.Second}
	result := effectiveTimeout(10*time.Second, ep)
	assert.Equal(t, 2*time.Second, result)
}

func TestEffectiveTimeout_EndpointOverridesGlobal(t *testing.T) {
	ep := &types.EndpointConfig{Timeout: 500 * time.Millisecond}
	result := effectiveTimeout(30*time.Second, ep)
	assert.Equal(t, 500*time.Millisecond, result)
}
