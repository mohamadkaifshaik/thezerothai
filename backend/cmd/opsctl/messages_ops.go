package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// cursorKeyEnv is the environment variable that holds the API's CURSOR_HMAC_KEY (the secret `cursor-hmac-key`). The
// conversation_hash of the request logs is keyed by an HKDF derivation of it (W7-34, L-7); opsctl never takes it as a flag
// (shell history) and never falls back to the local development key.
const cursorKeyEnv = "CURSOR_HMAC_KEY"

// logHash is `opsctl messages loghash CONVERSATION_ID`: it prints the conversation_hash the API logs for that conversation
// (the keyed hash, logger.HashConversation) and nothing else, so an operator can paste it into a Logs Explorer filter. It needs
// no Firestore and no project. The id must have the 32-hex shape; the key (CURSOR_HMAC_KEY of the project whose logs are read)
// must be set. The hash changes when the secret changes: use the version that was live when the log lines were written.
func logHash(convID, key string, out io.Writer) error {
	if !messaging.ValidID(convID) {
		return errors.New("messages loghash needs CONVERSATION_ID: 32 lower-case hex characters (the tail of the /messages/<id> URL)")
	}
	if key == "" {
		return fmt.Errorf("messages loghash needs %s in the environment: the project's cursor-hmac-key secret "+
			"(gcloud secrets versions access latest --secret=cursor-hmac-key --project=<project> | tr -d '\\r')", cursorKeyEnv)
	}
	if err := logger.SetConversationKey([]byte(key)); err != nil {
		return err
	}
	fmt.Fprintln(out, logger.HashConversation(convID))
	return nil
}

// conversationHashForAudit is the conversation_hash the takedown audit line prints: the keyed one when CURSOR_HMAC_KEY is set in
// the operator's shell, else a marker (never the plain hash, which is no longer what the logs carry).
func conversationHashForAudit(convID string) string {
	key := os.Getenv(cursorKeyEnv)
	if key == "" || logger.SetConversationKey([]byte(key)) != nil {
		return "unavailable(set-" + cursorKeyEnv + ")"
	}
	return logger.HashConversation(convID)
}

// migratePlaceholder is `opsctl messages migrate-placeholder --project P [--dry-run]` (W7-34, L-2): a dev-only, one-off
// rewrite of the legacy erased-user placeholder "deleted" to messaging.DeletedUID ("_deleted") in conversations
// (participants, gone, requestFrom, requestTo), messages (senderId) and the surviving peer's entry (peerId). Run --dry-run
// first: it reads the same documents and writes nothing. It is idempotent (a rerun finds nothing and writes 0) and resumable
// (the conversation is rewritten last). The caller has already refused a -prod project: messaging was never on in prod.
//
// Cost: see messaging.FirestoreRepo.MigratePlaceholder: 1 read per conversation found, per matching message and per entry
// probe, +1 per conversation for its (possibly empty) message query; at most 1 write per matching document.
func migratePlaceholder(ctx context.Context, b *backends, project string, dryRun bool, out io.Writer) error {
	if b.placeholder == nil {
		return errors.New("messages migrate-placeholder: no migrator configured")
	}
	if isProd(project) {
		return errors.New("messages migrate-placeholder is dev only")
	}
	ctx, _ = budget.WithCounter(ctx)
	var total messaging.PlaceholderPage
	err := driveLoop(ctx, out, "",
		func(ctx context.Context, after string) (string, bool, error) {
			p, err := b.placeholder.MigratePlaceholder(ctx, after, dryRun)
			if err != nil {
				return after, false, err
			}
			total.Conversations += p.Conversations
			total.Messages += p.Messages
			total.Entries += p.Entries
			next := after
			if p.Last != "" {
				next = p.Last
			}
			return next, !p.More, nil
		}, func(after string) string { return "after=" + checkpointOrDash(after) }, "migrate-placeholder")
	if err != nil {
		return err
	}
	verb := "rewritten"
	if dryRun {
		verb = "would be rewritten (nothing written)"
	}
	fmt.Fprintf(out, "migrate-placeholder: project=%s conversations=%d messages=%d entries=%d %s\n",
		project, total.Conversations, total.Messages, total.Entries, verb)
	return nil
}

// postLogHash is `opsctl polls loghash POST_ID`: it prints the post_hash the API logs on the VotePoll request line and the
// poll_vote_contention WARN for that post (logger.HashPost, keyed like conversation_hash). No Firestore, no project. The id is
// a decimal Snowflake string; the key is CURSOR_HMAC_KEY of the project whose logs are read, and the hash changes with it.
func postLogHash(postID, key string, out io.Writer) error {
	if postID == "" || len(postID) > 20 || strings.Trim(postID, "0123456789") != "" {
		return errors.New("polls loghash needs POST_ID: the decimal post id")
	}
	if key == "" {
		return fmt.Errorf("polls loghash needs %s in the environment: the project's cursor-hmac-key secret "+
			"(gcloud secrets versions access latest --secret=cursor-hmac-key --project=<project> | tr -d '\r')", cursorKeyEnv)
	}
	if err := logger.SetConversationKey([]byte(key)); err != nil {
		return err
	}
	fmt.Fprintln(out, logger.HashPost(postID))
	return nil
}
