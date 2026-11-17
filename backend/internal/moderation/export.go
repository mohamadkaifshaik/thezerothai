// export.go is the `reports` export section: the reports the account filed (never reports about it: they would reveal
// their reporters). An ACCOUNT report's target is another person, so it is named by public id and handle, never by uid
// (owner decision, public ids; exportVersion 2: the row had "targetId" = the uid before).
package moderation

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// profileGetAllCap is the most ids one ProfileReader call takes (identity's repo GetAll bound).
const profileGetAllCap = 50

// ProfileReader resolves reported accounts for the export: identity's repo in production (users/{uid} by GetAll, at most
// 50 ids per call, EVERY account status, so a suspended account, the usual outcome of an account report, is still named;
// an erased one is absent). It is deliberately not identity.Directory, which drops non-ACTIVE accounts.
type ProfileReader interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// exportedPerson is a reported account as the export names it: public id and handle, each omitted when absent (no public
// id minted; profile erased). Never the uid.
type exportedPerson struct {
	PublicID string
	Handle   string
}

// exportedReport is one filed report in the data export (never evidence or anyone else's data). For every target type
// but ACCOUNT, TargetID is exported as stored on purpose: it is not a user id, and a MESSAGE report's
// `<conversation id>:<message id>` names the exporter's own conversation, whose id the client already holds (it is the id
// in every messaging response). The export's `messages` section leaves ids out; this one adds none the client does not
// have. An ACCOUNT target's id is the reported person's uid, so it is replaced by TargetPublicID and TargetHandle.
type exportedReport struct {
	ID             string    `json:"id"`
	TargetType     string    `json:"targetType"`
	TargetID       string    `json:"targetId,omitempty"`
	TargetPublicID string    `json:"targetPublicId,omitempty"`
	TargetHandle   string    `json:"targetHandle,omitempty"`
	Reason         string    `json:"reason"`
	Note           string    `json:"note"`
	Status         string    `json:"status"`
	CreatedAt      time.Time `json:"createdAt"`
}

// toExportedReport builds the row of report id; an ACCOUNT target missing from people (not resolved, or erased) gets
// neither field, never the uid.
func toExportedReport(id string, d reportDoc, people map[string]exportedPerson) exportedReport {
	er := exportedReport{ID: id, TargetType: d.TargetType, Reason: d.Reason, Note: d.Note, Status: d.Status, CreatedAt: d.CreatedAt.UTC()}
	if TargetType(d.TargetType) == TargetAccount {
		p := people[d.TargetID]
		er.TargetPublicID, er.TargetHandle = p.PublicID, p.Handle
		return er
	}
	er.TargetID = d.TargetID
	return er
}

// resolveAccountTargets adds to people every ACCOUNT target of docs not resolved yet, one ProfileReader call per
// profileGetAllCap ids. An erased account gets the zero row, so it is not looked up again. The public id comes from the
// same users/{uid} read as the handle, whatever public_ids says now.
func resolveAccountTargets(ctx context.Context, reader ProfileReader, docs []reportDoc, people map[string]exportedPerson) error {
	var need []string
	for _, d := range docs {
		if TargetType(d.TargetType) != TargetAccount {
			continue
		}
		if _, ok := people[d.TargetID]; !ok {
			people[d.TargetID] = exportedPerson{}
			need = append(need, d.TargetID)
		}
	}
	for i := 0; i < len(need); i += profileGetAllCap {
		got, err := reader.GetProfiles(ctx, need[i:min(i+profileGetAllCap, len(need))])
		if err != nil {
			return fmt.Errorf("moderation: export: profiles: %w", err)
		}
		for uid, p := range got {
			people[uid] = exportedPerson{PublicID: p.PublicID, Handle: p.Handle}
		}
	}
	return nil
}

// reportExporter is the Exporter over the reports collection and the ProfileReader that names reported accounts.
type reportExporter struct {
	repo   *FirestoreRepo
	people ProfileReader
}

// NewReportExporter builds the `reports` section. people is required: without it ExportUser fails rather than write a
// uid.
func NewReportExporter(repo *FirestoreRepo, people ProfileReader) Exporter {
	return reportExporter{repo: repo, people: people}
}

// ExportUser implements Exporter: {"userId": ..., "reports": [...]} in pages of opsPage. Reads: one per report filed
// (minimum 1), plus one profile read per distinct reported account (GetAll chunks of 50).
func (x reportExporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if x.people == nil {
		return fmt.Errorf("moderation: export: ProfileReader not wired")
	}
	if _, err := fmt.Fprintf(w, `{"userId":%q,"reports":[`, uid); err != nil {
		return fmt.Errorf("moderation: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	people := map[string]exportedPerson{}
	var last *firestore.DocumentSnapshot
	for {
		q := x.repo.client.Collection(reportsCollection).Where("reporterId", "==", uid).
			OrderBy(firestore.DocumentID, firestore.Asc).Limit(opsPage)
		if last != nil {
			q = q.StartAfter(last)
		}
		snaps, err := q.Documents(ctx).GetAll()
		if err != nil {
			return fmt.Errorf("moderation: export %s: query: %w", logger.HashUID(uid), err)
		}
		docs := make([]reportDoc, len(snaps))
		for i, s := range snaps {
			if err := s.DataTo(&docs[i]); err != nil {
				return fmt.Errorf("moderation: export decode %s: %w", s.Ref.ID, err)
			}
		}
		if err := resolveAccountTargets(ctx, x.people, docs, people); err != nil {
			return err
		}
		for i, s := range snaps {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("moderation: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(toExportedReport(s.Ref.ID, docs[i], people)); err != nil {
				return fmt.Errorf("moderation: write export: %w", err)
			}
		}
		if len(snaps) < opsPage {
			break
		}
		last = snaps[len(snaps)-1]
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("moderation: write export: %w", err)
	}
	return nil
}
