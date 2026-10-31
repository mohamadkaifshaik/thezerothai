package messaging

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// legacyDeletedUID is the placeholder the eraser wrote before W7-34 (L-2). It is a valid uid shape, so it is replaced by
// DeletedUID in dev data by `opsctl messages migrate-placeholder`; messaging was never on in prod. Nothing else reads it.
const legacyDeletedUID = "deleted"

// migratePage is the number of conversations one MigratePlaceholder call handles.
const migratePage = 50

// PlaceholderPage is what one MigratePlaceholder call found and did.
type PlaceholderPage struct {
	// Last is the id of the last conversation handled (the next call's cursor); More is true when the page was full.
	Last string
	More bool
	// Conversations, Messages and Entries count the documents that carried the legacy value (and, outside a dry run, were
	// rewritten): conversations, tombstoned messages (senderId) and surviving peers' entries (peerId).
	Conversations, Messages, Entries int
}

// PlaceholderMigrator is the operator seam of `opsctl messages migrate-placeholder` (W7-34). The FirestoreRepo implements it;
// it is not part of the Repo the service uses.
type PlaceholderMigrator interface {
	// MigratePlaceholder handles one page of at most 50 conversations after the cursor `after` ("" = from the start).
	// Dry-run reads the same documents and writes nothing.
	MigratePlaceholder(ctx context.Context, after string, dryRun bool) (PlaceholderPage, error)
}

var _ PlaceholderMigrator = (*FirestoreRepo)(nil)

// MigratePlaceholder replaces the legacy placeholder "deleted" by DeletedUID in dev data. It finds work through
// `conversations where participants array-contains "deleted" ORDER BY __name__ LIMIT 50` (no collection-group query exists),
// and per conversation, in the eraser's order so a crash leaves the conversation findable and a rerun finishes it:
//  1. the messages with `senderId == "deleted"` (pages of 500 by __name__): senderId -> DeletedUID;
//  2. the surviving participant's own entry (dmRequests only for the recipient of an unaccepted request, else dmInbox):
//     peerId -> DeletedUID when it holds the legacy value;
//  3. the conversation LAST: participants, gone, requestFrom and requestTo swapped in one field-level Update (position kept).
//
// Every write is a field-level Update carrying the LastUpdateTime of the document as read (a document changed meanwhile
// fails the call with FailedPrecondition and the rerun re-reads it; nothing is ever recreated or overwritten with Set). No
// rev, updatedAt or changedAt moves: no client-visible value changes, since the legacy value was never shown. A rerun finds
// nothing and writes 0 (1 read for the empty query).
//
// Reads: 1 per conversation returned by the query, 1 per matching message (+1 for a conversation's empty message query),
// 1 for the entry probe; writes: at most 1 per matching message, entry and conversation. Dev only (the command refuses *-prod).
func (r *FirestoreRepo) MigratePlaceholder(ctx context.Context, after string, dryRun bool) (PlaceholderPage, error) {
	c := budget.FromContext(ctx)
	q := r.client.Collection(conversationsCollection).Where("participants", "array-contains", legacyDeletedUID).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.convRef(after))
	}
	docs, err := q.Limit(migratePage).Documents(ctx).GetAll()
	c.AddQueryReads(len(docs))
	if err != nil {
		return PlaceholderPage{}, redactErr(fmt.Errorf("messaging: migrate list conversations: %w", err), after)
	}
	out := PlaceholderPage{More: len(docs) == migratePage}
	for _, d := range docs {
		var conv ConvDoc
		if derr := d.DataTo(&conv); derr != nil {
			return out, fmt.Errorf("messaging: migrate decode conversation: %w", derr)
		}
		convID := d.Ref.ID
		n, err := r.migrateMessages(ctx, convID, dryRun)
		out.Messages += n
		if err != nil {
			return out, err
		}
		e, err := r.migrateEntry(ctx, conv, convID, dryRun)
		out.Entries += e
		if err != nil {
			return out, err
		}
		if !dryRun {
			b := store.NewFirestoreBatch(r.client, c)
			b.Update(d.Ref, legacySwap(conv), firestore.LastUpdateTime(d.UpdateTime))
			if cerr := b.Commit(ctx); cerr != nil {
				return out, redactErr(fmt.Errorf("messaging: migrate conversation: %w", cerr), convID)
			}
		}
		out.Conversations++
		out.Last = convID
	}
	return out, nil
}

// legacySwap is the conversation update: the four fields that can hold the placeholder, the legacy value replaced in place.
func legacySwap(conv ConvDoc) []firestore.Update {
	swap := func(in []string) []string {
		out := make([]string, len(in))
		for i, v := range in {
			out[i] = v
			if v == legacyDeletedUID {
				out[i] = DeletedUID
			}
		}
		return out
	}
	ups := []firestore.Update{{Path: "participants", Value: swap(conv.Participants)}, {Path: "gone", Value: swap(conv.Gone)}}
	if conv.RequestFrom == legacyDeletedUID {
		ups = append(ups, firestore.Update{Path: "requestFrom", Value: DeletedUID})
	}
	if conv.RequestTo == legacyDeletedUID {
		ups = append(ups, firestore.Update{Path: "requestTo", Value: DeletedUID})
	}
	return ups
}

// migrateMessages rewrites senderId on every message of the conversation that holds the legacy value, in pages of 500, and
// returns how many. In a dry run it counts them (all pages walked).
func (r *FirestoreRepo) migrateMessages(ctx context.Context, convID string, dryRun bool) (int, error) {
	c := budget.FromContext(ctx)
	col := r.convRef(convID).Collection(messagesCollection)
	total, cursor := 0, ""
	for {
		q := col.Where("senderId", "==", legacyDeletedUID).OrderBy(firestore.DocumentID, firestore.Asc)
		if cursor != "" {
			q = q.StartAfter(col.Doc(cursor))
		}
		docs, err := q.Limit(lifecyclePage).Documents(ctx).GetAll()
		c.AddQueryReads(len(docs))
		if err != nil {
			return total, redactErr(fmt.Errorf("messaging: migrate list messages: %w", err), convID, cursor)
		}
		if len(docs) == 0 {
			return total, nil
		}
		if !dryRun {
			b := store.NewFirestoreBatch(r.client, c)
			for _, d := range docs {
				b.Update(d.Ref, []firestore.Update{{Path: "senderId", Value: DeletedUID}}, firestore.LastUpdateTime(d.UpdateTime))
			}
			if cerr := b.Commit(ctx); cerr != nil {
				return total, redactErr(fmt.Errorf("messaging: migrate messages: %w", cerr), convID)
			}
		}
		total += len(docs)
		if len(docs) < lifecyclePage {
			return total, nil
		}
		cursor = docs[len(docs)-1].Ref.ID
	}
}

// migrateEntry rewrites peerId on the surviving participant's own entry when it holds the legacy value; returns 1 when it
// did (or, in a dry run, would). A conversation with no live participant (both gone) has no entry to fix. Reads 1.
func (r *FirestoreRepo) migrateEntry(ctx context.Context, conv ConvDoc, convID string, dryRun bool) (int, error) {
	survivor := ""
	for _, p := range conv.Participants {
		if p != legacyDeletedUID && p != DeletedUID {
			survivor = p
		}
	}
	if survivor == "" {
		return 0, nil
	}
	c := budget.FromContext(ctx)
	ref := r.entryRef(survivor, convID, entryFolder(conv, survivor))
	snap, err := ref.Get(ctx)
	c.AddReads(1)
	if status.Code(err) == codes.NotFound {
		return 0, nil // the survivor deleted the conversation for themselves
	}
	if err != nil {
		return 0, redactErr(fmt.Errorf("messaging: migrate read entry: %w", err), survivor, convID)
	}
	var e EntryDoc
	if derr := snap.DataTo(&e); derr != nil {
		return 0, fmt.Errorf("messaging: migrate decode entry: %w", derr)
	}
	if e.PeerID != legacyDeletedUID {
		return 0, nil
	}
	if !dryRun {
		b := store.NewFirestoreBatch(r.client, c)
		b.Update(ref, []firestore.Update{{Path: "peerId", Value: DeletedUID}}, firestore.LastUpdateTime(snap.UpdateTime))
		if cerr := b.Commit(ctx); cerr != nil {
			return 0, redactErr(fmt.Errorf("messaging: migrate entry: %w", cerr), survivor, convID)
		}
	}
	return 1, nil
}
