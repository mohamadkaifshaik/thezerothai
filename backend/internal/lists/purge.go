// purge.go is the right-to-delete and right-to-access path of lists/{listId}. Deleting users/{uid}
// does not delete a list, so the `lists` account-deletion step (Eraser, registered BeforeIdentity after `messaging`) removes
// the user's own lists and then removes the uid from every other list that names it, and the `lists` export section writes
// the user's own lists, naming each member by public id and handle (never by uid). Neither is flag-gated: documents
// outlive the flag.
package lists

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// purgePage is the most lists one eraser invocation touches (a Firestore batch holds 500 writes).
	purgePage = 500
	// exportPage is the page of the export (a user owns at most LISTS_MAX_PER_USER = 20 lists, so one page in practice).
	exportPage = 100

	phaseOwn     = ""
	phaseMember  = "member"
	phaseFollows = "follows" // appended after member: old checkpoints keep their meaning
)

// MemberPage is the outcome of one RemoveMemberPage call.
type MemberPage struct {
	// Scanned is how many lists named the uid on this page (the query's size, at most purgePage).
	Scanned int
	// Updated is how many of them were rewritten.
	Updated int
	// Conflict says the batch lost a race (a list changed or went away between the query and the commit); nothing was
	// written and the next call re-queries.
	Conflict bool
}

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// PurgeOwnedPage deletes up to purgePage of uid's own lists in one atomic batch and reports how many. Reads: one per
	// list (minimum 1); deletes: one per list. Deleted lists leave the next page, so repeating the call is self-resuming.
	PurgeOwnedPage(ctx context.Context, uid string) (deleted int, err error)
	// RemoveMemberPage removes uid from up to purgePage lists that name it (memberIds array-contains uid): a field-level
	// Update (ArrayRemove and updatedAt) with a LastUpdateTime precondition, never a Set. Reads: one per list (minimum 1);
	// writes: one per list. A list changed or deleted since the query makes the batch a Conflict with nothing written.
	RemoveMemberPage(ctx context.Context, uid string) (MemberPage, error)
	// PurgeFollowerPage removes up to followPurgePage of uid's follow markers and decrements each list's followerCount in the
	// same transaction (the list may be gone: then only the marker goes). Repeating the call resumes.
	PurgeFollowerPage(ctx context.Context, uid string) (MemberPage, error)
}

var _ PagePurger = (*FirestoreRepo)(nil)

// PurgeOwnedPage implements PagePurger.
func (r *FirestoreRepo) PurgeOwnedPage(ctx context.Context, uid string) (int, error) {
	docs, err := r.col().Where("ownerId", "==", uid).Select().Limit(purgePage).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("lists: purge owned %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	ids := make([]string, len(docs))
	b := store.NewFirestoreBatch(r.client)
	for i, d := range docs {
		ids[i] = d.Ref.ID
		// The list's follow markers go first, so a crash between the two leaves a list the next call finds again.
		if _, err := r.deleteFollowMarkers(ctx, d.Ref.ID); err != nil {
			return 0, logger.RedactErr(fmt.Errorf("lists: purge owned %s: markers: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
		}
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		// The commit error names the deleted documents' paths: redact the uid and the list ids.
		return 0, logger.RedactErr(fmt.Errorf("lists: purge owned %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
	}
	return len(docs), nil
}

// RemoveMemberPage implements PagePurger.
func (r *FirestoreRepo) RemoveMemberPage(ctx context.Context, uid string) (MemberPage, error) {
	docs, err := r.col().Where("memberIds", "array-contains", uid).Select().Limit(purgePage).Documents(ctx).GetAll()
	if err != nil {
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge member %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return MemberPage{}, nil
	}
	ids := make([]string, len(docs))
	now := r.now().UTC()
	b := store.NewFirestoreBatch(r.client)
	for i, d := range docs {
		ids[i] = d.Ref.ID
		b.Update(d.Ref, []firestore.Update{
			{Path: "memberIds", Value: firestore.ArrayRemove(uid)},
			{Path: "updatedAt", Value: now},
		}, firestore.LastUpdateTime(d.UpdateTime))
	}
	if err := b.Commit(ctx); err != nil {
		if store.IsPreconditionFailed(err) {
			return MemberPage{Scanned: len(docs), Conflict: true}, nil
		}
		return MemberPage{}, logger.RedactErr(fmt.Errorf("lists: purge member %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
	}
	return MemberPage{Scanned: len(docs), Updated: len(docs)}, nil
}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning. Deleted and rewritten lists drop
// out of the next page, so the purge is self-resuming and the counts are only for logging. It is the step's own type: the step
// name is persisted in deletionJob.step.
type Checkpoint struct {
	// Phase is "" while the user's own lists are being deleted and "member" while the uid is being removed from other lists.
	Phase   string `json:"phase,omitempty"`
	Deleted int    `json:"deleted,omitempty"`
	Updated int    `json:"updated,omitempty"`
}

// Eraser is the `lists` account-deletion step. Phase 1 deletes the user's own lists (which also removes any
// membership in them), phase 2 removes the uid from other users' lists. One page of at most 500 per call; never flag-gated.
type Eraser struct {
	repo PagePurger
}

// NewEraser builds the step on a PagePurger (FirestoreRepo in production).
func NewEraser(repo PagePurger) *Eraser { return &Eraser{repo: repo} }

// PurgeUser runs one page and reports whether the step is finished. An account with no lists takes two calls (an empty page
// per phase, no writes); a repeat after completion is the same two empty pages, so a rerun writes nothing. It deletes each own
// list and updates each list the user was a member of.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Phase == phaseOwn {
		n, err := e.repo.PurgeOwnedPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Phase: phaseOwn, Deleted: cp.Deleted + n, Updated: cp.Updated}
		if n < purgePage {
			next.Phase = phaseMember
		}
		slog.InfoContext(ctx, "lists_purge", "uid_hash", logger.HashUID(uid), "phase", "own", "docs", n, "deleted_total", next.Deleted)
		return next, false, nil
	}
	if cp.Phase == phaseFollows {
		pg, err := e.repo.PurgeFollowerPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Phase: phaseFollows, Deleted: cp.Deleted, Updated: cp.Updated + pg.Updated}
		slog.InfoContext(ctx, "lists_purge", "uid_hash", logger.HashUID(uid), "phase", "follows", "docs", pg.Updated, "updated_total", next.Updated)
		return next, pg.Scanned < followPurgePage, nil
	}
	pg, err := e.repo.RemoveMemberPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := Checkpoint{Phase: phaseMember, Deleted: cp.Deleted, Updated: cp.Updated + pg.Updated}
	slog.InfoContext(ctx, "lists_purge", "uid_hash", logger.HashUID(uid), "phase", "member", "docs", pg.Updated, "conflict", pg.Conflict, "updated_total", next.Updated)
	if pg.Conflict {
		return next, false, nil // nothing was written: the next call re-queries
	}
	if pg.Scanned < purgePage {
		next.Phase = phaseFollows // the member phase is done; the follow markers are next
	}
	return next, false, nil
}

// ExportedList is one row of the `lists` export section: the user's own list with its members. Lists the user
// is a member of belong to their owners and are not exported here (see lists_member_of). MemberIDs is what the repo
// reads and is never written; the Exporter turns it into Members (exportVersion 2: the section had "memberIds" before).
type ExportedList struct {
	ListID      string           `json:"listId"`
	Name        string           `json:"name"`
	Description string           `json:"description"`
	IsPrivate   bool             `json:"isPrivate"`
	MemberIDs   []string         `json:"-"`
	Members     []ExportedPerson `json:"members"`
	CreatedAt   time.Time        `json:"createdAt"`
	UpdatedAt   time.Time        `json:"updatedAt"`
}

// ExportedPerson is another person in the export, named by public id and handle, never by uid (owner decision, public
// ids; the same row as the graph section's). PublicID is omitted when the person has none (never minted), Handle when the
// profile is gone (erased); a row with neither is still written, so a list keeps one row per member.
type ExportedPerson struct {
	PublicID string `json:"publicId,omitempty"`
	Handle   string `json:"handle,omitempty"`
}

// PeopleSource resolves members' profiles for the export: identity's repo in production (users/{uid} by GetAll, at most
// 50 ids per call, EVERY account status, so a suspended or deleting member is still named; an erased one is absent). It
// is deliberately not identity.Directory, which drops non-ACTIVE accounts and is cache-first.
type PeopleSource interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error)
}

// ExportSource pages through a user's own lists (FirestoreRepo in production).
type ExportSource interface {
	// ExportPage returns uid's lists after the list id `after` ("" = from the start), in id order, at most limit. Reads:
	// len(result), minimum 1.
	ExportPage(ctx context.Context, uid, after string, limit int) ([]ExportedList, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// ExportPage implements ExportSource: ownerId == uid ordered by the document id, on the automatic single-field index, with a
// Limit.
func (r *FirestoreRepo) ExportPage(ctx context.Context, uid, after string, limit int) ([]ExportedList, error) {
	q := r.col().Where("ownerId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(min(max(limit, 1), exportPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("lists: export %s: query: %w", logger.HashUID(uid), err), uid, after)
	}
	out := make([]ExportedList, 0, len(docs))
	for _, s := range docs {
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: export decode: %w", err), uid, s.Ref.ID)
		}
		members := d.MemberIDs
		if members == nil {
			members = []string{}
		}
		out = append(out, ExportedList{
			ListID: s.Ref.ID, Name: d.Name, Description: d.Description, IsPrivate: d.IsPrivate, MemberIDs: members,
			CreatedAt: d.CreatedAt.UTC(), UpdatedAt: d.UpdatedAt.UTC(),
		})
	}
	return out, nil
}

// Exporter writes the `lists` export section.
type Exporter struct {
	src ExportSource
	// people names the members of the user's own lists (required: without it the export fails rather than write a uid).
	people PeopleSource
	// member, handles and social are set by WithMembership; a nil member writes no lists_member_of part.
	member  MemberOfSource
	handles HandleSource
	social  SocialSource
	// follows is set by WithFollows; a nil follows writes no "follows" part (the golden export is unchanged without it).
	follows FollowSource
}

// FollowSource reads the markers of one account for the export (FirestoreRepo.FollowedBy).
type FollowSource interface {
	FollowedBy(ctx context.Context, uid string, limit int) ([]FollowRow, error)
}

// WithFollows adds the "follows" part: the lists uid follows, as the markers name them (list id and when followed).
func (x *Exporter) WithFollows(src FollowSource) *Exporter {
	x.follows = src
	return x
}

// NewExporter builds the section on an ExportSource (FirestoreRepo in production) and the PeopleSource that names the
// members (identity's repo in production).
func NewExporter(src ExportSource, people PeopleSource) *Exporter {
	return &Exporter{src: src, people: people}
}

// ExportUser streams {"lists":[...]} to w, in list-id order, in pages of 100 (memory stays bounded). Reads: one per list,
// minimum 1, plus one profile read per distinct member across the user's lists (GetAll chunks of 50; a person on several
// lists is read once). The public id is on that same users/{uid} read, whatever public_ids says now.
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if x.people == nil {
		return fmt.Errorf("lists: export: PeopleSource not wired")
	}
	if _, err := io.WriteString(w, `{"lists":[`); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first, after := true, ""
	people := map[string]ExportedPerson{}
	for {
		page, err := x.src.ExportPage(ctx, uid, after, exportPage)
		if err != nil {
			return err
		}
		if err := x.resolvePeople(ctx, page, people); err != nil {
			return err
		}
		for _, l := range page {
			l.Members = make([]ExportedPerson, 0, len(l.MemberIDs))
			for _, m := range l.MemberIDs {
				l.Members = append(l.Members, people[m]) // an unresolved member is an empty row, never the uid
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("lists: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(l); err != nil {
				return fmt.Errorf("lists: write export: %w", err)
			}
		}
		if len(page) < exportPage {
			break
		}
		after = page[len(page)-1].ListID
	}
	if _, err := io.WriteString(w, "]"); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	if x.member != nil {
		if err := x.writeMemberOf(ctx, uid, w); err != nil {
			return err
		}
	}
	if x.follows != nil {
		if err := x.writeFollows(ctx, uid, w); err != nil {
			return err
		}
	}
	if _, err := io.WriteString(w, "}\n"); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	return nil
}

// resolvePeople adds to people every member of page not resolved yet, one PeopleSource call per memberOfLookupChunk ids.
// An erased member gets the zero row, so it is not looked up again.
func (x *Exporter) resolvePeople(ctx context.Context, page []ExportedList, people map[string]ExportedPerson) error {
	var need []string
	for _, l := range page {
		for _, m := range l.MemberIDs {
			if _, ok := people[m]; !ok {
				people[m] = ExportedPerson{}
				need = append(need, m)
			}
		}
	}
	for i := 0; i < len(need); i += memberOfLookupChunk {
		profs, err := x.people.GetProfiles(ctx, need[i:min(i+memberOfLookupChunk, len(need))])
		if err != nil {
			return fmt.Errorf("lists: export members: %w", err)
		}
		for id, p := range profs {
			people[id] = ExportedPerson{PublicID: p.PublicID, Handle: p.Handle}
		}
	}
	return nil
}

// writeFollows writes `,"follows":[{"listId":...,"followedAt":...}]`: at most MaxFollowsPerUser rows (one read page).
func (x *Exporter) writeFollows(ctx context.Context, uid string, w io.Writer) error {
	rows, err := x.follows.FollowedBy(ctx, uid, MaxFollowsPerUser)
	if err != nil {
		return err
	}
	type followOut struct {
		ListID     string    `json:"listId"`
		FollowedAt time.Time `json:"followedAt"`
	}
	out := make([]followOut, 0, len(rows))
	for _, r := range rows {
		out = append(out, followOut{ListID: r.ListID, FollowedAt: r.CreatedAt})
	}
	b, err := json.Marshal(out)
	if err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	if _, err := io.WriteString(w, `,"follows":`); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	if _, err := w.Write(b); err != nil {
		return fmt.Errorf("lists: write export: %w", err)
	}
	return nil
}
