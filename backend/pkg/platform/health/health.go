// Package health exposes the Cloud Run startup/liveness probe target. It must have zero dependencies —
// it answers even if Firestore, Auth, or any downstream is unavailable, and it is never logged
// (observability skill: "Health checks not logged").
package health

import "net/http"

// Handler answers 200 OK with no body work and no I/O.
func Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}
}
