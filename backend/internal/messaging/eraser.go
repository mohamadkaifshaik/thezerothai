package messaging

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Phases of one conversation's erasure. The zero phase picks the next conversation and marks it gone.
const (
	phaseTombstone = "tombstone"
	phaseFinish    = "finish"
	phaseTree      = "tree"
)

// Checkpoint resumes the `messaging` account-deletion step across calls (ADR-0027 D8). It is the step's own type: step
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
	// Counters for the final log line.
	Conversations  int `json:"conversations,omitempty"`
	Tombstoned     int `json:"tombstoned,omitempty"`
	EntriesDeleted int `json:"entriesDeleted,omitempty"`
}

// Purger is the storage side of the eraser (FirestoreRepo in production). Each method is one bounded unit of work.
type Purger interface {
	NextConversation(ctx context.Context, uid, after string) (id string, found bool, err error)
	MarkGone(ctx context.Context, uid, convID string) (goneResult, error)
	TombstonePage(ctx context.Context, uid, convID, after string) (last string, tombstoned int, full bool, err error)
	DeleteEntry(ctx context.Context, uid, convID, folder string) error
	DeleteTreePage(ctx context.Context, convID string) (deleted int, done bool, err error)
}

var _ Purger = (*FirestoreRepo)(nil)

type eraser struct {
	repo Purger
	log  *slog.Logger
}

// NewEraser builds the `messaging` step on a Purger. It is never flag-gated: documents outlive the flag (right to
// delete, ADR-0011).
func NewEraser(repo Purger, log *slog.Logger) Eraser {
	if log == nil {
		log = slog.Default()
	}
	return &eraser{repo: repo, log: log}
}

// PurgeUser implements Eraser: the account-deletion step `messaging` (ADR-0027 D8), registered BeforeIdentity after
// `follow_requests`. Resumable, one bounded unit of work per call (at most 500 documents), the checkpoint is opaque JSON
// (Checkpoint). For each conversation of the user, in __name__ order:
//
//  1. mark it gone (the user's uid joins `gone`, in the transaction that also rewrites the peer's entry to the
//     "Deleted account" placeholder, snippet "Message deleted" when the user's message was the last), so no send can
//     rewrite the deleted user's entries afterwards;
//  2. tombstone the user's messages, 500 per call (text cleared, state DELETED_ACCOUNT; the peer's own messages stay);
//  3. delete the user's own dmInbox or dmRequests entry;
//  4. when the peer is gone too, delete the whole tree: the messages 500 per call, then the conversation document.
//
// Cost for the reference account (20 conversations, 300 own messages, peers alive): about 360 reads (21 cursor queries,
// 20 conversation and 20 peer-entry reads in the transactions, 300 messages), 340 writes (20 gone marks, 20 peer
// entries, 300 tombstones), 20 deletes. Every step is idempotent: a call repeated after a crash re-does at most one
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
		if cp.Both {
			cp.Phase = phaseTree
		} else {
			cp = finishConversation(cp)
		}
	case phaseTree:
		_, done, err := e.repo.DeleteTreePage(ctx, cp.Conv)
		if err != nil {
			return cp, false, err
		}
		if done {
			cp = finishConversation(cp)
		}
	default:
		return e.next(ctx, uid, cp)
	}
	return cp, false, nil
}

// next picks the next conversation after the cursor and marks it gone. No conversation left is the end of the step.
func (e *eraser) next(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	id, found, err := e.repo.NextConversation(ctx, uid, cp.After)
	if err != nil {
		return cp, false, err
	}
	if !found {
		// The account_job line (identity) carries the step name; this one carries the step's own counters. No peer uid.
		e.log.InfoContext(ctx, "messaging_purge_done", "uid_hash", logger.HashUID(uid), "conversations", cp.Conversations,
			"messages_tombstoned", cp.Tombstoned, "entries_deleted", cp.EntriesDeleted)
		return cp, true, nil
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
