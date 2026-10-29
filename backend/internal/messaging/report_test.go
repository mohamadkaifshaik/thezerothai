package messaging

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const stranger = "uid-stranger"

// countingRepo counts the message and conversation reads of a report lookup and can fail the message read.
type countingRepo struct {
	*fakeRepo
	msgReads int
	msgErr   error
}

func (c *countingRepo) GetMessage(ctx context.Context, convID, msgID string) (MsgDoc, bool, error) {
	c.msgReads++
	if c.msgErr != nil {
		return MsgDoc{}, false, c.msgErr
	}
	return c.fakeRepo.GetMessage(ctx, convID, msgID)
}

// reporter is the Deps a report lookup needs and nothing else: no Social (the lookup never reads the caller's graph, so a
// blocked conversation stays reportable) and no Events or Badge.
func (r *rig) reporter() (*service, *countingRepo) {
	cr := &countingRepo{fakeRepo: r.repo}
	svc := New(r.reg, Deps{Repo: cr, Profiles: r.profs, Limits: r.limits, Now: func() time.Time { return r.now }}).(*service)
	return svc, cr
}

func msgID(i int) string { return fmt.Sprintf("%032x", i+1) } // the id putThread gives message i

func TestReportableMessage_ParticipantMatrix(t *testing.T) {
	t.Parallel()
	unknown := strings.Repeat("a", 32)
	tests := []struct {
		name    string
		caller  string
		conv    string
		msg     string
		mutate  func(rg *rig, rows []MessageRow)
		want    error
		wantTxt string
	}{
		{name: "alice reports bob's message", caller: alice, conv: aliceBobConv, msg: msgID(1), wantTxt: "secret text 1"},
		{name: "bob reports alice's message", caller: bob, conv: aliceBobConv, msg: msgID(0), wantTxt: "secret text 0"},
		{name: "own message", caller: alice, conv: aliceBobConv, msg: msgID(0), want: ErrOwnMessage},
		{name: "non-participant on a real message", caller: stranger, conv: aliceBobConv, msg: msgID(1), want: ErrNotFound},
		{name: "unknown conversation", caller: alice, conv: unknown, msg: msgID(1), want: ErrNotFound},
		{name: "unknown message in a real conversation", caller: alice, conv: aliceBobConv, msg: unknown, want: ErrNotFound},
		{name: "a message of another conversation id", caller: alice, conv: ConversationID(alice, stranger), msg: msgID(1), want: ErrNotFound},
		{name: "taken down by a moderator", caller: alice, conv: aliceBobConv, msg: msgID(1), want: ErrNotFound,
			mutate: func(rg *rig, rows []MessageRow) {
				rows[1].State, rows[1].Text = msgRemoved, ""
			}},
		{name: "sender deleted the account", caller: alice, conv: aliceBobConv, msg: msgID(1), want: ErrNotFound,
			mutate: func(rg *rig, rows []MessageRow) {
				rows[1].State, rows[1].Text, rows[1].SenderID = msgDeletedAccount, "", DeletedUID
			}},
		{name: "own message that was taken down is still own", caller: alice, conv: aliceBobConv, msg: msgID(0), want: ErrOwnMessage,
			mutate: func(rg *rig, rows []MessageRow) {
				rows[0].State, rows[0].Text = msgRemoved, ""
			}},
		{name: "a visible message whose sender is neither participant", caller: alice, conv: aliceBobConv, msg: msgID(1), want: ErrNotFound,
			mutate: func(rg *rig, rows []MessageRow) { rows[1].SenderID = stranger }},
		{name: "malformed ids are unknown, not an error", caller: alice, conv: "xyz", msg: msgID(1), want: ErrNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			rg := newRig(t, nil)
			rows := rg.putThread(3, nil)
			if tt.mutate != nil {
				tt.mutate(rg, rows)
				rg.repo.msgs[aliceBobConv] = rows
			}
			svc, _ := rg.reporter()
			got, err := svc.ReportableMessage(context.Background(), tt.caller, tt.conv, tt.msg)
			if tt.want != nil {
				if !errors.Is(err, tt.want) || err != tt.want { //nolint:errorlint // the sentinel itself is the contract: one value per cause class
					t.Fatalf("err = %v, want exactly %v", err, tt.want)
				}
				if got != (ReportedMessage{}) {
					t.Errorf("a refusal returned evidence: %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			peer := bob
			handle := "bob"
			if tt.caller == bob {
				peer, handle = alice, "alice"
			}
			var sentAt time.Time
			for _, r := range rows {
				if r.ID == tt.msg {
					sentAt = r.CreatedAt
				}
			}
			if got.Text != tt.wantTxt || got.SenderUID != peer || got.SenderHandle != handle || !got.CreatedAt.Equal(sentAt) {
				t.Errorf("evidence = %+v, want sent at %v", got, sentAt)
			}
		})
	}
}

// Every refusal that is not "own message" is the same sentinel value, so moderation can build one wire answer for all of them.
func TestReportableMessage_EveryNotFoundCauseIsTheSameValue(t *testing.T) {
	t.Parallel()
	rg := newRig(t, nil)
	rows := rg.putThread(3, nil)
	rows[1].State, rows[1].Text = msgRemoved, ""
	rows[2].State, rows[2].SenderID = msgDeletedAccount, DeletedUID
	rg.repo.msgs[aliceBobConv] = rows
	svc, _ := rg.reporter()
	unknown := strings.Repeat("b", 32)
	for name, args := range map[string][3]string{
		"unknown conversation": {alice, unknown, msgID(1)},
		"non-participant":      {stranger, aliceBobConv, msgID(1)},
		"unknown message":      {alice, aliceBobConv, unknown},
		"removed":              {alice, aliceBobConv, msgID(1)},
		"tombstoned":           {alice, aliceBobConv, msgID(2)},
	} {
		_, err := svc.ReportableMessage(context.Background(), args[0], args[1], args[2])
		if err != ErrNotFound { //nolint:errorlint // identity of the sentinel is the point
			t.Errorf("%s: err = %v, want the ErrNotFound value", name, err)
		}
	}
}

// The first lookup costs conversation 1 + message 1 + sender profile 1; a second lookup of another message in the same
// conversation costs the message only (the conversation is the 60 s instance cache, the profile the directory's).
func TestReportableMessage_ReadsAndCache(t *testing.T) {
	t.Parallel()
	rg := newRig(t, nil)
	rg.putThread(4, nil)
	svc, cr := rg.reporter()
	ctx := context.Background()
	if _, err := svc.ReportableMessage(ctx, alice, aliceBobConv, msgID(1)); err != nil {
		t.Fatal(err)
	}
	if rg.repo.gets != 1 || cr.msgReads != 1 || rg.profs.calls != 1 {
		t.Fatalf("cold: conversation reads %d, message reads %d, profile lookups %d, want 1/1/1", rg.repo.gets, cr.msgReads, rg.profs.calls)
	}
	if _, err := svc.ReportableMessage(ctx, alice, aliceBobConv, msgID(3)); err != nil {
		t.Fatal(err)
	}
	if rg.repo.gets != 1 || cr.msgReads != 2 {
		t.Errorf("warm: conversation reads %d, message reads %d, want 1/2 (the message is never cached)", rg.repo.gets, cr.msgReads)
	}
	// A refusal reads at most the conversation and the message.
	rg2 := newRig(t, nil)
	rg2.putThread(2, nil)
	svc2, cr2 := rg2.reporter()
	if _, err := svc2.ReportableMessage(ctx, stranger, aliceBobConv, msgID(1)); err != ErrNotFound { //nolint:errorlint // sentinel identity
		t.Fatal(err)
	}
	if cr2.msgReads != 0 || rg2.profs.calls != 0 {
		t.Errorf("a non-participant read the message (%d) or a profile (%d)", cr2.msgReads, rg2.profs.calls)
	}
}

// The lookup reads neither flag state nor the caller's graph: a user dropped from the allowlist, or one who blocked the
// sender, can still report (ADR-0027 D4 "On read", D6, F6). The service here has no Social at all and its registry has the
// flag off for everyone.
func TestReportableMessage_NeedsNoFlagAndNoGraph(t *testing.T) {
	t.Parallel()
	rg := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}) })
	rg.putThread(2, nil)
	svc, _ := rg.reporter()
	if _, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1)); err != nil {
		t.Fatalf("err = %v", err)
	}
	if rg.social.calls != 0 {
		t.Errorf("graph snapshots read: %d", rg.social.calls)
	}
}

// A sender the directory does not list as ACTIVE (suspended, deleting) still has their VISIBLE message shown in the thread, so
// it stays reportable; the handle is empty and the owner uid names them.
func TestReportableMessage_InactiveSenderHasNoHandle(t *testing.T) {
	t.Parallel()
	rg := newRig(t, nil)
	rg.putThread(2, nil)
	p := rg.profs.profiles[bob]
	p.Status = identity.AccountStatusSuspended
	rg.profs.profiles[bob] = p
	svc, _ := rg.reporter()
	got, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
	if err != nil {
		t.Fatal(err)
	}
	if got.SenderHandle != "" || got.SenderUID != bob || got.Text != "secret text 1" {
		t.Errorf("evidence = %+v", got)
	}
}

func TestReportableMessage_Errors(t *testing.T) {
	t.Parallel()
	t.Run("not configured", func(t *testing.T) {
		t.Parallel()
		svc := New(nil, Deps{}).(*service)
		if _, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1)); err == nil || errors.Is(err, ErrNotFound) {
			t.Fatalf("err = %v, want a configuration error", err)
		}
	})
	t.Run("storage errors are redacted and are not NOT_FOUND", func(t *testing.T) {
		t.Parallel()
		rg := newRig(t, nil)
		rg.putThread(2, nil)
		svc, cr := rg.reporter()
		cr.msgErr = fmt.Errorf("boom conversations/%s/messages/%s for %s", aliceBobConv, msgID(1), alice)
		_, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
		if err == nil || errors.Is(err, ErrNotFound) {
			t.Fatalf("err = %v", err)
		}
		for _, secret := range []string{alice, aliceBobConv, msgID(1)} {
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error leaks %q: %v", secret, err)
			}
		}
	})
	t.Run("directory errors are redacted", func(t *testing.T) {
		t.Parallel()
		rg := newRig(t, nil)
		rg.putThread(2, nil)
		rg.profs.err = fmt.Errorf("boom %s", bob)
		svc, _ := rg.reporter()
		_, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
		if err == nil || errors.Is(err, ErrNotFound) || strings.Contains(err.Error(), bob) {
			t.Fatalf("err = %v", err)
		}
	})
}
