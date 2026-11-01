// purge.go is the right-to-delete and right-to-access path of the communities collections (ADR-0031 D9, ticket W5-24). Deleting
// users/{uid} removes none of communities/{cid}, its communityMembers or communityMemberships/{uid}, so the `communities`
// account-deletion step (Eraser, registered BeforeIdentity after `poll_votes`) takes the user out of every community that names them,
// and the `communities` export section writes what the user is entitled to see. Neither is flag-gated: documents outlive the flag.
package communities

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// defaultEraserChunk is the most communities one eraser invocation handles, each in its own transaction. A user is in at most 50
	// joined communities plus the few they own, are banned from or appear in a log of; ten per invocation keeps one invocation well
	// inside the lifecycle's work budget, and the checkpoint resumes the rest.
	defaultEraserChunk = 10
	// defaultModlogMax is COMMUNITY_MODLOG_MAX, the cap an OWNER_HANDOVER entry is trimmed to.
	defaultModlogMax = 100
	// exportBatch is the most documents one GetAll of the export reads.
	exportBatch = 100
)

// PurgeResult is what the eraser's transaction for one community did.
type PurgeResult struct {
	// MemberRemoved: the user's member doc existed and was deleted.
	MemberRemoved bool
	// HandedOver: the user owned the community and the first ACTIVE moderator became its owner.
	HandedOver bool
	// Archived: the user owned the community and no moderator could take over, so ownerId was cleared (ARCHIVED unless the community was
	// SUSPENDED, which stays so).
	Archived bool
	// Scrubbed counts the modlog entries that named the user and now read DeletedMarker.
	Scrubbed int
	// Written: the community document was written (a rerun leaves this false and writes nothing).
	Written bool
}

// PurgeParams are the eraser's knobs for one community.
type PurgeParams struct {
	// ModlogMax is COMMUNITY_MODLOG_MAX, applied to the handover log entry.
	ModlogMax int
	// Active reports whether a moderator's account is ACTIVE (identity.Directory, cache-first); a nil func treats nobody as ACTIVE.
	Active func(ctx context.Context, uid string) bool
}

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// LoadMemberships reads communityMemberships/{uid} (1 read, billed when missing too).
	LoadMemberships(ctx context.Context, uid string) (m Memberships, exists bool, err error)
	// PurgeCommunity takes uid out of one community in one transaction; see FirestoreRepo.PurgeCommunity.
	PurgeCommunity(ctx context.Context, uid, communityID string, p PurgeParams) (PurgeResult, error)
	// DeleteMemberships deletes communityMemberships/{uid} (1 delete).
	DeleteMemberships(ctx context.Context, uid string) error
}

var _ PagePurger = (*FirestoreRepo)(nil)

// LoadMemberships implements PagePurger.
func (r *FirestoreRepo) LoadMemberships(ctx context.Context, uid string) (Memberships, bool, error) {
	snap, err := r.membershipsRef(uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Memberships{}, false, nil
		}
		return Memberships{}, false, logger.RedactErr(fmt.Errorf("communities: load memberships %s: %w", logger.HashUID(uid), err), uid)
	}
	var d membershipsDoc
	if err := snap.DataTo(&d); err != nil {
		return Memberships{}, false, logger.RedactErr(fmt.Errorf("communities: decode memberships %s: %w", logger.HashUID(uid), err), uid)
	}
	return d.memberships(), true, nil
}

// DeleteMemberships implements PagePurger.
func (r *FirestoreRepo) DeleteMemberships(ctx context.Context, uid string) error {
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	b.Delete(r.membershipsRef(uid))
	if err := b.Commit(ctx); err != nil {
		return logger.RedactErr(fmt.Errorf("communities: delete memberships %s: %w", logger.HashUID(uid), err), uid)
	}
	return nil
}

// scrub returns the modlog with every entry that names uid (as actor or target) rewritten to DeletedMarker, and how many it changed.
func scrub(log []LogEntry, uid string) ([]LogEntry, int) {
	out := slices.Clone(log)
	n := 0
	for i := range out {
		hit := false
		if out[i].Actor == uid {
			out[i].Actor, hit = DeletedMarker, true
		}
		if out[i].Target == uid {
			out[i].Target, hit = DeletedMarker, true
		}
		if hit {
			n++
		}
	}
	return out, n
}

// PurgeCommunity takes uid out of community cid in ONE transaction (ADR-0031 D9). Reads, fresh: the community, uid's member doc, and,
// when uid owns the community and has moderators, one memberships doc per candidate successor tried (at most 10; the account check is
// identity.Directory, cache-first). It then
//
//   - deletes uid's member doc, and lowers memberCount by one if it was JOINED (a BANNED member never counted);
//   - removes uid from moderatorIds;
//   - for an owned community (F12) hands it to the first ACTIVE uid in moderatorIds (appointment order): it becomes ownerId, leaves
//     moderatorIds, gets the community in its owned and modlogged (a field-level Update of its memberships, which must exist: a
//     moderator whose memberships are gone is being deleted and is skipped), and an OWNER_HANDOVER entry (actor DeletedMarker, target the
//     new owner) is appended; with no such moderator ownerId becomes "" and an ACTIVE community becomes ARCHIVED (a SUSPENDED one stays
//     SUSPENDED; the text stays; no log entry);
//   - rewrites every modlog entry that names uid as actor or target to DeletedMarker.
//
// Writes: one community Update (only when something changes), one delete (the member doc), one memberships Update on a handover. A
// rerun finds nothing that names uid and writes nothing. A community that no longer exists only loses a leftover member doc.
func (r *FirestoreRepo) PurgeCommunity(ctx context.Context, uid, cid string, p PurgeParams) (PurgeResult, error) {
	var res PurgeResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = PurgeResult{}
		c, cerr := r.getInTx(ctx, tx, cid)
		if cerr != nil && !errors.Is(cerr, ErrNotFound) {
			return cerr
		}
		missing := cerr != nil
		msnap, merr := tx.Get(r.memberRef(cid, uid))
		budget.FromContext(ctx).AddReads(1)
		memberState := MemberNone
		if merr == nil {
			var md memberDoc
			if err := msnap.DataTo(&md); err != nil {
				return fmt.Errorf("communities: decode member: %w", err)
			}
			memberState = MemberState(md.State)
		} else if status.Code(merr) != codes.NotFound {
			return fmt.Errorf("communities: get member: %w", merr)
		}
		owned := !missing && c.OwnerID == uid
		successor := ""
		if owned && p.Active != nil {
			for _, m := range c.ModeratorIDs {
				if m == uid || !p.Active(ctx, m) {
					continue
				}
				_, serr := tx.Get(r.membershipsRef(m))
				budget.FromContext(ctx).AddReads(1)
				if serr != nil {
					if status.Code(serr) == codes.NotFound {
						continue
					}
					return fmt.Errorf("communities: get successor memberships: %w", serr)
				}
				successor = m
				break
			}
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		if merr == nil {
			b.Delete(r.memberRef(cid, uid), firestore.Exists)
			res.MemberRemoved = true
		}
		if !missing {
			var updates []firestore.Update
			if memberState == MemberJoined {
				updates = append(updates, firestore.Update{Path: "memberCount", Value: firestore.Increment(-1)})
			}
			mods := slices.Clone(c.ModeratorIDs)
			modsChanged := false
			if i := slices.Index(mods, uid); i >= 0 {
				mods = slices.Delete(mods, i, i+1)
				modsChanged = true
			}
			log, n := scrub(c.Modlog, uid)
			res.Scrubbed = n
			logChanged := n > 0
			seq := c.ModlogSeq
			now := r.now().UTC()
			switch {
			case owned && successor != "":
				mods = slices.DeleteFunc(mods, func(m string) bool { return m == successor })
				modsChanged = true
				seq++
				log = append(log, LogEntry{Seq: seq, At: now, Actor: DeletedMarker, Action: ActionOwnerHandover, Target: successor})
				if p.ModlogMax > 0 && len(log) > p.ModlogMax {
					log = slices.Clone(log[len(log)-p.ModlogMax:])
				}
				logChanged = true
				updates = append(updates, firestore.Update{Path: "ownerId", Value: successor})
				b.Update(r.membershipsRef(successor), []firestore.Update{
					{Path: "owned", Value: firestore.ArrayUnion(cid)},
					{Path: "modlogged", Value: firestore.ArrayUnion(cid)},
					{Path: "updatedAt", Value: now},
				})
				res.HandedOver = true
			case owned:
				updates = append(updates, firestore.Update{Path: "ownerId", Value: ""})
				if c.Status == StatusActive {
					updates = append(updates, firestore.Update{Path: "status", Value: string(StatusArchived)})
				}
				res.Archived = true
			}
			if modsChanged {
				updates = append(updates, firestore.Update{Path: "moderatorIds", Value: nonNil(mods)})
			}
			if logChanged {
				updates = append(updates,
					firestore.Update{Path: "modlog", Value: logDocs(log)},
					firestore.Update{Path: "modlogSeq", Value: seq})
			}
			if len(updates) > 0 {
				updates = append(updates, firestore.Update{Path: "updatedAt", Value: now})
				b.Update(r.ref(cid), updates)
				res.Written = true
			}
		}
		return b.Err()
	})
	noteAttempts(ctx, attempts)
	if err != nil {
		return PurgeResult{}, logger.RedactErr(fmt.Errorf("communities: purge %s: %w", logger.HashUID(uid), err), uid, cid)
	}
	return res, nil
}

// Checkpoint resumes Eraser.PurgeUser across calls. The zero value starts from the beginning. After is the last community id the
// step finished, in the sorted order of the union of the user's memberships (ids are fixed-width Snowflakes, so sorted = oldest first);
// the counts are for logging only. It is the step's own type: the step name is persisted in deletionJob.step.
type Checkpoint struct {
	After       string `json:"after,omitempty"`
	Communities int    `json:"communities,omitempty"`
	Handovers   int    `json:"handovers,omitempty"`
	Archived    int    `json:"archived,omitempty"`
}

// Eraser is the `communities` account-deletion step (ADR-0031 D9): BeforeIdentity, resumable, idempotent, never flag-gated.
type Eraser struct {
	repo      PagePurger
	dir       identity.Directory
	chunk     int
	modlogMax int
}

// EraserOption tunes an Eraser.
type EraserOption func(*Eraser)

// WithChunk sets the most communities one invocation handles (default 10); the tests use 1 to exercise a resume.
func WithChunk(n int) EraserOption {
	return func(e *Eraser) {
		if n > 0 {
			e.chunk = n
		}
	}
}

// WithModlogMax sets COMMUNITY_MODLOG_MAX for the handover entry (default 100).
func WithModlogMax(n int) EraserOption {
	return func(e *Eraser) {
		if n > 0 {
			e.modlogMax = n
		}
	}
}

// NewEraser builds the step on a PagePurger (FirestoreRepo in production) and the directory that tells whether a moderator may take
// over (cache-first, 60 s stale; an account that is not ACTIVE is never chosen).
func NewEraser(repo PagePurger, dir identity.Directory, opts ...EraserOption) *Eraser {
	e := &Eraser{repo: repo, dir: dir, chunk: defaultEraserChunk, modlogMax: defaultModlogMax}
	for _, o := range opts {
		o(e)
	}
	return e
}

// union is joined ∪ owned ∪ banned ∪ modlogged, de-duplicated and sorted: every community that can hold the user's uid (I-M, I-L).
func (m Memberships) union() []string {
	all := make([]string, 0, len(m.Joined)+len(m.Owned)+len(m.Banned)+len(m.Modlogged))
	all = append(all, m.Joined...)
	all = append(all, m.Owned...)
	all = append(all, m.Banned...)
	all = append(all, m.Modlogged...)
	slices.Sort(all)
	return slices.Compact(all)
}

func (e *Eraser) active(ctx context.Context, uid string) bool {
	if e.dir == nil {
		return false
	}
	profs, err := e.dir.GetProfiles(ctx, []string{uid})
	if err != nil {
		return false // an unreadable account is not chosen; the next candidate is
	}
	p, ok := profs[uid]
	return ok && p.Status == identity.AccountStatusActive
}

// PurgeUser runs up to one chunk of communities and reports whether the step is finished. It reads the memberships doc once (1
// read), then each community in its own transaction (2 reads, plus the successor checks of an owned one), and when the last community
// is done deletes the memberships doc. An account with no memberships doc is one read and no writes, and so is a rerun after
// completion. Reads: 1 + 2 per community (+ at most 10 profiles and 10 memberships reads per owned community with moderators); writes:
// 1 per community that changed (+1 on a handover); deletes: 1 per member doc + 1 for the memberships doc.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	ms, exists, err := e.repo.LoadMemberships(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	if !exists {
		slog.InfoContext(ctx, "account_job", "step", "communities", "uid_hash", logger.HashUID(uid), "memberships", 0, "handovers", cp.Handovers, "archived", cp.Archived)
		return cp, true, nil
	}
	list := ms.union()
	start, _ := slices.BinarySearch(list, cp.After)
	if start < len(list) && list[start] == cp.After && cp.After != "" {
		start++
	}
	end := min(start+e.chunk, len(list))
	next := cp
	for _, cid := range list[start:end] {
		res, err := e.repo.PurgeCommunity(ctx, uid, cid, PurgeParams{ModlogMax: e.modlogMax, Active: e.active})
		if err != nil {
			return cp, false, err
		}
		next.After = cid
		next.Communities++
		if res.HandedOver {
			next.Handovers++
		}
		if res.Archived {
			next.Archived++
		}
	}
	done := end >= len(list)
	if done {
		if err := e.repo.DeleteMemberships(ctx, uid); err != nil {
			return cp, false, err
		}
	}
	slog.InfoContext(ctx, "account_job", "step", "communities", "uid_hash", logger.HashUID(uid), "memberships", next.Communities,
		"handovers", next.Handovers, "archived", next.Archived, "done", done)
	return next, done, nil
}

// ---- export ----

// ExportSource reads what the export section needs (FirestoreRepo in production).
type ExportSource interface {
	// LoadMemberships reads communityMemberships/{uid} (1 read).
	LoadMemberships(ctx context.Context, uid string) (m Memberships, exists bool, err error)
	// ExportRows reads, in batches of at most 100 references, the community doc of every id and the user's own member doc of every
	// id in withMember. Reads: one per document requested (a missing one is billed too). Rows come back in the order of ids.
	ExportRows(ctx context.Context, uid string, ids, withMember []string) ([]ExportRow, error)
}

var _ ExportSource = (*FirestoreRepo)(nil)

// ExportRow is one community of the export: Exists is false when the community doc is gone; MemberState and MemberAt describe the
// user's own member doc (MemberNone when there is none; MemberAt is its joinedAt or bannedAt).
type ExportRow struct {
	Community   Community
	Exists      bool
	MemberState MemberState
	MemberAt    time.Time
}

// ExportRows implements ExportSource.
func (r *FirestoreRepo) ExportRows(ctx context.Context, uid string, ids, withMember []string) ([]ExportRow, error) {
	rows := make([]ExportRow, len(ids))
	byID := make(map[string]int, len(ids))
	var refs []*firestore.DocumentRef
	kind := []int{} // 0 = community doc, 1 = member doc, per ref
	for i, id := range ids {
		byID[id] = i
		refs = append(refs, r.ref(id))
		kind = append(kind, 0)
	}
	for _, id := range withMember {
		refs = append(refs, r.memberRef(id, uid))
		kind = append(kind, 1)
	}
	for from := 0; from < len(refs); from += exportBatch {
		to := min(from+exportBatch, len(refs))
		snaps, err := r.client.GetAll(ctx, refs[from:to])
		budget.FromContext(ctx).AddReads(int64(to - from))
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("communities: export %s: %w", logger.HashUID(uid), err), append([]string{uid}, ids...)...)
		}
		for j, snap := range snaps {
			if !snap.Exists() {
				continue
			}
			if kind[from+j] == 0 {
				var d communityDoc
				if err := snap.DataTo(&d); err != nil {
					return nil, logger.RedactErr(fmt.Errorf("communities: export decode: %w", err), uid, snap.Ref.ID)
				}
				i := byID[snap.Ref.ID]
				rows[i].Community, rows[i].Exists = d.community(snap.Ref.ID), true
				continue
			}
			var md memberDoc
			if err := snap.DataTo(&md); err != nil {
				return nil, logger.RedactErr(fmt.Errorf("communities: export decode member: %w", err), uid, snap.Ref.Parent.Parent.ID)
			}
			i := byID[snap.Ref.Parent.Parent.ID]
			rows[i].MemberState = MemberState(md.State)
			switch {
			case md.JoinedAt != nil:
				rows[i].MemberAt = md.JoinedAt.UTC()
			case md.BannedAt != nil:
				rows[i].MemberAt = md.BannedAt.UTC()
			}
		}
	}
	return rows, nil
}

// ExportedRule, ExportedJoined, ExportedOwned, ExportedBanned and ExportedAction are the rows of the `communities` export section.
type (
	// ExportedRule is one rule of an owned community.
	ExportedRule struct {
		Title string `json:"title"`
		Text  string `json:"text"`
	}
	// ExportedJoined is a community the user is a member of; Role is OWNER, MODERATOR or MEMBER.
	ExportedJoined struct {
		CommunityID string     `json:"communityId"`
		Name        string     `json:"name"`
		Role        string     `json:"role"`
		JoinedAt    *time.Time `json:"joinedAt,omitempty"`
	}
	// ExportedOwned is a community the user owns, with the text they wrote.
	ExportedOwned struct {
		CommunityID string         `json:"communityId"`
		Name        string         `json:"name"`
		Description string         `json:"description"`
		Rules       []ExportedRule `json:"rules"`
		CreatedAt   time.Time      `json:"createdAt"`
	}
	// ExportedBanned is a community the user is banned from.
	ExportedBanned struct {
		CommunityID string     `json:"communityId"`
		Name        string     `json:"name"`
		BannedAt    *time.Time `json:"bannedAt,omitempty"`
	}
	// ExportedAction is one entry of a moderation log where the user was the actor: the action and its time, never a target or a post.
	ExportedAction struct {
		CommunityID string    `json:"communityId"`
		Action      string    `json:"action"`
		At          time.Time `json:"at"`
	}
)

// Export is the `communities` section (ADR-0031 D9). No other user's uid appears in it: no moderator ids, no log targets.
type Export struct {
	Joined            []ExportedJoined `json:"joined"`
	Owned             []ExportedOwned  `json:"owned"`
	Banned            []ExportedBanned `json:"banned"`
	ModerationActions []ExportedAction `json:"moderationActions"`
	// RedactedCount is how many of the user's communities are left out because they are SUSPENDED (and not the user's own) or gone;
	// it does not say which cause applied.
	RedactedCount int `json:"redactedCount"`
}

// Exporter writes the `communities` export section.
type Exporter struct{ src ExportSource }

// NewExporter builds the section on an ExportSource (FirestoreRepo in production).
func NewExporter(src ExportSource) *Exporter { return &Exporter{src: src} }

// BuildExport assembles the section. Reads: 1 (memberships) + 1 per community in joined ∪ owned ∪ banned ∪ modlogged + 1 per joined
// or banned community (the user's member doc, which carries joinedAt and bannedAt); an account without a memberships doc is 1 read.
func (x *Exporter) BuildExport(ctx context.Context, uid string) (Export, error) {
	out := Export{Joined: []ExportedJoined{}, Owned: []ExportedOwned{}, Banned: []ExportedBanned{}, ModerationActions: []ExportedAction{}}
	ms, exists, err := x.src.LoadMemberships(ctx, uid)
	if err != nil {
		return Export{}, err
	}
	if !exists {
		return out, nil
	}
	list := ms.union()
	withMember := slices.Clone(ms.Joined)
	withMember = append(withMember, ms.Banned...)
	slices.Sort(withMember)
	withMember = slices.Compact(withMember)
	rows, err := x.src.ExportRows(ctx, uid, list, withMember)
	if err != nil {
		return Export{}, err
	}
	for i, cid := range list {
		row := rows[i]
		c := row.Community
		if !row.Exists || (c.Status == StatusSuspended && c.OwnerID != uid) {
			out.RedactedCount++
			continue
		}
		if slices.Contains(ms.Joined, cid) {
			j := ExportedJoined{CommunityID: cid, Name: c.Name, Role: "MEMBER"}
			switch c.RoleOf(uid) {
			case RoleOwner:
				j.Role = "OWNER"
			case RoleModerator:
				j.Role = "MODERATOR"
			}
			if row.MemberState == MemberJoined && !row.MemberAt.IsZero() {
				at := row.MemberAt
				j.JoinedAt = &at
			}
			out.Joined = append(out.Joined, j)
		}
		if c.OwnerID == uid {
			o := ExportedOwned{CommunityID: cid, Name: c.Name, Description: c.Description, Rules: []ExportedRule{}, CreatedAt: c.CreatedAt.UTC()}
			for _, r := range c.Rules {
				o.Rules = append(o.Rules, ExportedRule(r))
			}
			out.Owned = append(out.Owned, o)
		}
		if slices.Contains(ms.Banned, cid) {
			bn := ExportedBanned{CommunityID: cid, Name: c.Name}
			if row.MemberState == MemberBanned && !row.MemberAt.IsZero() {
				at := row.MemberAt
				bn.BannedAt = &at
			}
			out.Banned = append(out.Banned, bn)
		}
		for _, e := range c.Modlog {
			if e.Actor == uid {
				out.ModerationActions = append(out.ModerationActions, ExportedAction{CommunityID: cid, Action: e.Action, At: e.At.UTC()})
			}
		}
	}
	return out, nil
}

// ExportUser writes the section as one JSON value to w. Reads as BuildExport.
func (x *Exporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	e, err := x.BuildExport(ctx, uid)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(w).Encode(e); err != nil {
		return fmt.Errorf("communities: write export: %w", err)
	}
	return nil
}
