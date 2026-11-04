package communities

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// communitiesCollection, membersSubcollection and membershipsCollection are the collections this module owns.
	// Only communities.FirestoreRepo touches them. Each has a row (apiserver/lifecycle_collections_guard_test.go), the
	// `communities` eraser step and the `communities` export section. The subcollection is named communityMembers, not
	// members: the name scan and the residue sweep key on the collection id (D2).
	communitiesCollection   = "communities"
	membersSubcollection    = "communityMembers"
	membershipsCollection   = "communityMemberships"
	rpcCreateCommunity      = "CreateCommunity"
	rpcUpdateCommunity      = "UpdateCommunity"
	txTimeout               = 5 * time.Second
	maxTxRuns               = 3
	txBackoff               = 20 * time.Millisecond
	fieldCommunityTxn       = "community_txn_attempts"
	eventCommunityContended = "communities_txn_contention"
)

// ruleDoc is one element of communities/{cid}.rules.
type ruleDoc struct {
	Title string `firestore:"title"`
	Text  string `firestore:"text"`
}

// logDoc is one element of communities/{cid}.modlog (D2). target and postId are absent when not applicable.
type logDoc struct {
	Seq    int64     `firestore:"seq"`
	At     time.Time `firestore:"at"`
	Actor  string    `firestore:"actor"`
	Action string    `firestore:"action"`
	Target string    `firestore:"target,omitempty"`
	PostID string    `firestore:"postId,omitempty"`
}

// removalDoc is one element of communities/{cid}.recentRemovals.
type removalDoc struct {
	PostID string    `firestore:"postId"`
	At     time.Time `firestore:"at"`
}

// communityDoc is communities/{cid}. Every array is written as an array, never null. removalsTruncatedAt is absent
// until a cap first drops an entry.
type communityDoc struct {
	Name                string       `firestore:"name"`
	Description         string       `firestore:"description"`
	Rules               []ruleDoc    `firestore:"rules"`
	OwnerID             string       `firestore:"ownerId"`
	ModeratorIDs        []string     `firestore:"moderatorIds"`
	MemberCount         int64        `firestore:"memberCount"`
	Status              string       `firestore:"status"`
	Visibility          string       `firestore:"visibility"`
	RecentRemovals      []removalDoc `firestore:"recentRemovals"`
	RemovalsTruncatedAt *time.Time   `firestore:"removalsTruncatedAt,omitempty"`
	Modlog              []logDoc     `firestore:"modlog"`
	ModlogSeq           int64        `firestore:"modlogSeq"`
	CreatedAt           time.Time    `firestore:"createdAt"`
	UpdatedAt           time.Time    `firestore:"updatedAt"`
}

// memberDoc is communities/{cid}/communityMembers/{uid} (D2): state is JOINED or BANNED, never a role; joinedAt (JOINED) or bannedAt
// (BANNED) is present only in its state, and its presence is the member page's filter.
type memberDoc struct {
	UID      string     `firestore:"uid"`
	State    string     `firestore:"state"`
	JoinedAt *time.Time `firestore:"joinedAt,omitempty"`
	BannedAt *time.Time `firestore:"bannedAt,omitempty"`
}

// membershipsDoc is communityMemberships/{uid} (D2).
type membershipsDoc struct {
	Joined    []string  `firestore:"joined"`
	Owned     []string  `firestore:"owned"`
	Banned    []string  `firestore:"banned"`
	Modlogged []string  `firestore:"modlogged"`
	UpdatedAt time.Time `firestore:"updatedAt"`
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func (d membershipsDoc) memberships() Memberships {
	return Memberships{Joined: slices.Clone(d.Joined), Owned: slices.Clone(d.Owned), Banned: slices.Clone(d.Banned), Modlogged: slices.Clone(d.Modlogged)}
}

func (d communityDoc) community(id string) Community {
	c := Community{
		ID: id, Name: d.Name, Description: d.Description, OwnerID: d.OwnerID, ModeratorIDs: slices.Clone(d.ModeratorIDs),
		MemberCount: d.MemberCount, Status: Status(d.Status), Visibility: d.Visibility, ModlogSeq: d.ModlogSeq,
		CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt,
	}
	for _, r := range d.Rules {
		c.Rules = append(c.Rules, Rule(r))
	}
	for _, r := range d.RecentRemovals {
		c.RecentRemovals = append(c.RecentRemovals, Removal(r))
	}
	if d.RemovalsTruncatedAt != nil {
		c.RemovalsTruncatedAt = *d.RemovalsTruncatedAt
	}
	for _, e := range d.Modlog {
		c.Modlog = append(c.Modlog, LogEntry(e))
	}
	return c
}

func ruleDocs(rules []Rule) []ruleDoc {
	out := make([]ruleDoc, len(rules))
	for i, r := range rules {
		out[i] = ruleDoc(r)
	}
	return out
}

func logDocs(entries []LogEntry) []logDoc {
	out := make([]logDoc, len(entries))
	for i, e := range entries {
		out[i] = logDoc(e)
	}
	return out
}

// FirestoreRepo is the Firestore implementation of Repo, and the page source of the eraser and the exporter.
type FirestoreRepo struct {
	client *firestore.Client
	idem   *idempotency.Store
	quotas *quota.Store
	now    func() time.Time
	// moderator is the posts-side seam of Hide and Restore (A12).
	moderator PostModerator
	// hidden is the posts-side listing and restore of the platform recovery (D14a, opsctl only).
	hidden HiddenPosts
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repository on the process's one Firestore client. idem is the shared idempotency store; a repo built
// without it (the lifecycle tests) can still erase and export.
func NewFirestoreRepo(client *firestore.Client, idem *idempotency.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, idem: idem, quotas: quota.New(client), now: time.Now}
}

func (r *FirestoreRepo) col() *firestore.CollectionRef {
	return r.client.Collection(communitiesCollection)
}

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef { return r.col().Doc(id) }

func (r *FirestoreRepo) memberRef(cid, uid string) *firestore.DocumentRef {
	return r.ref(cid).Collection(membersSubcollection).Doc(uid)
}

func (r *FirestoreRepo) membershipsRef(uid string) *firestore.DocumentRef {
	return r.client.Collection(membershipsCollection).Doc(uid)
}

func (r *FirestoreRepo) ready() error {
	if r == nil || r.client == nil || r.idem == nil || r.quotas == nil {
		return errors.New("communities: repo is not fully wired")
	}
	return nil
}

// run is one community transaction with bounded re-runs. A same-key request that committed first leaves AlreadyExists on this
// one's idempotency Create; the transaction is run once more, finds the record and replays it.
func (r *FirestoreRepo) run(ctx context.Context, fn store.TxnFunc) (int, error) {
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, fn)
	if status.Code(err) == codes.AlreadyExists {
		again, err2 := store.RunTransactionRetry(ctx, r.client, cfg, fn)
		return attempts + again, err2
	}
	return attempts, err
}

// noteAttempts records the attempt count on the request line (`community_txn_attempts`, and the shared txn_attempts).
func noteAttempts(ctx context.Context, attempts int) {
	logger.SetRequestField(ctx, fieldCommunityTxn, attempts)
	store.NoteTxnAttempts(ctx, eventCommunityContended, attempts)
}

// putIdem appends the TTL'd idempotency document of rpc, holding the community id only, to b (same atomic unit as the effect).
func (r *FirestoreRepo) putIdem(b store.Batch, uid, key, rpc, hash, communityID string) {
	r.idem.Put(b, key, idempotency.Record{
		UID: uid, RPC: rpc, RequestHash: hash, Result: map[string]string{"id": communityID}, ExpireAt: r.now().UTC().Add(idempotency.TTL),
	})
}

// lookup reads the idempotency document in tx. found with a nil error is a replay; found with ErrKeyReused is a record that
// belongs to another request body; not found means the caller proceeds.
func (r *FirestoreRepo) lookup(ctx context.Context, tx *firestore.Transaction, key, hash string) (rec idempotency.Record, found bool, err error) {
	rec, err = r.idem.Get(ctx, tx, key)
	switch {
	case err == nil:
		if rec.RequestHash != hash {
			return rec, true, ErrKeyReused
		}
		return rec, true, nil
	case errors.Is(err, idempotency.ErrNotFound):
		return rec, false, nil
	default:
		return rec, false, fmt.Errorf("communities: idempotency lookup: %w", err)
	}
}

// getInTx reads communities/{id} inside tx and decodes it, or ErrNotFound when it is missing.
func (r *FirestoreRepo) getInTx(ctx context.Context, tx *firestore.Transaction, id string) (Community, error) {
	snap, err := tx.Get(r.ref(id))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Community{}, ErrNotFound
		}
		return Community{}, fmt.Errorf("communities: get community: %w", err)
	}
	var d communityDoc
	if err := snap.DataTo(&d); err != nil {
		return Community{}, fmt.Errorf("communities: decode community: %w", err)
	}
	return d.community(id), nil
}

// replay answers a replay from the community as it is now (the record holds the id only): a fresh read in tx. A community that is gone
// or SUSPENDED since is the one ErrNotFound.
func (r *FirestoreRepo) replay(ctx context.Context, tx *firestore.Transaction, rec idempotency.Record) (Community, error) {
	id := rec.Result["id"]
	if id == "" {
		return Community{}, ErrNotFound
	}
	c, err := r.getInTx(ctx, tx, id)
	if err != nil {
		return Community{}, err
	}
	if c.Status == StatusSuspended {
		return Community{}, ErrNotFound
	}
	return c, nil
}

// membershipsInTx reads communityMemberships/{uid} inside tx. A missing doc is empty memberships.
func (r *FirestoreRepo) membershipsInTx(ctx context.Context, tx *firestore.Transaction, uid string) (m Memberships, exists bool, err error) {
	snap, err := tx.Get(r.membershipsRef(uid))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Memberships{}, false, nil
		}
		return Memberships{}, false, fmt.Errorf("communities: get memberships: %w", err)
	}
	var d membershipsDoc
	if err := snap.DataTo(&d); err != nil {
		return Memberships{}, false, fmt.Errorf("communities: decode memberships: %w", err)
	}
	return d.memberships(), true, nil
}

// Create implements Repo: one transaction. Reads, fresh and in this order: idempotency/{hash} (a replay
// returns after reading the community), communityMemberships/{uid} (the owned and joined caps are exact). Writes: Create the
// community (ACTIVE, PUBLIC, memberCount 1), Create the owner's member doc (JOINED), the memberships doc (owned and joined += id) and
// Create the idempotency document. At either cap nothing is written. No quota (the owned cap is lifetime).
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if err := r.ready(); err != nil {
		return CreateResult{}, err
	}
	var res CreateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = CreateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				c, rerr := r.replay(ctx, tx, rec)
				if rerr != nil {
					return rerr
				}
				res = CreateResult{Outcome: Replayed, Community: c}
			}
			return err
		}
		ms, exists, err := r.membershipsInTx(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		if len(ms.Owned) >= p.MaxOwned {
			return ErrOwnedLimit
		}
		if len(ms.Joined) >= p.MaxJoined {
			return ErrJoinedLimit
		}
		now := r.now().UTC()
		doc := communityDoc{
			Name: p.Name, Description: p.Description, Rules: ruleDocs(p.Rules), OwnerID: p.UID, ModeratorIDs: []string{},
			MemberCount: 1, Status: string(StatusActive), Visibility: VisibilityPublic, RecentRemovals: []removalDoc{},
			Modlog: []logDoc{}, ModlogSeq: 0, CreatedAt: now, UpdatedAt: now,
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Create(r.ref(p.ID), doc)
		b.Create(r.memberRef(p.ID, p.UID), memberDoc{UID: p.UID, State: string(MemberJoined), JoinedAt: &now})
		if exists {
			b.Update(r.membershipsRef(p.UID), []firestore.Update{
				{Path: "owned", Value: append(slices.Clone(ms.Owned), p.ID)},
				{Path: "joined", Value: append(slices.Clone(ms.Joined), p.ID)},
				{Path: "updatedAt", Value: now},
			})
		} else {
			b.Create(r.membershipsRef(p.UID), membershipsDoc{
				Joined: []string{p.ID}, Owned: []string{p.ID}, Banned: []string{}, Modlogged: []string{}, UpdatedAt: now,
			})
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcCreateCommunity, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = CreateResult{Outcome: Written, Community: doc.community(p.ID)}
		return nil
	})
	noteAttempts(ctx, attempts)
	return res, err
}

func sameRules(a, b []Rule) bool { return slices.Equal(a, b) }

// Update implements Repo: one transaction. Reads, fresh: idempotency (a replay returns after reading the community), the
// community, and, only when something changes, the owner's memberships (the first log entry that names the owner adds the community to
// modlogged, I-L). A missing or SUSPENDED community is ErrNotFound, then a caller who is not the owner is ErrNotOwner, then an ARCHIVED
// community is ErrArchived; nothing is written and an error is not recorded. A request that changes nothing writes only the
// idempotency document. Otherwise the community changes through one field-level Update (name, description, rules, an EDIT log entry
// with the next seq, trimmed to ModlogMax, modlogSeq, updatedAt).
func (r *FirestoreRepo) Update(ctx context.Context, p UpdateParams) (UpdateResult, error) {
	if err := r.ready(); err != nil {
		return UpdateResult{}, err
	}
	var res UpdateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = UpdateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				c, rerr := r.replay(ctx, tx, rec)
				if rerr != nil {
					return rerr
				}
				res = UpdateResult{Outcome: Replayed, Community: c}
			}
			return err
		}
		c, err := r.getInTx(ctx, tx, p.ID)
		if err != nil {
			return err
		}
		if c.Status == StatusSuspended {
			return ErrNotFound
		}
		if c.OwnerID == "" || c.OwnerID != p.UID {
			return ErrNotOwner
		}
		if c.Status == StatusArchived {
			return ErrArchived
		}
		var updates []firestore.Update
		next := c
		if p.Name != nil && *p.Name != c.Name {
			updates = append(updates, firestore.Update{Path: "name", Value: *p.Name})
			next.Name = *p.Name
		}
		if p.Description != nil && *p.Description != c.Description {
			updates = append(updates, firestore.Update{Path: "description", Value: *p.Description})
			next.Description = *p.Description
		}
		if p.Rules != nil && !sameRules(*p.Rules, c.Rules) {
			updates = append(updates, firestore.Update{Path: "rules", Value: ruleDocs(*p.Rules)})
			next.Rules = slices.Clone(*p.Rules)
		}
		b := store.NewFirestoreTxBatch(tx)
		outcome := Unchanged
		if len(updates) > 0 {
			ms, exists, merr := r.membershipsInTx(ctx, tx, p.UID)
			if merr != nil {
				return merr
			}
			now := r.now().UTC()
			entry := LogEntry{Seq: c.ModlogSeq + 1, At: now, Actor: p.UID, Action: ActionEdit}
			next.Modlog = append(slices.Clone(c.Modlog), entry)
			if p.ModlogMax > 0 && len(next.Modlog) > p.ModlogMax {
				next.Modlog = slices.Clone(next.Modlog[len(next.Modlog)-p.ModlogMax:])
			}
			next.ModlogSeq, next.UpdatedAt = entry.Seq, now
			updates = append(updates,
				firestore.Update{Path: "modlog", Value: logDocs(next.Modlog)},
				firestore.Update{Path: "modlogSeq", Value: next.ModlogSeq},
				firestore.Update{Path: "updatedAt", Value: now})
			b.Update(r.ref(p.ID), updates)
			switch {
			case !exists:
				b.Create(r.membershipsRef(p.UID), membershipsDoc{
					Joined: []string{}, Owned: []string{p.ID}, Banned: []string{}, Modlogged: []string{p.ID}, UpdatedAt: now,
				})
			case !containsString(ms.Modlogged, p.ID):
				b.Update(r.membershipsRef(p.UID), []firestore.Update{
					{Path: "modlogged", Value: firestore.ArrayUnion(p.ID)},
					{Path: "updatedAt", Value: now},
				})
			}
			outcome = Written
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcUpdateCommunity, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = UpdateResult{Outcome: outcome, Community: next}
		return nil
	})
	noteAttempts(ctx, attempts)
	return res, err
}

// Get implements Repo: one point read of communities/{id}, outside any transaction.
func (r *FirestoreRepo) Get(ctx context.Context, id string) (Community, error) {
	if r == nil || r.client == nil {
		return Community{}, errors.New("communities: repo has no firestore client")
	}
	snap, err := r.ref(id).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Community{}, ErrNotFound
		}
		return Community{}, logger.RedactErr(fmt.Errorf("communities: get community: %w", err), id)
	}
	var d communityDoc
	if err := snap.DataTo(&d); err != nil {
		return Community{}, logger.RedactErr(fmt.Errorf("communities: decode community: %w", err), id)
	}
	return d.community(snap.Ref.ID), nil
}

// Member implements Repo: one point read of the member doc.
func (r *FirestoreRepo) Member(ctx context.Context, communityID, uid string) (MemberState, error) {
	if r == nil || r.client == nil {
		return MemberNone, errors.New("communities: repo has no firestore client")
	}
	snap, err := r.memberRef(communityID, uid).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return MemberNone, nil
		}
		return MemberNone, logger.RedactErr(fmt.Errorf("communities: get member: %w", err), communityID, uid)
	}
	var d memberDoc
	if err := snap.DataTo(&d); err != nil {
		return MemberNone, logger.RedactErr(fmt.Errorf("communities: decode member: %w", err), communityID, uid)
	}
	switch MemberState(d.State) {
	case MemberJoined, MemberBanned:
		return MemberState(d.State), nil
	}
	return MemberNone, nil
}
