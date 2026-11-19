package messaging

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Phases of the erasure, stored by name in the checkpoint: never rename or reuse one (a checkpoint written by an earlier
// build must resume under this one). The zero phase picks the next conversation and marks it gone; the four after it are
// one conversation's; phaseWelcomes (appended with E2EE plan 3 Task 8) runs once, after the last conversation.
const (
	phaseTombstone = "tombstone"
	phaseFinish    = "finish"
	phaseRewrite   = "rewrite"
	phaseTree      = "tree"
	phaseWelcomes  = "welcomes"
)

// Checkpoint resumes the `messaging` account-deletion step across calls. It is the step's own type: step
// names are persisted in deletionJob.step, so it never joins another module's checkpoint. It holds ids and counters
// only: no uid, no text.
type Checkpoint struct {
	// After is the last conversation fully handled, the cursor of the conversation query.
	After string `json:"after,omitempty"`
	// Conv is the conversation in progress and Phase where it stands; Msg is the last message id seen by the tombstone
	// phase (its cursor). Both says the peer is gone too, so the tree is deleted after this user's part. Entry is the
	// folder of the user's own entry.
	Conv  string `json:"conv,omitempty"`
	Phase string `json:"phase,omitempty"`
	Msg   string `json:"msg,omitempty"`
	Both  bool   `json:"both,omitempty"`
	Entry string `json:"entry,omitempty"`
	// Counters for the final log line. The two E2EE counters are new fields: an older checkpoint decodes them as 0.
	Conversations    int `json:"conversations,omitempty"`
	Tombstoned       int `json:"tombstoned,omitempty"`
	EntriesDeleted   int `json:"entriesDeleted,omitempty"`
	CommitsRewritten int `json:"commitsRewritten,omitempty"`
	WelcomesDeleted  int `json:"welcomesDeleted,omitempty"`
}

// Purger is the storage side of the eraser (FirestoreRepo in production). Each method is one bounded unit of work.
type Purger interface {
	NextConversation(ctx context.Context, uid, after string) (id string, found bool, err error)
	MarkGone(ctx context.Context, uid, convID string) (goneResult, error)
	TombstonePage(ctx context.Context, uid, convID, after string) (last string, tombstoned int, full bool, err error)
	DeleteEntry(ctx context.Context, uid, convID, folder string) error
	RewriteCommitsPage(ctx context.Context, uid, convID string) (rewritten int, err error)
	RewriteConversation(ctx context.Context, uid, convID string) error
	DeleteTreePage(ctx context.Context, convID string) (deleted int, done bool, err error)
	DeleteWelcomesPage(ctx context.Context, uid string) (deleted int, full bool, err error)
}

var _ Purger = (*FirestoreRepo)(nil)

type eraser struct {
	repo Purger
	log  *slog.Logger
}

// NewEraser builds the `messaging` step on a Purger. It is never flag-gated: documents outlive the flag (right to
// delete).
func NewEraser(repo Purger, log *slog.Logger) Eraser {
	if log == nil {
		log = slog.Default()
	}
	return &eraser{repo: repo, log: log}
}

// PurgeUser implements Eraser: the account-deletion step `messaging`, registered BeforeIdentity after
// `follow_requests`. Resumable, one bounded unit of work per call (at most 500 documents), the checkpoint is opaque JSON
// (Checkpoint). For each conversation of the user, in __name__ order:
//
//  1. mark it gone (the user's uid joins `gone`, in the transaction that also rewrites the peer's entry to the
//     "Deleted account" placeholder, snippet "Message deleted" when the user's message was the last), so no send can
//     rewrite the deleted user's entries afterwards;
//  2. tombstone the user's messages, 500 per call (text cleared, state DELETED_ACCOUNT, senderId = DeletedUID; an
//     encrypted one also loses its ciphertext, commitment and ctExpireAt and gets ctRemoved, keeping its pair and mlsKey;
//     the peer's own messages stay);
//  3. delete the user's own dmInbox or dmRequests entry;
//  4. when the peer is gone too, delete the whole tree: the messages and the commit records 500 per call, then the
//     conversation document; otherwise, in the rewrite phase, first replace the uid by DeletedUID in the senderId of the
//     user's commit records (500 per call, until a call finds none), then rewrite the conversation LAST, replacing the uid
//     by DeletedUID in participants, gone, requestFrom and requestTo and dropping its clearedAt and clearedKey entries (the
//     peer's entry got peerId = DeletedUID in step 1).
//
// After the last conversation, the welcomes phase deletes every document under users/{uid}/dmWelcomes, 500 per call. It
// comes last on purpose: by then every conversation of the user has the uid (or DeletedUID) in `gone`, so no commit or
// reset can address one of the user's devices again (a commit to a conversation with a gone participant is refused), and
// nothing can write a welcome behind it. Welcomes the user's own sends left in a peer's inbox stay until their 30-day
// expiry: they hold the peer's device id, the conversation id (a hash), the pair and opaque bytes, no uid of the user.
//
// The order is what makes it resumable: the cursor query finds a conversation through `participants array-contains uid`,
// so that field is the last thing changed. Every earlier step keeps the uid findable and is idempotent; once the
// rewrite commits there is nothing left to do. `gone` keeps blocking sends throughout (the uid first, DeletedUID after),
// and the peer's own eraser still finds the conversation by the peer's uid and sees DeletedUID in `gone`.
//
// Checkpoints written before the E2EE phases existed resume unchanged: no phase was renamed or reordered; the commit
// records' senderId rewrite runs inside the existing rewrite phase (so a checkpoint already at "rewrite" still does it),
// the commit records' delete inside DeleteTreePage (so one already at "tree" still does it), and the welcomes phase is
// entered where the step used to end. What such a build already finished (messages tombstoned without the ciphertext
// blanked, conversations behind its cursor) is not redone.
//
// Every step is idempotent: a call repeated after a crash re-does at most one
// unit of work and never a half-erased conversation.
func (e *eraser) PurgeUser(ctx context.Context, uid string, raw []byte) ([]byte, bool, error) {
	var cp Checkpoint
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &cp); err != nil {
			return nil, false, fmt.Errorf("messaging: decode eraser checkpoint: %w", err)
		}
	}
	next, done, err := e.step(ctx, uid, cp)
	if err != nil {
		return nil, false, err
	}
	out, err := json.Marshal(next)
	if err != nil {
		return nil, false, fmt.Errorf("messaging: encode eraser checkpoint: %w", err)
	}
	return out, done, nil
}

func (e *eraser) step(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	switch cp.Phase {
	case phaseTombstone:
		last, n, full, err := e.repo.TombstonePage(ctx, uid, cp.Conv, cp.Msg)
		if err != nil {
			return cp, false, err
		}
		cp.Tombstoned += n
		cp.Msg = last
		if !full {
			cp.Phase = phaseFinish
		}
	case phaseFinish:
		if err := e.repo.DeleteEntry(ctx, uid, cp.Conv, cp.Entry); err != nil {
			return cp, false, err
		}
		cp.EntriesDeleted++
		cp.Phase = phaseRewrite
		if cp.Both {
			cp.Phase = phaseTree
		}
	case phaseRewrite:
		// First the user's commit records (senderId -> DeletedUID), a page per call while a page finds any: a rewritten
		// record no longer matches, so the phase needs no cursor. Then the conversation, last on purpose: it is found
		// through participants array-contains uid, so replacing the uid there ends the work on it. A crash before this
		// commit finds the conversation again and repeats idempotent steps; a crash after it has nothing left to repeat.
		n, err := e.repo.RewriteCommitsPage(ctx, uid, cp.Conv)
		if err != nil {
			return cp, false, err
		}
		if n > 0 {
			cp.CommitsRewritten += n
			return cp, false, nil
		}
		if err := e.repo.RewriteConversation(ctx, uid, cp.Conv); err != nil {
			return cp, false, err
		}
		cp = finishConversation(cp)
	case phaseTree:
		_, done, err := e.repo.DeleteTreePage(ctx, cp.Conv)
		if err != nil {
			return cp, false, err
		}
		if done {
			cp = finishConversation(cp)
		}
	case phaseWelcomes:
		n, full, err := e.repo.DeleteWelcomesPage(ctx, uid)
		if err != nil {
			return cp, false, err
		}
		cp.WelcomesDeleted += n
		if !full {
			// The account_job line (identity) carries the step name; this one carries the step's own counters. No peer uid.
			e.log.InfoContext(ctx, "messaging_purge_done", "uid_hash", logger.HashUID(uid), "conversations", cp.Conversations,
				"messages_tombstoned", cp.Tombstoned, "entries_deleted", cp.EntriesDeleted,
				"commits_rewritten", cp.CommitsRewritten, "welcomes_deleted", cp.WelcomesDeleted)
			return cp, true, nil
		}
	default:
		return e.next(ctx, uid, cp)
	}
	return cp, false, nil
}

// next picks the next conversation after the cursor and marks it gone. No conversation left moves on to the welcomes
// phase, the end of the step.
func (e *eraser) next(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	id, found, err := e.repo.NextConversation(ctx, uid, cp.After)
	if err != nil {
		return cp, false, err
	}
	if !found {
		cp.Phase = phaseWelcomes
		return cp, false, nil
	}
	g, err := e.repo.MarkGone(ctx, uid, id)
	if err != nil {
		return cp, false, err
	}
	if g.Missing {
		cp.After = id
		return cp, false, nil
	}
	cp.Conv, cp.Both, cp.Entry, cp.Msg = id, g.Both, g.Entry, ""
	cp.Conversations++
	cp.Phase = phaseTombstone
	if g.Both {
		// The tree is deleted whole after this user's entry: the messages need no tombstone.
		cp.Phase = phaseFinish
	}
	return cp, false, nil
}

// finishConversation moves the cursor past the conversation just handled.
func finishConversation(cp Checkpoint) Checkpoint {
	cp.After = cp.Conv
	cp.Conv, cp.Phase, cp.Msg, cp.Entry, cp.Both = "", "", "", "", false
	return cp
}
