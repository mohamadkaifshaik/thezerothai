package messaging

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// checkFlags are the four gates of CheckPostShare, all on; off turns the named ones off.
func checkFlags(off ...string) []flags.Spec {
	out := []flags.Spec{
		{Name: FlagName, Mode: flags.On}, {Name: ShareCheckFlagName, Mode: flags.On},
		{Name: postsFlagName, Mode: flags.On}, {Name: PostShareFlagName, Mode: flags.On},
	}
	for i := range out {
		for _, n := range off {
			if out[i].Name == n {
				out[i].Mode = flags.Off
			}
		}
	}
	return out
}

// newCheckRig is newShareRig over exactly the given registry (messaging included, so it can be off) and allowAnon.
func newCheckRig(t *testing.T, allowAnon bool, specs ...flags.Spec) *shareRig {
	t.Helper()
	sr := newShareRig(t)
	r := sr.rig
	r.reg = flags.NewRegistry(specs...)
	r.allowAnon = allowAnon
	r.svc = New(r.reg, Deps{
		Repo: r.repo, Social: r.social, TxSocial: r.txSocial, TxProfiles: r.txProfs, AllowAnonymous: r.allowAnon, Profiles: r.profs,
		Events: r.events, Badge: r.badge, Limits: r.limits, CursorKey: testCursorKey, Now: func() time.Time { return r.now },
		PostShare: sr.check, Cards: sr.cards, Shares: sr.shares,
	}).(*service)
	return sr
}

// untouched fails when the call read or wrote anything besides the share check itself (want checks calls).
func (sr *shareRig) untouched(t *testing.T, wantChecks int) {
	t.Helper()
	r := sr.rig
	if r.repo.gets+len(r.repo.sends)+r.social.calls+r.profs.calls+r.txSocial.txCalls+len(sr.shares.calls)+len(sr.cards.calls) != 0 || sr.check.calls != wantChecks {
		t.Fatalf("CheckPostShare touched: gets %d sends %d graph %d profiles %d tx %d records %v cards %v checks %d (want %d)",
			r.repo.gets, len(r.repo.sends), r.social.calls, r.profs.calls, r.txSocial.txCalls, sr.shares.calls, sr.cards.calls, sr.check.calls, wantChecks)
	}
}

func checkPost(id string) *messagingv1.CheckPostShareRequest {
	return &messagingv1.CheckPostShareRequest{PostId: id}
}

// unavailableSet is RefuseShare's answer when the protected set cannot be read (posts.setUnavailable), byte for byte.
func unavailableSet() error {
	return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
		WithCause(errors.New("posts: protected set: boom"))
}

// The gates, in SendMessage's order and before any lookup: messaging, dm_share_check, the verified email, posts and
// dm_post_share (FEATURE_DISABLED with the off flag), then the id (VALIDATION post_id). Zero CheckShare calls, nothing read.
func TestCheckPostShare_GatesBeforeAnyRead(t *testing.T) {
	unverified := authn.WithClaims(context.Background(), authn.Claims{SignInProvider: authn.SignInProviderPassword, EmailVerified: false})
	tests := []struct {
		name    string
		specs   []flags.Spec
		ctx     context.Context
		postID  string
		code    connect.Code
		reason  commonv1.ErrorReason
		meta    map[string]string
		message string
		sendToo bool // SendMessage refuses the same caller with the same wire bytes
	}{
		{"messaging off", checkFlags(FlagName), verifiedCtx(), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": FlagName}, "", true},
		{"dm_share_check off", checkFlags(ShareCheckFlagName), verifiedCtx(), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": ShareCheckFlagName}, "", false},
		{"dm_share_check off answers before the email", checkFlags(ShareCheckFlagName), unverified, postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": ShareCheckFlagName}, "", false},
		{"unverified email", checkFlags(), unverified, postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, nil, "please verify your email before sending messages", true},
		{"unverified email answers before posts off", checkFlags(postsFlagName), unverified, postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, nil, "", false},
		{"posts off", checkFlags(postsFlagName), verifiedCtx(), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": postsFlagName}, "", false},
		{"dm_post_share off", checkFlags(PostShareFlagName), verifiedCtx(), postOrig, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": PostShareFlagName}, "", false},
		{"dm_post_share off answers before the id", checkFlags(PostShareFlagName), verifiedCtx(), "123", connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": PostShareFlagName}, "", false},
		{"empty id", checkFlags(), verifiedCtx(), "", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "post_id"}, "post_id must be a 19-digit post id", false},
		{"not 19 digits", checkFlags(), verifiedCtx(), "123", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "post_id"}, "post_id must be a 19-digit post id", false},
		{"not digits", checkFlags(), verifiedCtx(), "000000000000000000x", connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "post_id"}, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newCheckRig(t, false, tt.specs...)
			resp, err := r.svc.CheckPostShare(tt.ctx, alice, checkPost(tt.postID))
			if resp != nil {
				t.Fatalf("a refusal answered %v", resp)
			}
			wantAPI(t, err, tt.code, tt.reason, tt.meta)
			if tt.message != "" {
				if got := apierr.ToConnect(err).Message(); got != tt.message {
					t.Fatalf("message = %q, want %q", got, tt.message)
				}
			}
			r.untouched(t, 0)
			if tt.sendToo {
				// SendMessage's own gate answers the same bytes for the same caller.
				s := newCheckRig(t, false, tt.specs...)
				_, serr := s.svc.Send(tt.ctx, alice, sharing(key1, bob, "look", tt.postID))
				if got, want := wireBytes(t, err), wireBytes(t, serr); !bytes.Equal(got, want) {
					t.Fatalf("check bytes %q != send bytes %q", got, want)
				}
			}
		})
	}
}

// The answers of the shared check, each byte-identical to SendMessage with shared_post_id to a recipient who passes every
// recipient check (the same checkPostShare over the same PostShareCheck): NOT_FOUND "post not found" for every
// ErrPostNotVisible, PROTECTED_ACCOUNT and UNAVAILABLE passed through, success with the resolved id. CheckPostShare reads
// nothing but the check and records no share; any other failure is an internal error on both.
func TestCheckPostShare_ParityWithSend(t *testing.T) {
	tests := []struct {
		name     string
		postID   string
		checkErr error
		wantID   string // "" = a refusal
		code     connect.Code
		reason   commonv1.ErrorReason
		internal bool
		rawRead  bool // internal here, but SendMessage answers UNAVAILABLE "busy, please retry"
	}{
		{name: "visible original", postID: postOrig, wantID: postOrig},
		{name: "a REPOST id answers its original", postID: postRepost, wantID: postOrig},
		{name: "own post", postID: postByAlice, wantID: postByAlice},
		{name: "not visible: GetPost's NOT_FOUND", postID: postHidden, code: connect.CodeNotFound, reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{name: "protected author: PROTECTED_ACCOUNT", postID: postProtect, code: connect.CodeFailedPrecondition, reason: commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT},
		{name: "protected set unreadable: UNAVAILABLE", postID: postOrig, checkErr: unavailableSet(), code: connect.CodeUnavailable, reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{name: "ErrPostNotVisible wrapped", postID: postOrig, checkErr: errors.Join(errors.New("x"), ErrPostNotVisible), code: connect.CodeNotFound, reason: commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED},
		{name: "any other failure is internal", postID: postOrig, checkErr: errors.New("boom " + alice + " " + postOrig), internal: true},
		// The one difference from SendMessage: a raw read failure is INTERNAL here (Send: UNAVAILABLE busy).
		{name: "raw read failure is INTERNAL, not UNAVAILABLE", postID: postOrig, checkErr: context.DeadlineExceeded, internal: true, rawRead: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			check := newCheckRig(t, false, checkFlags()...)
			check.check.err = tt.checkErr
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			resp, cerr := check.svc.CheckPostShare(ctx, alice, checkPost(tt.postID))
			check.untouched(t, 1)

			send := newCheckRig(t, false, checkFlags()...)
			send.check.err = tt.checkErr
			_, serr := send.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "look", tt.postID))

			switch {
			case tt.wantID != "":
				if cerr != nil || serr != nil {
					t.Fatalf("check = %v, send = %v; want both to pass", cerr, serr)
				}
				if resp.GetSharedPostId() != tt.wantID || send.repo.sends[0].SharedPostID != tt.wantID {
					t.Fatalf("check answered %q, send stored %q; want %q", resp.GetSharedPostId(), send.repo.sends[0].SharedPostID, tt.wantID)
				}
			case tt.internal:
				if tt.rawRead {
					if cerr == nil || errors.As(cerr, new(*apierr.Error)) {
						t.Fatalf("check = %v; want an internal error", cerr)
					}
					if got := apierr.ToConnect(cerr).Code(); got != connect.CodeInternal {
						t.Fatalf("check code = %v, want INTERNAL", got)
					}
					if got := apierr.ToConnect(serr).Code(); got != connect.CodeUnavailable {
						t.Fatalf("send code = %v (%v), want UNAVAILABLE", got, serr)
					}
				} else if cerr == nil || errors.As(cerr, new(*apierr.Error)) || serr == nil || errors.As(serr, new(*apierr.Error)) {
					t.Fatalf("check = %v, send = %v; want internal errors", cerr, serr)
				}
				if msg := cerr.Error(); bytes.Contains([]byte(msg), []byte(alice)) || bytes.Contains([]byte(msg), []byte(postOrig)) {
					t.Fatalf("internal error %q names the uid or the post id", msg)
				}
			default:
				if resp != nil {
					t.Fatalf("a refusal answered %v", resp)
				}
				wantAPI(t, cerr, tt.code, tt.reason, nil)
				if got, want := wireBytes(t, cerr), wireBytes(t, serr); !bytes.Equal(got, want) {
					t.Fatalf("check bytes %q != send bytes %q", got, want)
				}
				if tt.code == connect.CodeNotFound && apierr.ToConnect(cerr).Message() != postNotFoundText {
					t.Fatalf("message = %q, want GetPost's %q", apierr.ToConnect(cerr).Message(), postNotFoundText)
				}
			}
			kind, _ := info.Get(fieldKind)
			shared, _ := info.Get(fieldSharedPost)
			if kind != kindShareCheck || shared != true {
				t.Errorf("request line kind = %v shared_post = %v, want %s, true", kind, shared, kindShareCheck)
			}
			for _, a := range info.Fields() {
				if v := a.Value.String(); bytes.Contains([]byte(v), []byte(tt.postID)) {
					t.Errorf("request line field %s carries the post id", a.Key)
				}
			}
		})
	}
}

// SendMessage's own VALIDATION answer for a malformed shared_post_id is unchanged by the shared gate: field shared_post_id
// and the same message.
func TestSendPost_ValidationFieldUnchanged(t *testing.T) {
	r := newShareRig(t)
	_, err := r.svc.Send(verifiedCtx(), alice, sharing(key1, bob, "look", "123"))
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "shared_post_id"})
	if got := apierr.ToConnect(err).Message(); got != "shared_post_id must be a 19-digit post id" {
		t.Fatalf("message = %q", got)
	}
}
