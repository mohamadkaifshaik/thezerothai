// export_requests.go builds the `follow_requests` export section (ADR-0025 D11, ticket W3-32): the requests the
// subject sent and received, newest first, as {userId, handle, requestedAt}. The graph section and its golden are
// unchanged and the privacy/protectedAuthors set doc is never exported (it lists other users).
package graph

import (
	"context"
	"fmt"
	"sort"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// RequestExportRow is one row of the `follow_requests` section: the other party and when the request was made.
type RequestExportRow struct {
	UserID      string    `json:"userId"`
	Handle      string    `json:"handle,omitempty"`
	RequestedAt time.Time `json:"requestedAt"`
}

// RequestsExport is the section body: `{"sent":[...],"received":[...]}`, both newest first, never null.
type RequestsExport struct {
	Sent     []RequestExportRow `json:"sent"`
	Received []RequestExportRow `json:"received"`
}

const requestExportPage = 500

// ExportRequests pages both sides (every query has a Limit of 500) and resolves handles through the ProfileReader in
// batches of 50, as ExportUser does. Reads: 1 per request doc, minimum 2 (one query per side), plus the handle
// lookups for the distinct counterparts (cache-first through the ProfileReader); writes 0. Sent requests are capped
// at 500 by graph/{uid}.requested.
func (r *FirestoreRepo) ExportRequests(ctx context.Context, uid string) (RequestsExport, error) {
	if r.profiles == nil {
		return RequestsExport{}, fmt.Errorf("graph: export requests: ProfileReader not wired (SetProfiles)")
	}
	sent, err := r.exportRequestSide(ctx, uid, true)
	if err != nil {
		return RequestsExport{}, err
	}
	received, err := r.exportRequestSide(ctx, uid, false)
	if err != nil {
		return RequestsExport{}, err
	}
	var sentUIDs, receivedUIDs []string
	for _, d := range sent {
		sentUIDs = append(sentUIDs, d.FolloweeID)
	}
	for _, d := range received {
		receivedUIDs = append(receivedUIDs, d.FollowerID)
	}
	handles, err := r.handlesFor(ctx, sentUIDs, receivedUIDs)
	if err != nil {
		return RequestsExport{}, err
	}
	out := RequestsExport{Sent: make([]RequestExportRow, 0, len(sent)), Received: make([]RequestExportRow, 0, len(received))}
	for _, d := range sent {
		out.Sent = append(out.Sent, RequestExportRow{UserID: d.FolloweeID, Handle: handles[d.FolloweeID], RequestedAt: d.CreatedAt})
	}
	for _, d := range received {
		out.Received = append(out.Received, RequestExportRow{UserID: d.FollowerID, Handle: handles[d.FollowerID], RequestedAt: d.CreatedAt})
	}
	return out, nil
}

// exportRequestSide returns one side's requests, newest first. Received uses the composite index
// `followeeId ASC, createdAt DESC`; sent uses the automatic followerId index ordered by document id (no new
// composite index, ADR-0025 D15) and sorts in memory.
func (r *FirestoreRepo) exportRequestSide(ctx context.Context, uid string, sent bool) ([]requestDoc, error) {
	var all []requestDoc
	var last *firestore.DocumentSnapshot
	for {
		var q firestore.Query
		if sent {
			q = r.client.Collection(followRequestsCollection).Where("followerId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
		} else {
			q = r.client.Collection(followRequestsCollection).Where("followeeId", "==", uid).OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
		}
		if last != nil {
			q = q.StartAfter(last)
		}
		page, err := q.Limit(requestExportPage).Documents(ctx).GetAll()
		reads := int64(len(page))
		if reads == 0 {
			reads = 1
		}
		budget.FromContext(ctx).AddReads(reads)
		if err != nil {
			return nil, fmt.Errorf("graph: export requests query: %w", err)
		}
		for _, s := range page {
			var d requestDoc
			if err := s.DataTo(&d); err != nil {
				return nil, fmt.Errorf("graph: export requests decode: %w", err)
			}
			all = append(all, d)
		}
		if len(page) < requestExportPage {
			break
		}
		last = page[len(page)-1]
	}
	if sent {
		sort.SliceStable(all, func(i, j int) bool { return all[i].CreatedAt.After(all[j].CreatedAt) })
	}
	return all, nil
}
