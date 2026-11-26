package messaging

// purge_plaintext.go is the plaintext cut-over of the end-to-end encryption launch (Plan 6 §2.4): the operator-only
// count and deletion of the readable text the server still holds for plaintext direct messages. It runs from
// `opsctl messages plaintext-count` (read-only, allowed on prod) and `opsctl messages purge-plaintext` (irreversible,
// owner-run, re-confirmed on the day). It is never a cron: a cron would run without that confirmation.
//
// A purged message keeps its record (id, sender, state, times): only its text, its request digest (a hash over the text)
// and its shared post id go, and textRemoved = true says why (Message.text_removed on the wire). textRemoved is never
// queried, so it has no index entry (firebase/firestore.indexes.json is unchanged). An encrypted message (mlsGen >= 1, or
// ctRemoved) is never touched. Nothing here bumps a conversation rev, an entry's changedAt or sends a push: a device that
// cached the text keeps it until its own cache trims it (the claim is about the server).
//
// It reads and writes only this module's own collections (conversations, their messages, users/{uid}/dmInbox and
// dmRequests). The right-to-delete eraser is independent of it: either may run first (purge_plaintext_integration_test.go).

import (
	"context"
	"fmt"
	"sync"

	"cloud.google.com/go/firestore"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	// PlaintextConvPage is the number of conversations one PurgePlaintextPage call walks (by document id).
	PlaintextConvPage = 50
	// plaintextMsgPage is the page of one conversation's messages (by document id).
	plaintextMsgPage = lifecyclePage
	// plaintextWorkers bounds the concurrent message updates of one page.
	plaintextWorkers = 16
	// noLongerStoredSnippet is what a purged last message leaves in a participant's inbox preview (the deletedSnippet
	// pattern: a server string old builds render as is).
	noLongerStoredSnippet = "Message no longer stored"
)

// plaintextMsgFields are the fields the walk reads (Select): the three readable ones, and every field that marks an
// encrypted message (mlsGen, mlsKey, ctRemoved, ciphertext: belt and braces, any one of them is enough to leave the
// message alone) or an already purged one. Reading ciphertext costs its bytes on encrypted messages only (a plaintext
// message has none); that is accepted for a one-off operator run.
var plaintextMsgFields = []string{"text", "sharedPostId", "requestHash", "mlsGen", "mlsKey", "ctRemoved", "ciphertext", "textRemoved"}

// PlaintextMode is what one PurgePlaintextPage call does. The zero value is the read-only count.
type PlaintextMode int

const (
	// PlaintextCountOnly reads conversations and messages and counts the readable ones: no entry read, no write.
	PlaintextCountOnly PlaintextMode = iota
	// PlaintextDryRun also reads the participants' entries and counts the previews it would rewrite; it writes nothing.
	PlaintextDryRun
	// PlaintextPurge writes: one field update per readable message and per stale preview.
	PlaintextPurge
)

// PlaintextTotals is the aggregation count of the two collections the walk would read (about 1 read per 1,000 index
// entries each). Messages counts the `messages` collection group, which only this module writes.
type PlaintextTotals struct {
	Conversations, Messages int64
}

// PlaintextPage is what one PurgePlaintextPage call found and did (counts only, plus the cursor).
type PlaintextPage struct {
	// Last is the id of the last conversation walked (the next call's `after`); More is true when the page was full.
	Last string
	More bool
	// Conversations and Messages are how many documents were read.
	Conversations, Messages int
	// Plaintext is how many messages still held readable data (text, sharedPostId or a plaintext requestHash).
	Plaintext int
	// Purged is how many of them were cleared; Skipped how many changed or went between the read and the update (left
	// for the next run, which reads them again).
	Purged, Skipped int
	// Previews is how many inbox or request entries previewing a purged message were rewritten (in a dry run: would be);
	// PreviewsSkipped how many changed between their read and the update (the next run rewrites them).
	Previews, PreviewsSkipped int
}

// Add sums b into p (Last and More are b's: the latest page's).
func (p *PlaintextPage) Add(b PlaintextPage) {
	p.Last, p.More = b.Last, b.More
	p.Conversations += b.Conversations
	p.Messages += b.Messages
	p.Plaintext += b.Plaintext
	p.Purged += b.Purged
	p.Skipped += b.Skipped
	p.Previews += b.Previews
	p.PreviewsSkipped += b.PreviewsSkipped
}

// PlaintextPurger is the operator seam of `opsctl messages plaintext-count` and `purge-plaintext`. The FirestoreRepo
// implements it; it is not part of the Repo the service uses.
type PlaintextPurger interface {
	// CountPlaintext is the aggregation count of conversations and of the messages collection group. Both 0 means there
	// is nothing to walk.
	CountPlaintext(ctx context.Context) (PlaintextTotals, error)
	// PurgePlaintextPage walks at most PlaintextConvPage conversations after `after` ("" = from the start) in document id
	// order, each with all its messages in pages of 500, and counts, previews or purges as mode says.
	PurgePlaintextPage(ctx context.Context, after string, mode PlaintextMode) (PlaintextPage, error)
}

var _ PlaintextPurger = (*FirestoreRepo)(nil)

// CountPlaintext implements PlaintextPurger: two aggregation queries, no document read.
func (r *FirestoreRepo) CountPlaintext(ctx context.Context) (PlaintextTotals, error) {
	var out PlaintextTotals
	var err error
	if out.Conversations, err = aggCount(ctx, r.client.Collection(conversationsCollection).Query); err != nil {
		return PlaintextTotals{}, fmt.Errorf("messaging: count conversations: %w", err)
	}
	if out.Messages, err = aggCount(ctx, r.client.CollectionGroup(messagesCollection).Query); err != nil {
		return PlaintextTotals{}, fmt.Errorf("messaging: count messages: %w", err)
	}
	return out, nil
}

func aggCount(ctx context.Context, q firestore.Query) (int64, error) {
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	if err != nil {
		return 0, err
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, err
	}
	return out.Count, nil
}

// PurgePlaintextPage implements PlaintextPurger. Per conversation of the page (`conversations ORDER BY __name__ LIMIT 50`,
// Select of the three fields entryFolder needs) it pages the messages by document id (Limit 500, Select of
// plaintextMsgFields: 1 read per message, no index beyond the automatic one) and classifies each:
//   - encrypted (mlsGen >= 1, mlsKey set, ctRemoved or a non-empty ciphertext): never touched, not counted;
//   - already purged (textRemoved): not counted, but its id still counts for the preview check below, so a run that
//     stopped between a message and its preview, or lost a preview to a precondition, is finished by the next run;
//   - readable (non-empty text, sharedPostId or requestHash): Plaintext. In PlaintextPurge mode it gets one field-level
//     Update (text = "", requestHash = "", sharedPostId deleted, textRemoved = true) with a LastUpdateTime precondition
//     equal to the read, as the ciphertext sweep does: a message changed or deleted meanwhile (a takedown, the eraser's
//     tombstone, the peer's tree delete) is Skipped and read again by the next run. Update never recreates a document.
//
// Then, outside the count mode and only when the conversation has a purged (or, in a dry run, a to-be-purged) message,
// both participants' own entries (dmInbox, or dmRequests for the recipient of an open request) are read in one GetAll.
// An entry whose VISIBLE plaintext preview names such a message gets last.snippet = noLongerStoredSnippet and
// last.sharedPost = false, again with a LastUpdateTime precondition (a conflict is PreviewsSkipped). lastMessageAt and
// changedAt stay: the inbox keeps its order and no device is told to refresh. A request accepted after the page read
// the conversation has moved the recipient's entry from dmRequests to dmInbox: a missing dmRequests entry is looked up in
// dmInbox (one more read) and handled the same way; when neither exists it is PreviewsSkipped (the next run reads the
// conversation again).
//
// Errors name no ids in the clear (redactErr). A failed call can be repeated with the same `after`: everything it did is
// already done and is not counted again.
func (r *FirestoreRepo) PurgePlaintextPage(ctx context.Context, after string, mode PlaintextMode) (PlaintextPage, error) {
	q := r.client.Collection(conversationsCollection).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.convRef(after))
	}
	docs, err := q.Select("participants", "state", "requestTo").Limit(PlaintextConvPage).Documents(ctx).GetAll()
	if err != nil {
		return PlaintextPage{}, redactErr(fmt.Errorf("messaging: plaintext list conversations: %w", err), after)
	}
	out := PlaintextPage{Last: after, More: len(docs) == PlaintextConvPage}
	for _, d := range docs {
		var conv ConvDoc
		if derr := d.DataTo(&conv); derr != nil {
			return out, redactErr(fmt.Errorf("messaging: plaintext decode conversation %s: %w", d.Ref.ID, derr), d.Ref.ID)
		}
		purged, err := r.plaintextMessages(ctx, d.Ref.ID, mode, &out)
		if err != nil {
			return out, err
		}
		if mode != PlaintextCountOnly && len(purged) > 0 {
			if err := r.plaintextPreviews(ctx, d.Ref.ID, conv, purged, mode, &out); err != nil {
				return out, err
			}
		}
		out.Conversations++
		out.Last = d.Ref.ID
	}
	return out, nil
}

// plaintextMessages walks one conversation's messages and returns the ids whose text is gone (purged before, purged now,
// or in a dry run to be purged), adding its counts to out.
func (r *FirestoreRepo) plaintextMessages(ctx context.Context, convID string, mode PlaintextMode, out *PlaintextPage) (map[string]bool, error) {
	col := r.convRef(convID).Collection(messagesCollection)
	gone := map[string]bool{}
	cursor := ""
	for {
		q := col.OrderBy(firestore.DocumentID, firestore.Asc)
		if cursor != "" {
			q = q.StartAfter(col.Doc(cursor))
		}
		docs, err := q.Select(plaintextMsgFields...).Limit(plaintextMsgPage).Documents(ctx).GetAll()
		if err != nil {
			return nil, redactErr(fmt.Errorf("messaging: plaintext list messages: %w", err), convID, cursor)
		}
		out.Messages += len(docs)
		var readable []*firestore.DocumentSnapshot
		for _, d := range docs {
			var m MsgDoc
			if derr := d.DataTo(&m); derr != nil {
				return nil, redactErr(fmt.Errorf("messaging: plaintext decode message %s: %w", d.Ref.ID, derr), convID, d.Ref.ID)
			}
			switch plaintextClass(m) {
			case plainPurged:
				gone[d.Ref.ID] = true
			case plainReadable:
				readable = append(readable, d)
			}
		}
		out.Plaintext += len(readable)
		switch mode {
		case PlaintextDryRun:
			for _, d := range readable {
				gone[d.Ref.ID] = true
			}
		case PlaintextPurge:
			if len(readable) > 0 {
				r.hooks.plaintextRead()
				done, skipped, err := updateIfUnchanged(ctx, readable, plaintextRemoval())
				for _, d := range done {
					gone[d.Ref.ID] = true
				}
				out.Purged += len(done)
				out.Skipped += skipped
				if err != nil {
					return nil, redactErr(fmt.Errorf("messaging: plaintext purge message: %w", err), convID)
				}
			}
		}
		if len(docs) < plaintextMsgPage {
			return gone, nil
		}
		cursor = docs[len(docs)-1].Ref.ID
	}
}

// plaintextPreviews rewrites (or, in a dry run, counts) each participant's entry whose preview names a message in gone.
func (r *FirestoreRepo) plaintextPreviews(ctx context.Context, convID string, conv ConvDoc, gone map[string]bool, mode PlaintextMode, out *PlaintextPage) error {
	var refs []*firestore.DocumentRef
	var requestUIDs []string // participants whose entry was looked up in dmRequests, in refs order (or "")
	for _, uid := range conv.Participants {
		if uid == "" || uid == DeletedUID {
			continue
		}
		folder := entryFolder(conv, uid)
		refs = append(refs, r.entryRef(uid, convID, folder))
		if folder == entryRequests {
			requestUIDs = append(requestUIDs, uid)
		} else {
			requestUIDs = append(requestUIDs, "")
		}
	}
	if len(refs) == 0 {
		return nil
	}
	snaps, err := r.client.GetAll(ctx, refs)
	if err != nil {
		return redactErr(fmt.Errorf("messaging: plaintext read entries: %w", err), convID)
	}
	// A dmRequests entry missing at the read: the request was accepted since the page read the conversation (the entry
	// moved to dmInbox), or the recipient deleted it. Look in dmInbox once.
	var moved []*firestore.DocumentRef
	present := snaps[:0:0]
	for i, s := range snaps {
		switch {
		case s != nil && s.Exists():
			present = append(present, s)
		case requestUIDs[i] != "":
			moved = append(moved, r.inboxRef(requestUIDs[i], convID))
		}
		// else: a missing dmInbox entry: the participant deleted the conversation for themselves
	}
	if len(moved) > 0 {
		inbox, ierr := r.client.GetAll(ctx, moved)
		if ierr != nil {
			return redactErr(fmt.Errorf("messaging: plaintext read moved entries: %w", ierr), convID)
		}
		for _, s := range inbox {
			if s != nil && s.Exists() {
				present = append(present, s)
			} else {
				out.PreviewsSkipped++ // neither entry exists: counted, the next run reads the conversation again
			}
		}
	}
	var stale []*firestore.DocumentSnapshot
	for _, s := range present {
		var e EntryDoc
		if derr := s.DataTo(&e); derr != nil {
			return redactErr(fmt.Errorf("messaging: plaintext decode entry: %w", derr), convID)
		}
		if previewStale(e.Last, gone) {
			stale = append(stale, s)
		}
	}
	if mode != PlaintextPurge {
		out.Previews += len(stale)
		return nil
	}
	if len(stale) == 0 {
		return nil
	}
	done, skipped, err := updateIfUnchanged(ctx, stale, []firestore.Update{
		{Path: "last.snippet", Value: noLongerStoredSnippet}, {Path: "last.sharedPost", Value: false},
	})
	out.Previews += len(done)
	out.PreviewsSkipped += skipped
	if err != nil {
		return redactErr(fmt.Errorf("messaging: plaintext rewrite preview: %w", err), convID)
	}
	return nil
}

// Message classes of the walk.
const (
	plainNone     = iota // encrypted, a tombstone, or nothing readable: left alone
	plainReadable        // still holds readable data: purge it
	plainPurged          // purged before (textRemoved)
)

// plaintextClass classifies one message as read with plaintextMsgFields. An encrypted message is never readable here,
// whatever its stored fields say: its requestHash is a digest over ciphertext, and its bytes are the retention sweep's.
func plaintextClass(m MsgDoc) int {
	switch {
	case m.MlsGen >= 1 || m.MlsKey != "" || m.CtRemoved || len(m.Ciphertext) > 0:
		return plainNone
	case m.TextRemoved:
		return plainPurged
	case m.Text != "" || m.SharedPostID != "" || m.RequestHash != "":
		return plainReadable
	}
	return plainNone
}

// plaintextRemoval is the one field update of a purged message. state, senderId and the times stay.
func plaintextRemoval() []firestore.Update {
	return []firestore.Update{
		{Path: "text", Value: ""}, {Path: "requestHash", Value: ""},
		{Path: "sharedPostId", Value: firestore.Delete}, {Path: "textRemoved", Value: true},
	}
}

// previewStale reports whether an entry's preview still shows (or may show) the text of a message whose text is gone: a
// VISIBLE plaintext preview naming it that is not already the no-longer-stored string. A REMOVED or DELETED_ACCOUNT
// preview already holds a server string, and an encrypted one holds no snippet.
func previewStale(l LastDoc, gone map[string]bool) bool {
	return l.State == msgVisible && !l.Encrypted && gone[l.MessageID] &&
		(l.Snippet != noLongerStoredSnippet || l.SharedPost)
}

// updateIfUnchanged applies ups to every document with a LastUpdateTime precondition equal to its read, at most
// plaintextWorkers at a time, and returns the documents it updated (snapshots, not ids: the entries of two users share
// one document id) and how many it skipped because they changed or went since the read (FailedPrecondition, NotFound,
// Aborted). Any other error is returned after the other updates finished.
func updateIfUnchanged(ctx context.Context, docs []*firestore.DocumentSnapshot, ups []firestore.Update) ([]*firestore.DocumentSnapshot, int, error) {
	var (
		mu      sync.Mutex
		done    []*firestore.DocumentSnapshot
		skipped int
		g       errgroup.Group
	)
	g.SetLimit(plaintextWorkers)
	for _, d := range docs {
		g.Go(func() error {
			_, err := d.Ref.Update(ctx, ups, firestore.LastUpdateTime(d.UpdateTime))
			mu.Lock()
			defer mu.Unlock()
			switch status.Code(err) {
			case codes.OK:
				done = append(done, d)
			case codes.FailedPrecondition, codes.NotFound, codes.Aborted:
				skipped++
			default:
				return redactErr(err, refIDs(d.Ref)...) // the path names the conversation, the message or the entry's owner
			}
			return nil
		})
	}
	err := g.Wait()
	return done, skipped, err
}

// refIDs is every document id on ref's path (the document's own, then each parent document's), for redactErr.
func refIDs(ref *firestore.DocumentRef) []string {
	var out []string
	for ref != nil {
		out = append(out, ref.ID)
		if ref.Parent == nil {
			break
		}
		ref = ref.Parent.Parent
	}
	return out
}
