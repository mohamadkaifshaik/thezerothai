package apiserver

// CheckPostShare against SendMessage with shared_post_id, both through messaging.New with the REAL postShareCheck adapter
// over the sharePosts fake (messaging_post_share_test.go): every row must give the same wire answer (code, message and
// ErrorDetail bytes) or the same resolved id. The send goes to a recipient who passes every recipient check.

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// parityRepo is a messaging.Repo whose only implemented method is Send (a recipient_user_id send to an established
// peer calls nothing else); it records the stored shared post id. Any other call panics on the nil embedded interface.
type parityRepo struct {
	messaging.Repo
	stored []string
}

func (r *parityRepo) Send(_ context.Context, p messaging.SendParams) (messaging.SendResult, error) {
	r.stored = append(r.stored, p.SharedPostID)
	return messaging.SendResult{Created: true, Msg: messaging.MsgDoc{SenderID: p.UID, Text: p.Text, SharedPostID: p.SharedPostID, CreatedAt: p.Now}}, nil
}

// paritySocial: nobody follows, mutes or blocks anybody (the post rules carry the blocks under test).
type paritySocial struct{}

func (paritySocial) Snapshot(context.Context, string) (graph.Snapshot, error) {
	return graph.Snapshot{}, nil
}
func (paritySocial) SnapshotInTx(context.Context, *firestore.Transaction, string) (graph.Snapshot, error) {
	return graph.Snapshot{}, nil
}

// parityProfiles: every uid is an ACTIVE, established account.
type parityProfiles struct{ created time.Time }

func (p parityProfiles) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	out := make(map[string]identity.Profile, len(uids))
	for _, u := range uids {
		out[u] = identity.Profile{UserID: u, Handle: "h" + u, Status: identity.AccountStatusActive, CreatedAt: p.created}
	}
	return out, nil
}
func (parityProfiles) Forget(...string) {}
func (p parityProfiles) ProfileInTx(_ context.Context, _ *firestore.Transaction, uid string) (identity.Profile, error) {
	return identity.Profile{UserID: uid, Status: identity.AccountStatusActive, CreatedAt: p.created}, nil
}

// parityService is messaging.New over the real postShareCheck adapter and the fakes above; off names flags left off.
func parityService(world sharePosts, off ...string) (messaging.Service, *parityRepo) {
	specs := []flags.Spec{}
	for _, name := range []string{messaging.FlagName, messaging.ShareCheckFlagName, posts.FlagName, messaging.PostShareFlagName} {
		mode := flags.On
		for _, o := range off {
			if o == name {
				mode = flags.Off
			}
		}
		specs = append(specs, flags.Spec{Name: name, Mode: mode})
	}
	now := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	profs := parityProfiles{created: now.Add(-365 * 24 * time.Hour)}
	repo := &parityRepo{}
	svc := messaging.New(flags.NewRegistry(specs...), messaging.Deps{
		Repo: repo, Social: paritySocial{}, TxSocial: paritySocial{}, Profiles: profs, TxProfiles: profs,
		Limits:    messaging.Limits{RequestMaxUnanswered: 3, DMNewPerDay: 20, NewAccountDMNewPerDay: 5, NewAccountWindow: time.Hour},
		PostShare: postShareCheck{posts: world}, Now: func() time.Time { return now },
	})
	return svc, repo
}

// shareCheckWire is an error as the client receives it: code, message and the serialised ErrorDetail.
func shareCheckWire(t *testing.T, err error) []byte {
	t.Helper()
	ce := apierr.ToConnect(err)
	if ce == nil {
		t.Fatal("no error")
	}
	var b bytes.Buffer
	b.WriteString(ce.Code().String() + "|" + ce.Message() + "|")
	for _, d := range ce.Details() {
		v, verr := d.Value()
		if verr != nil {
			t.Fatal(verr)
		}
		raw, merr := proto.MarshalOptions{Deterministic: true}.Marshal(v)
		if merr != nil {
			t.Fatal(merr)
		}
		b.Write(raw)
	}
	return b.Bytes()
}

// Extra posts of the parity world.
const (
	spRepostProt = "0000000000000000206" // a REPOST of spProtected
	spRepostRep  = "0000000000000000207" // a REPOST of the REPOST spRepost
	spQuote      = "0000000000000000208" // a QUOTE whose embedded author is gina
)

func parityWorld() sharePosts {
	w := shareWorld()
	w.visible[spRepostProt] = &posts.Post{ID: spRepostProt, AuthorID: "dave", Kind: posts.KindRepost, RepostOfID: spProtected}
	w.visible[spRepostRep] = &posts.Post{ID: spRepostRep, AuthorID: "dave", Kind: posts.KindRepost, RepostOfID: spRepost}
	w.visible[spQuote] = &posts.Post{ID: spQuote, AuthorID: "frank", Kind: posts.KindQuote, EmbeddedAuthorID: "gina"}
	w.blocks["hank"] = "gina"
	return w
}

func TestCheckPostShare_ParityWithSendOverPostShareCheck(t *testing.T) {
	unavailable := apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
		WithCause(errors.New("posts: protected set: boom"))
	tests := []struct {
		name, caller, id string
		refuseErr        error
		off              []string
		wantID           string // "" = a refusal
		code             connect.Code
		reason           commonv1.ErrorReason
		feature          string
	}{
		{name: "public", caller: "alice", id: spOrig, wantID: spOrig},
		{name: "a REPOST answers its original", caller: "alice", id: spRepost, wantID: spOrig},
		{name: "own protected post", caller: "erin", id: spProtected, wantID: spProtected},
		{name: "another's protected post", caller: "alice", id: spProtected, code: connect.CodeFailedPrecondition, reason: commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT},
		{name: "repost of a protected original", caller: "alice", id: spRepostProt, code: connect.CodeFailedPrecondition, reason: commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT},
		{name: "repost of a repost", caller: "alice", id: spRepostRep, code: connect.CodeNotFound},
		{name: "repost without an original", caller: "alice", id: spNoOrig, code: connect.CodeNotFound},
		{name: "repost whose original is invisible", caller: "alice", id: spDangling, code: connect.CodeNotFound},
		{name: "quote whose embedded author the caller blocks", caller: "hank", id: spQuote, code: connect.CodeNotFound},
		{name: "caller blocks the author (G2)", caller: "bob", id: spOrig, code: connect.CodeNotFound},
		{name: "invisible (Viewable's ErrNotFound)", caller: "alice", id: "0000000000000000999", code: connect.CodeNotFound},
		{name: "set unreadable, followed author (G1)", caller: "alice", id: spOrig, refuseErr: unavailable, code: connect.CodeUnavailable},
		{name: "set unreadable, own post passes", caller: "carol", id: spOrig, refuseErr: unavailable, wantID: spOrig},
		{name: "dm_post_share off", caller: "alice", id: spOrig, off: []string{messaging.PostShareFlagName}, code: connect.CodeFailedPrecondition, reason: commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, feature: messaging.PostShareFlagName},
		{name: "posts off", caller: "alice", id: spOrig, off: []string{posts.FlagName}, code: connect.CodeFailedPrecondition, reason: commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, feature: posts.FlagName},
	}
	ctx := authn.WithClaims(context.Background(), authn.Claims{SignInProvider: authn.SignInProviderGoogle})
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			world := parityWorld()
			world.refuseErr = tt.refuseErr
			svc, repo := parityService(world, tt.off...)
			resp, cerr := svc.CheckPostShare(ctx, tt.caller, &messagingv1.CheckPostShareRequest{PostId: tt.id})
			if len(repo.stored) != 0 {
				t.Fatal("CheckPostShare reached the send transaction")
			}
			_, serr := svc.Send(ctx, tt.caller, &messagingv1.SendMessageRequest{
				IdempotencyKey: "parity-key-00000001", Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: "rcpt"},
				Text: "look", SharedPostId: tt.id,
			})
			if tt.wantID != "" {
				if cerr != nil || serr != nil {
					t.Fatalf("check = %v, send = %v; want both to pass", cerr, serr)
				}
				if resp.GetSharedPostId() != tt.wantID || len(repo.stored) != 1 || repo.stored[0] != tt.wantID {
					t.Fatalf("check answered %q, send stored %v; want %q", resp.GetSharedPostId(), repo.stored, tt.wantID)
				}
				return
			}
			if resp != nil || cerr == nil || serr == nil {
				t.Fatalf("check = %v, %v; send = %v; want both refused", resp, cerr, serr)
			}
			ce := apierr.ToConnect(cerr)
			if ce.Code() != tt.code {
				t.Fatalf("code = %v (%v), want %v", ce.Code(), cerr, tt.code)
			}
			if tt.code == connect.CodeNotFound && ce.Message() != "post not found" {
				t.Fatalf("message = %q, want GetPost's", ce.Message())
			}
			var ae *apierr.Error
			if !errors.As(cerr, &ae) {
				t.Fatalf("check error %v is not an apierr", cerr)
			}
			if tt.reason != 0 && ae.Reason != tt.reason || ae.Metadata["feature"] != tt.feature {
				t.Fatalf("reason %v feature %q, want %v %q", ae.Reason, ae.Metadata["feature"], tt.reason, tt.feature)
			}
			if got, want := shareCheckWire(t, cerr), shareCheckWire(t, serr); !bytes.Equal(got, want) {
				t.Fatalf("check bytes %q != send bytes %q", got, want)
			}
		})
	}
	t.Run("dm_share_check off refuses the check only", func(t *testing.T) {
		svc, _ := parityService(parityWorld(), messaging.ShareCheckFlagName)
		_, err := svc.CheckPostShare(ctx, "alice", &messagingv1.CheckPostShareRequest{PostId: spOrig})
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != messaging.ShareCheckFlagName {
			t.Fatalf("err = %v, want FEATURE_DISABLED dm_share_check", err)
		}
		if _, err := svc.Send(ctx, "alice", &messagingv1.SendMessageRequest{
			IdempotencyKey: "parity-key-00000002", Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: "rcpt"},
			Text: "look", SharedPostId: spOrig,
		}); err != nil {
			t.Fatalf("the send does not need dm_share_check: %v", err)
		}
	})
}
