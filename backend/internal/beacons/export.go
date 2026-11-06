// export.go is the right-to-access path: the `beacons` export section streams the user's organised beacons and their
// membership rows. Never flag-gated.
package beacons

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// exportPage is the page of the export (memory stays bounded).
const exportPage = 100

// ExportedBeacon is one row of the beacons part: a beacon the user organised. Participants belong to themselves and are
// not exported.
type ExportedBeacon struct {
	BeaconID      string    `json:"beaconId"`
	CommunityID   string    `json:"communityId"`
	Activity      string    `json:"activity"`
	Title         string    `json:"title"`
	Details       string    `json:"details"`
	Venue         string    `json:"venue"`
	StartAt       time.Time `json:"startAt"`
	EndAt         time.Time `json:"endAt"`
	DurationMin   int       `json:"durationMinutes"`
	OpenSpots     int       `json:"openSpots"`
	AcceptedCount int       `json:"acceptedCount"`
	Cost          string    `json:"cost"`
	ChatPref      string    `json:"chatPreference"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"createdAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

// ExportedMembership is one row of the memberships part: the user's relationship with a beacon (no other user's uid).
type ExportedMembership struct {
	BeaconID    string    `json:"beaconId"`
	Role        string    `json:"role"`
	State       string    `json:"state"`
	CommunityID string    `json:"communityId"`
	StartAt     time.Time `json:"startAt"`
	EndAt       time.Time `json:"endAt"`
}

// ExportSource pages through a user's data (FirestoreRepo in production).
type ExportSource interface {
	// ExportBeaconsPage returns uid's organised beacons after the id `after` ("" = from the start), in id order, at most limit.
	ExportBeaconsPage(ctx context.Context, uid, after string, limit int) ([]ExportedBeacon, error)
	// ExportMembershipsPage returns uid's membership rows after the beacon id `after`, in id order, at most limit.
	ExportMembershipsPage(ctx context.Context, uid, after string, limit int) ([]ExportedMembership, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// ExportBeaconsPage implements ExportSource: organiserId == uid ordered by the document id, with a Limit.
func (r *FirestoreRepo) ExportBeaconsPage(ctx context.Context, uid, after string, limit int) ([]ExportedBeacon, error) {
	q := r.col().Where("organiserId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(min(max(limit, 1), exportPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: export %s: query: %w", logger.HashUID(uid), err), uid, after)
	}
	out := make([]ExportedBeacon, 0, len(docs))
	for _, s := range docs {
		var d beaconDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: export decode: %w", err), uid, s.Ref.ID)
		}
		out = append(out, ExportedBeacon{
			BeaconID: s.Ref.ID, CommunityID: d.CommunityID, Activity: d.Activity, Title: d.Title, Details: d.Details, Venue: d.Venue,
			StartAt: d.StartAt.UTC(), EndAt: d.EndAt.UTC(), DurationMin: d.DurationMin, OpenSpots: d.OpenSpots, AcceptedCount: d.AcceptedCount,
			Cost: d.Cost, ChatPref: d.ChatPref, Status: d.Status, CreatedAt: d.CreatedAt.UTC(), UpdatedAt: d.UpdatedAt.UTC(),
		})
	}
	return out, nil
}

// ExportMembershipsPage implements ExportSource: users/{uid}/beaconMemberships ordered by the document id (the beacon id).
func (r *FirestoreRepo) ExportMembershipsPage(ctx context.Context, uid, after string, limit int) ([]ExportedMembership, error) {
	q := r.client.Collection(usersCollection).Doc(uid).Collection(membershipsSubcollection).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.membershipRef(uid, after))
	}
	docs, err := q.Limit(min(max(limit, 1), exportPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: export memberships %s: query: %w", logger.HashUID(uid), err), uid, after)
	}
	out := make([]ExportedMembership, 0, len(docs))
	for _, s := range docs {
		var m membershipDoc
		if err := s.DataTo(&m); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: export memberships decode: %w", err), uid, s.Ref.ID)
		}
		out = append(out, ExportedMembership{
			BeaconID: s.Ref.ID, Role: m.Role, State: m.State, CommunityID: m.CommunityID, StartAt: m.StartAt.UTC(), EndAt: m.EndAt.UTC(),
		})
	}
	return out, nil
}

// Exporter writes the `beacons` export section.
type Exporter struct {
	src ExportSource
}

// NewExporter builds the section on an ExportSource (FirestoreRepo in production).
func NewExporter(src ExportSource) *Exporter { return &Exporter{src: src} }

// ExportUser streams {"beacons":[...],"memberships":[...]} to w, each part in id order, in pages of exportPage.
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"beacons":[`); err != nil {
		return fmt.Errorf("beacons: write export: %w", err)
	}
	if err := streamPages(w, func(after string) ([]ExportedBeacon, string, error) {
		page, err := x.src.ExportBeaconsPage(ctx, uid, after, exportPage)
		last := ""
		if len(page) > 0 {
			last = page[len(page)-1].BeaconID
		}
		return page, last, err
	}); err != nil {
		return err
	}
	if _, err := io.WriteString(w, `],"memberships":[`); err != nil {
		return fmt.Errorf("beacons: write export: %w", err)
	}
	if err := streamPages(w, func(after string) ([]ExportedMembership, string, error) {
		page, err := x.src.ExportMembershipsPage(ctx, uid, after, exportPage)
		last := ""
		if len(page) > 0 {
			last = page[len(page)-1].BeaconID
		}
		return page, last, err
	}); err != nil {
		return err
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("beacons: write export: %w", err)
	}
	return nil
}

// streamPages writes the comma-separated JSON rows of every page next returns, until a short page.
func streamPages[T any](w io.Writer, next func(after string) ([]T, string, error)) error {
	enc := json.NewEncoder(w)
	first, after := true, ""
	for {
		page, last, err := next(after)
		if err != nil {
			return err
		}
		for _, row := range page {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("beacons: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(row); err != nil {
				return fmt.Errorf("beacons: write export: %w", err)
			}
		}
		if len(page) < exportPage {
			return nil
		}
		after = last
	}
}
