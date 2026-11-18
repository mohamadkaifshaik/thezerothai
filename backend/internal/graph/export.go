// export.go builds the manual data-export view of one user's social graph.
package graph

import (
	"context"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// exportEdgePage is the page size for walking follow edges (a batch job, not a request path).
const exportEdgePage = 500

// ExportUser is one row of an export: another person, named by public id and handle, never by uid (owner decision,
// public ids: the archive leaves the account owner's hands). PublicID is omitted when the person has none (never
// minted: public_ids was globally off, the prod state, or the account predates the backfill), Handle when the profile is
// gone (erased); a row with neither is still written, so a list keeps one row per edge. Format change of exportVersion
// 2: rows had {userId, handle} before.
type ExportUser struct {
	PublicID string `json:"publicId,omitempty"`
	Handle   string `json:"handle,omitempty"`
}

// Export is the subject's own graph data. UserID is the subject's own uid (their data); every listed person is an
// ExportUser. By construction it has no field for who blocked the subject
// ("data export should never list who blocked the user"); blockedBy is never read here.
type Export struct {
	UserID    string       `json:"userId"`
	Following []ExportUser `json:"following"`
	Followers []ExportUser `json:"followers"`
	Blocked   []ExportUser `json:"blocked"`
	Muted     []ExportUser `json:"muted"`
}

// ExportUser walks the subject's follow edges (both sides, 500 per page, every query limited), reads blocked
// and muted from graph/{uid}, and resolves handles and public ids through the ProfileReader in batches of 50. It reads
// the edges, the graph doc and one profile per distinct listed user (the public id is on that same users/{uid} read:
// no extra read), and writes nothing.
func (r *FirestoreRepo) ExportUser(ctx context.Context, uid string) (Export, error) {
	if r.profiles == nil {
		return Export{}, fmt.Errorf("graph: export: ProfileReader not wired (SetProfiles)")
	}
	out := Export{UserID: uid}
	following, err := r.exportEdges(ctx, uid, false)
	if err != nil {
		return Export{}, err
	}
	followers, err := r.exportEdges(ctx, uid, true)
	if err != nil {
		return Export{}, err
	}
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Export{}, err
	}

	people, err := r.peopleFor(ctx, following, followers, d.Blocked, d.Muted)
	if err != nil {
		return Export{}, err
	}
	out.Following = exportRows(following, people)
	out.Followers = exportRows(followers, people)
	out.Blocked = exportRows(d.Blocked, people)
	out.Muted = exportRows(d.Muted, people)
	return out, nil
}

func (r *FirestoreRepo) exportEdges(ctx context.Context, uid string, followers bool) ([]string, error) {
	var uids []string
	var after *cursor.Cursor
	for {
		edges, err := r.ListEdges(ctx, EdgeQuery{UID: uid, Followers: followers, Limit: exportEdgePage, After: after})
		if err != nil {
			return nil, err
		}
		for _, e := range edges {
			uids = append(uids, e.otherUID(followers))
		}
		if len(edges) < exportEdgePage {
			return uids, nil
		}
		last := edges[len(edges)-1]
		after = &cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.DocID}
	}
}

// peopleFor resolves every distinct uid of lists to its export row through the ProfileReader (identity's repo: all
// account statuses, erased ones absent), one GetAll per profileGetAllCap uids. The public id is read from the same
// users/{uid} document as the handle, whatever public_ids says now, like the subject's own public id in the profile
// section (identity/lifecycle_export.go).
func (r *FirestoreRepo) peopleFor(ctx context.Context, lists ...[]string) (map[string]ExportUser, error) {
	seen := map[string]struct{}{}
	var all []string
	for _, l := range lists {
		for _, u := range l {
			if _, ok := seen[u]; !ok {
				seen[u] = struct{}{}
				all = append(all, u)
			}
		}
	}
	people := make(map[string]ExportUser, len(all))
	for start := 0; start < len(all); start += profileGetAllCap {
		end := min(start+profileGetAllCap, len(all))
		got, err := r.profiles.GetProfiles(ctx, all[start:end])
		if err != nil {
			// The read names the people asked for (identity's error text, Firestore's document paths): nobody is named
			// on the way out, and the counterpart pseudonym is not their uid_hash.
			return nil, logger.ScrubPairErr(fmt.Errorf("graph: export: profiles: %w", err), "", all[start:end]...)
		}
		for uid, p := range got {
			people[uid] = ExportUser{PublicID: p.PublicID, Handle: p.Handle}
		}
	}
	return people, nil
}

// exportRows is one row per uid, in order; an unresolved uid is an empty row (never the uid).
func exportRows(uids []string, people map[string]ExportUser) []ExportUser {
	out := make([]ExportUser, 0, len(uids))
	for _, u := range uids {
		out = append(out, people[u])
	}
	return out
}
