// Package location is the Location module (location design 2026-11-15, proto/dzeroth/location/v1): the caller's CHOSEN
// area, a named neighbourhood or city from the curated catalogue embedded in the binary (areas/areas.json), and the
// consent behind it. Place-based: no coordinates or device readings exist anywhere in this module, and no user's area is
// returned to anyone but that user.
//
// It owns users/{uid}/locationArea/current, users/{uid}/locationConsents/{snowflake}, the catalogue and
// dzeroth.location.v1.LocationService. Both collections are erased by the `location` account-deletion step (purge.go) and
// exported in the `location` section (export.go), registered in apiserver/lifecycle_location.go whether or not
// FEATURE_LOCATION is on. Other modules reach it through the interfaces in this file only (beacons, P2: Catalog for plan
// areas and Reader for "my area"); location imports no other module.
package location

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name of FEATURE_LOCATION, the `feature` metadata of FEATURE_DISABLED and the string in
// GetMe.enabled_features.
const FlagName = "location"

// Kind is an area's level in the catalogue.
type Kind string

const (
	// KindArea is a neighbourhood inside a city.
	KindArea Kind = "AREA"
	// KindCity is a whole city.
	KindCity Kind = "CITY"
)

// Area is one catalogue entry. IDs are permanent: never renamed, reused or deleted; a withdrawn area is Retired (still
// resolves its label, cannot be picked or set).
type Area struct {
	ID       string
	Name     string
	Kind     Kind
	CityID   string
	CityName string
	// Aliases are extra search terms (other spellings, old names); search runs on the device.
	Aliases []string
	// Neighbours are curated neighbouring AREA ids (at most 8, symmetric; empty for a CITY).
	Neighbours []string
	Retired    bool
}

// Catalog is the in-memory area catalogue: no I/O.
type Catalog interface {
	// Lookup resolves an id, retired areas included.
	Lookup(id string) (Area, bool)
	// Pickable reports whether id exists and is not retired.
	Pickable(id string) bool
	// Version is the catalogue version (areas.json "version").
	Version() int64
}

// Reader is the seam other modules use for the caller's stored area (beacons ListNearbyBeacons, P2).
type Reader interface {
	// MyArea returns uid's stored area id; ok is false when none is set. 1 read.
	MyArea(ctx context.Context, uid string) (areaID string, ok bool, err error)
}

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the on-for-the-caller gate (SetArea; in P2 also setting a plan area and ListNearbyBeacons): before any
// Firestore access. Disabled is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=location. A nil checker is
// off for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid)
}

// GuardNotOff is the not-globally-off gate (ListAreas; in P2 removing a plan area and the Beacon.area label). Same error
// shape as Guard. A nil checker is off for everyone.
func GuardNotOff(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(_, name string) bool { return fc != nil && !fc.GloballyOff(name) }, uid)
}

// guard runs flags.Guard for FlagName and stamps the request line and the error metadata with the feature.
func guard(ctx context.Context, enabled func(uid, name string) bool, uid string) error {
	err := flags.Guard(ctx, enabled, uid, FlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", FlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", FlagName)
	}
	return err
}
