package lists

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The `lists_member_of` part of the `lists` export section (ADR-0030 D8 as-built note, W5-46, W5-17 L-7; founder 2026-10-31:
// "export users' own membership records while redacting private-list details and other members").
//
// What the user is shown is only what D3 would let them read as a viewer: a list they can see (public, not hidden by
// moderation, owner ACTIVE, owner not protected unless the user follows it) appears with its id, its owner's handle and its
// name. Every other list that names them (private, hidden, owner gone or not ACTIVE, owner protected and not followed) is
// counted in redactedCount and nothing else: no id, name, description, owner or other member. The count is the user's own
// membership record; it never says which cause applied, so the section cannot tell a private list from a moderated one.
// Lists the user owns are not repeated here (they are in `lists`). The export never carries any other member's id.

// MemberOfDoc is one list that names the user, as the repo returns it before redaction. It is never written as is.
type MemberOfDoc struct {
	ListID    string
	OwnerID   string
	Name      string
	IsPrivate bool
	Hidden    bool
}

// MemberOfSource pages through the lists that name a user (FirestoreRepo in production).
type MemberOfSource interface {
	// MemberOfPage returns the lists whose memberIds contain uid, after the list id `after` ("" = from the start), in id order,
	// at most limit, without the lists uid owns. last is the final id the query matched (kept or not) and full says the query
	// filled the page, so there may be another. Reads: one per list the query matches (minimum 1).
	MemberOfPage(ctx context.Context, uid, after string, limit int) (docs []MemberOfDoc, last string, full bool, err error)
}

var _ MemberOfSource = (*FirestoreRepo)(nil)

// MemberOfPage implements MemberOfSource: `memberIds array-contains uid` ordered by the document id (the automatic
// array-contains index), with a Limit.
func (r *FirestoreRepo) MemberOfPage(ctx context.Context, uid, after string, limit int) ([]MemberOfDoc, string, bool, error) {
	limit = min(max(limit, 1), exportPage)
	q := r.col().Where("memberIds", "array-contains", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, "", false, logger.RedactErr(fmt.Errorf("lists: export member-of %s: query: %w", logger.HashUID(uid), err), uid, after)
	}
	out := make([]MemberOfDoc, 0, len(docs))
	last := ""
	for _, s := range docs {
		last = s.Ref.ID
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, "", false, logger.RedactErr(fmt.Errorf("lists: export member-of decode: %w", err), uid, s.Ref.ID)
		}
		if d.OwnerID == uid {
			continue
		}
		out = append(out, MemberOfDoc{ListID: s.Ref.ID, OwnerID: d.OwnerID, Name: d.Name, IsPrivate: d.IsPrivate, Hidden: d.Hidden})
	}
	return out, last, len(docs) == limit, nil
}

// HandleSource resolves owners' profiles (identity.Directory in production; cache-first, at most 50 ids per call).
type HandleSource interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// SocialSource is the user's own graph (graph.Reader in production; cache-first, 60 s).
type SocialSource interface {
	Snapshot(ctx context.Context, uid string) (graph.Snapshot, error)
}

// memberOfLookupChunk bounds one directory call (ADR-0008 T6: at most 50 ids).
const memberOfLookupChunk = 50

// ExportedMembership is one public membership row of `lists_member_of.public`.
type ExportedMembership struct {
	ListID      string `json:"listId"`
	OwnerHandle string `json:"ownerHandle"`
	Name        string `json:"name"`
}

// WithMembership turns on the `lists_member_of` part of the section. Without it the section carries `lists` only.
func (x *Exporter) WithMembership(src MemberOfSource, handles HandleSource, social SocialSource) *Exporter {
	x.member, x.handles, x.social = src, handles, social
	return x
}

// writeMemberOf writes `,"lists_member_of":{"public":[...],"redactedCount":N}` (the section's closing brace is the caller's).
// Reads: one per list that names the user (pages of 100), plus the owners' profiles (distinct public owners, cache-first,
// chunks of 50) and 1 graph read (cache-first) only when a protected owner's list is met. Memory stays bounded: one page of
// rows and the owner cache.
func (x *Exporter) writeMemberOf(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `,"lists_member_of":{"public":[`); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	owners := map[string]identity.Profile{}
	var snap *graph.Snapshot
	first, redacted, after := true, 0, ""
	for {
		page, last, full, err := x.member.MemberOfPage(ctx, uid, after, exportPage)
		if err != nil {
			return err
		}
		var need []string
		for _, d := range page {
			if _, ok := owners[d.OwnerID]; !ok && !d.IsPrivate && !d.Hidden {
				owners[d.OwnerID] = identity.Profile{} // a missing owner stays zero: Status is not ACTIVE, so redacted
				need = append(need, d.OwnerID)
			}
		}
		for i := 0; i < len(need); i += memberOfLookupChunk {
			profs, err := x.handles.GetProfiles(ctx, need[i:min(i+memberOfLookupChunk, len(need))])
			if err != nil {
				return fmt.Errorf("lists: export member-of owners: %w", err)
			}
			for id, p := range profs {
				owners[id] = p
			}
		}
		for _, d := range page {
			p := owners[d.OwnerID]
			if d.IsPrivate || d.Hidden || p.Status != identity.AccountStatusActive {
				redacted++
				continue
			}
			if p.IsPrivate { // a protected owner's list is visible only to a follower (W5-42)
				if snap == nil {
					s, err := x.social.Snapshot(ctx, uid)
					if err != nil {
						return fmt.Errorf("lists: export member-of graph: %w", err)
					}
					snap = &s
				}
				if !snap.Following[d.OwnerID] {
					redacted++
					continue
				}
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("lists: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(ExportedMembership{ListID: d.ListID, OwnerHandle: p.Handle, Name: d.Name}); err != nil {
				return fmt.Errorf("lists: write export: %w", err)
			}
		}
		if !full {
			break
		}
		after = last
	}
	if _, err := fmt.Fprintf(w, `],"redactedCount":%d}`, redacted); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	return nil
}
