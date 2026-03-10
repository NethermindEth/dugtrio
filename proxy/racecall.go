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
