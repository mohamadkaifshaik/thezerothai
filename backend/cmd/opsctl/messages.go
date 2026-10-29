package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// parseTakedownMessageArgs validates `opsctl messages takedown <convId:msgId> [--report R] [--note N]` before anything is
// opened or confirmed: the sub-command, the one target id (the moderation package's parser, the same one ReportContent
// uses), --report (a 32-character report id) and --note (only meaningful with --report). A mistake is a usage error.
func parseTakedownMessageArgs(sub, target string, a modArgs) (convID, msgID string, err error) {
	if sub != "takedown" {
		return "", "", usageErr("messages needs the sub-command takedown")
	}
	convID, msgID, ok := moderation.ParseMessageTarget(target)
	if !ok {
		return "", "", usageErr("messages takedown needs CONVERSATION_ID:MESSAGE_ID as its first argument (32 lower-case hex characters each, joined by a colon: the target of the report)")
	}
	if a.report != "" && !reportIDRe.MatchString(a.report) {
		return "", "", usageErr("--report must be a 32-character report id")
	}
	if a.note != "" && a.report == "" {
		return "", "", usageErr("--note is the report resolution note: it needs --report")
	}
	return convID, msgID, nil
}

// takedownMessage is `opsctl messages takedown` (ADR-0027 D12, plan W7-12): it tombstones one direct message (state REMOVED,
// text and request digest cleared, field-level updates only) and rewrites the inbox preview of each participant whose last
// message it was, in one transaction. Both participants then see "This message was removed" the next time they load the
// thread or the inbox; a client that cached the text keeps it until it reloads the first page, because a takedown moves
// neither createdAt nor lastMessageAt. The usual prod confirmation (the typed project id) already ran in run().
//
// --dry-run reads the same documents and writes nothing. --report R (checked first: R must be a MESSAGE report of exactly
// this message) resolves R as TAKEDOWN after the write; a report that is already RESOLVED only warns. A message that is
// already REMOVED, or tombstoned by its sender's account deletion, is left alone (0 writes) and --report still resolves.
// An unknown message, or one whose conversation is gone, is an error (exit 1).
//
// Output never contains the message text or a uid. Ids are printed only as one-way hashes (conversation_hash and
// message_hash, the same fields messaging logs); the last line before the cost line is a fixed-shape audit line.
//
// Cost: the transaction reads the message (1) and, for a VISIBLE one, the conversation (1) and each participant's entry that
// still exists (at most 2), and writes the message (1) and each preview that named it (at most 2): at most 4 reads, 3
// writes. --report adds 1 read to check it, then the resolve (1 read, 1 write).
func takedownMessage(ctx context.Context, b *backends, project, convID, msgID string, a modArgs, out io.Writer, now func() time.Time) error {
	if b.messages == nil {
		return errors.New("messages takedown: no message moderator configured")
	}
	ctx, counter := budget.WithCounter(ctx)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	if a.report != "" {
		if err := checkReport(cctx, b, a.report, moderation.TargetMessage, moderation.MessageTargetID(convID, msgID), "", out); err != nil {
			return err
		}
	}
	res, err := b.messages.TakedownMessage(cctx, convID, msgID, a.dryRun)
	if errors.Is(err, messaging.ErrNotFound) {
		return errors.New("no such message (unknown, or its conversation was deleted)")
	}
	if err != nil {
		return err
	}

	switch {
	case res.Before == "VISIBLE" && a.dryRun:
		fmt.Fprintf(out, "dry-run: would set the message REMOVED (text cleared) and rewrite %d inbox preview(s) (nothing written)\n", res.Entries)
	case res.Before == "VISIBLE":
		fmt.Fprintf(out, "message: VISIBLE -> REMOVED (text cleared); %d inbox preview(s) rewritten\n", res.Entries)
		fmt.Fprintln(out, "both participants see \"This message was removed\" on their next load of the thread or the inbox; a client that cached the text keeps it until it reloads the first page")
	case res.Before == "REMOVED":
		fmt.Fprintln(out, "message: already REMOVED; nothing written")
	default:
		fmt.Fprintf(out, "message: already %s (its sender deleted the account and the text was cleared then); nothing written\n", res.Before)
	}
	report := "-"
	if a.report != "" {
		report = a.report
	}
	fmt.Fprintf(out, "audit: messages takedown project=%s at=%s conversation_hash=%s message_hash=%s before=%s after=%s previews=%d wrote=%t dry_run=%t report=%s\n",
		project, now().UTC().Format(time.RFC3339), logger.HashUID(convID), logger.HashUID(msgID), res.Before, res.After, res.Entries, res.Wrote, a.dryRun, report)

	if a.report != "" {
		if a.dryRun {
			fmt.Fprintf(out, "dry-run: would resolve report %s as %s\n", a.report, moderation.ResolutionTakedown)
		} else if err := resolveReport(ctx, b, a.report, moderation.ResolutionTakedown, a.note, out, now); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "cost: reads=%d writes=%d\n", counter.Reads(), counter.Writes())
	return nil
}
