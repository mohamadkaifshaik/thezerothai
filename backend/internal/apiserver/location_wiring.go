// location_wiring.go builds the location module (location design 2026-11-15): the embedded area catalogue, the Firestore
// repo, the service and the LocationService handler. The catalogue is parsed once here; a parse or validation failure fails
// Build (boot), never a request. FEATURE_LOCATION is checked by the handler per RPC class (location/server.go).
package apiserver

import (
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/location"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// locationModule is what Build needs of location: the repo and catalogue for the lifecycle, the service as the Reader
// beacons will use (P2), and the handler.
type locationModule struct {
	catalog *location.StaticCatalog
	repo    *location.FirestoreRepo
	svc     location.Service
	server  *location.Server
}

// newLocationModule wires location on the process's Firestore client, flag registry and snowflake node.
func newLocationModule(fs *firestore.Client, cfg config.Config, fc location.FlagChecker, ids location.IDGenerator) (locationModule, error) {
	catalog, err := location.DefaultCatalog()
	if err != nil {
		return locationModule{}, fmt.Errorf("location catalogue: %w", err)
	}
	repo := location.NewFirestoreRepo(fs, idempotency.New(fs))
	svc := location.New(location.Deps{
		Repo: repo, Catalog: catalog, IDs: ids, CursorKey: cfg.CursorHMACKey,
		Limits: location.Limits{MinCopyVersion: cfg.Location.ConsentMinCopyVersion, ConsentChangesPerDay: cfg.Location.ConsentChangesPerDay},
	})
	return locationModule{catalog: catalog, repo: repo, svc: svc, server: location.NewServer(fc, svc)}, nil
}
