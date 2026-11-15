// export.go is the right-to-access path: the `location` export section is the user's chosen area (resolved through the
// catalogue) and the full consent log in id order. Never flag-gated.
package location

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// exportPage is the consent page of the export (memory stays bounded).
const exportPage = 100

// ExportedArea is the section's area: null when none is set.
type ExportedArea struct {
	AreaID   string    `json:"areaId"`
	Name     string    `json:"name"`
	CityName string    `json:"cityName"`
	SetAt    time.Time `json:"setAt"`
}

// ExportedConsent is one consent record.
type ExportedConsent struct {
	ID             string    `json:"id"`
	Purpose        string    `json:"purpose"`
	Action         string    `json:"action"`
	CopyVersion    int       `json:"copyVersion"`
	AdultConfirmed bool      `json:"adultConfirmed"`
	At             time.Time `json:"at"`
}

// ExportSource reads a user's location data (FirestoreRepo in production).
type ExportSource interface {
	// Area reads the area doc; nil when none is set.
	Area(ctx context.Context, uid string) (*StoredArea, error)
	// ExportConsentsPage returns uid's consent records after the id `after` ("" = from the start), in id order, at most limit.
	ExportConsentsPage(ctx context.Context, uid, after string, limit int) ([]ConsentRecord, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// ExportConsentsPage implements ExportSource.
func (r *FirestoreRepo) ExportConsentsPage(ctx context.Context, uid, after string, limit int) ([]ConsentRecord, error) {
	q := r.consents(uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.consents(uid).Doc(after))
	}
	docs, err := q.Limit(min(max(limit, 1), exportPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("location: export %s: query: %w", logger.HashUID(uid), err), uid)
	}
	out := make([]ConsentRecord, 0, len(docs))
	for _, s := range docs {
		var d consentDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("location: export decode: %w", err), uid)
		}
		out = append(out, *d.record(s.Ref.ID))
	}
	return out, nil
}

// Exporter writes the `location` section.
type Exporter struct {
	src     ExportSource
	catalog Catalog
}

// NewExporter builds the section writer; the catalogue resolves the area's name and city.
func NewExporter(src ExportSource, catalog Catalog) *Exporter {
	return &Exporter{src: src, catalog: catalog}
}

// ExportUser streams {"area": {...} | null, "consents": [...]} and a newline to w.
func (e *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	a, err := e.src.Area(ctx, uid)
	if err != nil {
		return err
	}
	var area *ExportedArea
	if a != nil {
		area = &ExportedArea{AreaID: a.AreaID, SetAt: a.UpdatedAt.UTC()}
		if e.catalog != nil {
			if c, ok := e.catalog.Lookup(a.AreaID); ok {
				area.Name, area.CityName = c.Name, c.CityName
			}
		}
	}
	head, err := json.Marshal(area)
	if err != nil {
		return fmt.Errorf("location: export area: %w", err)
	}
	if _, err := fmt.Fprintf(w, `{"area":%s,"consents":[`, head); err != nil {
		return fmt.Errorf("location: export write: %w", err)
	}
	after, first := "", true
	for {
		page, err := e.src.ExportConsentsPage(ctx, uid, after, exportPage)
		if err != nil {
			return err
		}
		for _, c := range page {
			row, err := json.Marshal(ExportedConsent{
				ID: c.ID, Purpose: c.Purpose, Action: c.Action, CopyVersion: c.CopyVersion, AdultConfirmed: c.AdultConfirmed, At: c.At.UTC(),
			})
			if err != nil {
				return fmt.Errorf("location: export consent: %w", err)
			}
			sep := ","
			if first {
				sep, first = "", false
			}
			if _, err := io.WriteString(w, sep+string(row)); err != nil {
				return fmt.Errorf("location: export write: %w", err)
			}
		}
		if len(page) < exportPage {
			break
		}
		after = page[len(page)-1].ID
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("location: export write: %w", err)
	}
	return nil
}
