package communities

import (
	"context"
	"errors"
	"slices"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	rpcHideCommunityPost    = "HideCommunityPost"
	rpcRestoreCommunityPost = "RestoreCommunityPost"
	rpcSetMemberRole        = "SetMemberRole"
)

var _ ModerationRepo = (*FirestoreRepo)(nil)

// PostModerator is the posts-side seam of Hide and Restore (A12), the identical interface to posts.CommunityModerator: posts never imports
// communities and this package does not import posts, so it uses primitives and *firestore.Transaction only. found=false (no error) is a post
// that is missing, is a REPOST or plain post, is a root not created into cid, or is a reply whose conversationCommunityId is not cid. reply is true for a reply of the conversation (ADR-0031 Amendment 1 D4a, W5-51b): its hide sets communityHidden and communityHiddenAt, a restore deletes both, and ModeratePost writes no recentRemovals entry for it. Also found=false: a post carrying `moderation` (a platform removal). guard is the F16 check (W5-53), called with the post's authorId before any write. apiserver hands posts.NewCommunityModerator to WithPostModerator.
type PostModerator interface {
	SetCommunityListing(ctx context.Context, tx *firestore.Transaction, postID, cid string, listed bool, guard func(authorID string) error) (changed, found, reply bool, err error)
}

// WithPostModerator wires the posts-side moderation seam (apiserver at startup; the integration tests). Without it Hide and Restore fail closed.
func (r *FirestoreRepo) WithPostModerator(m PostModerator) *FirestoreRepo {
	r.moderator = m
	return r
}

// appendLog returns c's modlog with e appended (seq = modlogSeq + 1) and trimmed to the newest max entries, and the new modlogSeq.
func appendLog(c Community, e LogEntry, limit int) ([]LogEntry, int64) {
	if limit <= 0 {
		limit = defaultModlogCap
	}
	e.Seq = c.ModlogSeq + 1
	log := append(slices.Clone(c.Modlog), e)
	if len(log) > limit {
		log = slices.Clone(log[len(log)-limit:])
	}
	return log, e.Seq
}

// logUpdates are the community field updates every modlog append makes; next is updated to match.
func logUpdates(next *Community, now time.Time, log []LogEntry, seq int64) []firestore.Update {
	next.Modlog, next.ModlogSeq, next.UpdatedAt = log, seq, now
	return []firestore.Update{
		{Path: "modlog", Value: logDocs(log)},
		{Path: "modlogSeq", Value: seq},
		{Path: "updatedAt", Value: now},
	}
}

// stageModlogged stages "cid joins uid's modlogged" (I-L) on uid's memberships document, read earlier in the transaction: nothing when it is
// already there, an Update otherwise, a Create when the document is missing. extra are further updates for the same document, which make
// the write needed on their own (a document gets one Update per transaction).
func (r *FirestoreRepo) stageModlogged(b store.Batch, uid, cid string, ms Memberships, exists bool, now time.Time, extra ...firestore.Update) {
	has := slices.Contains(ms.Modlogged, cid)
	switch {
	case !exists:
		doc := membershipsDoc{Joined: []string{}, Owned: []string{}, Banned: []string{}, Modlogged: []string{cid}, UpdatedAt: now}
		for _, u := range extra {
			switch u.Path {
			case "joined":
				doc.Joined = []string{cid}
			case "banned":
				doc.Banned = []string{cid}
			}
		}
		b.Create(r.membershipsRef(uid), doc)
	case !has || len(extra) > 0:
		ups := slices.Clone(extra)
		if !has {
			ups = append(ups, firestore.Update{Path: "modlogged", Value: firestore.ArrayUnion(cid)})
		}
		b.Update(r.membershipsRef(uid), append(ups, firestore.Update{Path: "updatedAt", Value: now}))
	}
}

// openForModeration is the shared head of the moderation transactions: the community fresh (a missing or SUSPENDED one is ErrNotFound).
func (r *FirestoreRepo) openForModeration(ctx context.Context, tx *firestore.Transaction, cid string) (Community, error) {
	c, err := r.getInTx(ctx, tx, cid)
	if err != nil {
		return Community{}, err
	}
	if c.Status == StatusSuspended {
		return Community{}, ErrNotFound
	}
	return c, nil
}

// ModeratePost implements ModerationRepo (ADR-0031 D5, A12). One transaction. Reads, fresh and in this order: idempotency (a replay returns
// here, 1 read), the community (ErrNotFound, then ErrNotModerator for anyone but the owner and moderators, then ErrArchived; nothing is
// written and an error is not recorded), the actor's memberships, and last the post through PostModerator (ErrPostNotFound when
// it was not created into this community and is not a reply of its conversation), then ErrNotOwner when the actor is a moderator (not the owner) and the post's author is the owner or a CURRENT moderator other than the actor (F16, ADR-0031 D4b: the author's current role decides; checked on the one post read, before any write, 0 extra reads); a post with `moderation` set is ErrPostNotFound (L-2). A post already in the wanted state writes the idempotency document only. Otherwise writes 3:
// the post (field-level, in posts), the community (one Update: for a root recentRemovals capped at RemovalsMax with removalsTruncatedAt set from the
// entry the cap drops, the HIDE or RESTORE entry capped at ModlogMax, modlogSeq, updatedAt) and the idempotency document, +1 when the
// community is not yet in the actor's modlogged (A6).
func (r *FirestoreRepo) ModeratePost(ctx context.Context, p ModeratePostParams) (ModeratePostResult, error) {
	if err := r.ready(); err != nil {
		return ModeratePostResult{}, err
	}
	if r.moderator == nil {
		return ModeratePostResult{}, errors.New("communities: repo has no post moderator")
	}
	rpc, action := rpcHideCommunityPost, ActionHide
	if p.Restore {
		rpc, action = rpcRestoreCommunityPost, ActionRestore
	}
	var res ModeratePostResult
	var reply bool
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res, reply = ModeratePostResult{}, false
		if _, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash); found || err != nil {
			if err == nil {
				res = ModeratePostResult{Outcome: Replayed}
			}
			return err
		}
		c, err := r.openForModeration(ctx, tx, p.ID)
		if err != nil {
			return err
		}
		if c.RoleOf(p.UID) == RoleNone {
			return ErrNotModerator
		}
		if c.Status == StatusArchived {
			return ErrArchived
		}
		ms, exists, err := r.membershipsInTx(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		var changed, found bool
		changed, found, reply, err = r.moderator.SetCommunityListing(ctx, tx, p.PostID, p.ID, p.Restore, func(authorID string) error { return actorMayActOn(c, p.UID, authorID) })
		if err != nil {
			return err
		}
		if !found {
			return ErrPostNotFound
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		outcome, next := Unchanged, c
		if changed {
			now := r.now().UTC()
			var ups []firestore.Update
			if !reply { // a reply is never in the feed: no recentRemovals entry, feed tokens untouched (R1)
				next.RecentRemovals, next.RemovalsTruncatedAt = removalsAfter(c, p.PostID, p.Restore, now, p.RemovalsMax)
				ups = append(ups, firestore.Update{Path: "recentRemovals", Value: removalDocs(next.RecentRemovals)})
				if !next.RemovalsTruncatedAt.Equal(c.RemovalsTruncatedAt) {
					ups = append(ups, firestore.Update{Path: "removalsTruncatedAt", Value: next.RemovalsTruncatedAt})
				}
			}
			log, seq := appendLog(c, LogEntry{At: now, Actor: p.UID, Action: action, PostID: p.PostID}, p.ModlogMax)
			b.Update(r.ref(p.ID), append(ups, logUpdates(&next, now, log, seq)...))
			r.stageModlogged(b, p.UID, p.ID, ms, exists, now)
			outcome = Written
		}
		r.putIdem(b, p.UID, p.IdemKey, rpc, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = ModeratePostResult{Outcome: outcome, Community: next, Reply: reply}
		return nil
	})
	noteAttempts(ctx, attempts)
	res.Reply = reply
	return res, err
}

func removalDocs(in []Removal) []removalDoc {
	out := make([]removalDoc, len(in))
	for i, r := range in {
		out[i] = removalDoc(r)
	}
	return out
}

// removalsAfter is recentRemovals after a hide (the post appended as the newest entry, the oldest dropped beyond limit, removalsTruncatedAt
// set to the `at` of the newest dropped entry) or a restore (the post's entry deleted). A hide never leaves two entries for one post.
func removalsAfter(c Community, postID string, restore bool, now time.Time, limit int) ([]Removal, time.Time) {
	if limit <= 0 {
		limit = defaultRecentRemovalsMax
	}
	list := slices.DeleteFunc(slices.Clone(c.RecentRemovals), func(r Removal) bool { return r.PostID == postID })
	truncated := c.RemovalsTruncatedAt
	if restore {
		return list, truncated
	}
	list = append(list, Removal{PostID: postID, At: now})
	if len(list) > limit {
		drop := list[:len(list)-limit]
		if at := drop[len(drop)-1].At; at.After(truncated) {
			truncated = at
		}
		list = slices.Clone(list[len(list)-limit:])
	}
	return list, truncated
}

// SetRole implements ModerationRepo (ADR-0031 D4). One transaction. Reads, fresh and in this order: idempotency (a replay then reads the
// community and the target's member doc), the community (ErrNotFound; then the actor's right to the action: ErrNotModerator for BAN and
// UNBAN, ErrNotOwner for MAKE and REMOVE_MODERATOR; then ErrArchived), the target checks that need no read, the target's member doc, the
// target's memberships and the actor's memberships. Nothing more is read once the request is known to change nothing, and the idempotency
// document is then the only write. A BAN of a JOINED target is one Update of the member doc (state BANNED, bannedAt set, joinedAt deleted);
// of a non-member a Create. Every change appends one log entry to the community's single Update and adds the community to the modlogged of
// the actor and of the target (A6, I-L). Writes: BAN 4, UNBAN 3 + 1 delete, MAKE and REMOVE_MODERATOR 2 to 3, +1 for the actor's first
// entry in this community, worst 5.
func (r *FirestoreRepo) SetRole(ctx context.Context, p SetRoleParams) (SetRoleResult, error) {
	if err := r.ready(); err != nil {
		return SetRoleResult{}, err
	}
	var res SetRoleResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = SetRoleResult{}
		if _, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash); found || err != nil {
			if err != nil {
				return err
			}
			c, cerr := r.openForModeration(ctx, tx, p.ID)
			if cerr != nil {
				return cerr
			}
			st, merr := r.memberInTx(ctx, tx, p.ID, p.Target)
			if merr != nil {
				return merr
			}
			res = SetRoleResult{Outcome: Replayed, Community: c, TargetState: st}
			return nil
		}
		c, err := r.openForModeration(ctx, tx, p.ID)
		if err != nil {
			return err
		}
		actor := c.RoleOf(p.UID)
		ownerOnly := p.Action == RoleActionMakeModerator || p.Action == RoleActionRemoveModerator
		switch {
		case ownerOnly && actor != RoleOwner:
			return ErrNotOwner
		case actor == RoleNone:
			return ErrNotModerator
		}
		if c.Status == StatusArchived {
			return ErrArchived
		}
		targetRole := c.RoleOf(p.Target)
		if !ownerOnly { // BAN, UNBAN: the target is a plain member or a non-member
			switch {
			case targetRole == RoleOwner && actor == RoleOwner:
				return ErrBadTarget
			case targetRole != RoleNone && actor != RoleOwner:
				return ErrNotOwner
			case targetRole == RoleModerator:
				return ErrModeratorTarget
			}
		} else if targetRole == RoleOwner {
			return ErrBadTarget
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		unchanged := func(st MemberState) error {
			r.putIdem(b, p.UID, p.IdemKey, rpcSetMemberRole, p.RequestHash, p.ID)
			if err := b.Err(); err != nil {
				return err
			}
			res = SetRoleResult{Outcome: Unchanged, Community: c, TargetState: st}
			return nil
		}
		// Requests that change nothing, decided before any further read.
		switch {
		case p.Action == RoleActionMakeModerator && targetRole == RoleModerator:
			return unchanged(MemberJoined)
		case p.Action == RoleActionRemoveModerator && targetRole != RoleModerator:
			return unchanged(MemberNone)
		}
		st := MemberNone
		if p.Action != RoleActionRemoveModerator {
			if st, err = r.memberInTx(ctx, tx, p.ID, p.Target); err != nil {
				return err
			}
			switch {
			case p.Action == RoleActionBan && st == MemberBanned, p.Action == RoleActionUnban && st != MemberBanned:
				return unchanged(st)
			case p.Action == RoleActionMakeModerator && st != MemberJoined:
				return ErrBadTarget
			case p.Action == RoleActionMakeModerator && len(c.ModeratorIDs) >= p.MaxModerators:
				return ErrModeratorCap
			}
		}
		tms, texists, err := r.membershipsInTx(ctx, tx, p.Target)
		if err != nil {
			return err
		}
		ams, aexists, err := r.membershipsInTx(ctx, tx, p.UID)
		if err != nil {
			return err
		}
		now := r.now().UTC()
		next := c
		var cups, tups []firestore.Update
		action := ActionBan
		var after MemberState // every case below sets it; default returns
		switch p.Action {
		case RoleActionBan:
			if st == MemberJoined {
				b.Update(r.memberRef(p.ID, p.Target), []firestore.Update{
					{Path: "state", Value: string(MemberBanned)}, {Path: "bannedAt", Value: now}, {Path: "joinedAt", Value: firestore.Delete},
				})
				cups = append(cups, memberCountDelta(-1))
				next.MemberCount--
				tups = append(tups, firestore.Update{Path: "joined", Value: firestore.ArrayRemove(p.ID)})
			} else {
				b.Create(r.memberRef(p.ID, p.Target), memberDoc{UID: p.Target, State: string(MemberBanned), BannedAt: &now})
			}
			tups = append(tups, firestore.Update{Path: "banned", Value: firestore.ArrayUnion(p.ID)})
			after = MemberBanned
		case RoleActionUnban:
			action = ActionUnban
			b.Delete(r.memberRef(p.ID, p.Target), firestore.Exists)
			tups = append(tups, firestore.Update{Path: "banned", Value: firestore.ArrayRemove(p.ID)})
			after = MemberNone
		case RoleActionMakeModerator:
			action = ActionMakeModerator
			cups = append(cups, firestore.Update{Path: "moderatorIds", Value: firestore.ArrayUnion(p.Target)})
			next.ModeratorIDs = append(slices.Clone(c.ModeratorIDs), p.Target)
			after = MemberJoined
		case RoleActionRemoveModerator:
			action = ActionRemoveMod
			cups = append(cups, firestore.Update{Path: "moderatorIds", Value: firestore.ArrayRemove(p.Target)})
			next.ModeratorIDs = slices.DeleteFunc(slices.Clone(c.ModeratorIDs), func(m string) bool { return m == p.Target })
			after = MemberJoined
		default:
			return ErrBadTarget
		}
		log, seq := appendLog(c, LogEntry{At: now, Actor: p.UID, Action: action, Target: p.Target}, p.ModlogMax)
		b.Update(r.ref(p.ID), append(cups, logUpdates(&next, now, log, seq)...))
		r.stageModlogged(b, p.Target, p.ID, tms, texists, now, tups...)
		r.stageModlogged(b, p.UID, p.ID, ams, aexists, now)
		r.putIdem(b, p.UID, p.IdemKey, rpcSetMemberRole, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = SetRoleResult{Outcome: Written, Community: next, TargetState: after}
		return nil
	})
	noteAttempts(ctx, attempts)
	return res, notFoundIfNoDoc(err)
}

// actorMayActOn is the F16 rule (ADR-0031 D4b, founder 2026-11-02): the owner may hide or restore every post; a moderator may act on a post
// whose author is a plain member, a former moderator, a banned or departed user, or the moderator themselves, but never on the owner's post
// or another current moderator's. The author's role is the one in c now (current role decides). An empty authorId is a plain author.
func actorMayActOn(c Community, actor, authorID string) error {
	if c.RoleOf(actor) == RoleOwner || authorID == actor {
		return nil
	}
	if c.RoleOf(authorID) != RoleNone {
		return ErrNotOwner
	}
	return nil
}
