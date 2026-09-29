// export.go builds the manual data-export view of one user's social graph (ADR-0008 D12, T11).
package graph

import (
	"context"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// exportEdgePage is the page size for walking follow edges (a batch job, not a request path).
const exportEdgePage = 500

// ExportUser is one row of an export: a uid and, when the profile still exists, its handle.
type ExportUser struct {
	UserID string `json:"userId"`
	Handle string `json:"handle,omitempty"`
}

// Export is the subject's own graph data. By construction it has no field for who blocked the subject
// (ADR-0008 D12: "data export should never list who blocked the user"); blockedBy is never read here.
type Export struct {
	UserID    string       `json:"userId"`
	Following []ExportUser `json:"following"`
	Followers []ExportUser `json:"followers"`
	Blocked   []ExportUser `json:"blocked"`
	Muted     []ExportUser `json:"muted"`
}

// ExportUser walks the subject's follow edges (both sides, 500 per page, every query limited), reads blocked
// and muted from graph/{uid}, and resolves handles through the ProfileReader in batches of 50. Reads:
// edges + 1 graph doc + one per distinct listed user; writes 0.
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

	handles, err := r.handlesFor(ctx, following, followers, d.Blocked, d.Muted)
	if err != nil {
		return Export{}, err
	}
	out.Following = withHandles(following, handles)
	out.Followers = withHandles(followers, handles)
	out.Blocked = withHandles(d.Blocked, handles)
	out.Muted = withHandles(d.Muted, handles)
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

func (r *FirestoreRepo) handlesFor(ctx context.Context, lists ...[]string) (map[string]string, error) {
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
	handles := make(map[string]string, len(all))
	for start := 0; start < len(all); start += profileGetAllCap {
		end := min(start+profileGetAllCap, len(all))
		got, err := r.profiles.GetProfiles(ctx, all[start:end])
		if err != nil {
			return nil, fmt.Errorf("graph: export: profiles: %w", err)
		}
		for uid, p := range got {
			handles[uid] = p.Handle
		}
	}
	return handles, nil
}

func withHandles(uids []string, handles map[string]string) []ExportUser {
	out := make([]ExportUser, 0, len(uids))
	for _, u := range uids {
		out = append(out, ExportUser{UserID: u, Handle: handles[u]})
	}
	return out
}
