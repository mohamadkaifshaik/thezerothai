package posts

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// UpdateScheduled models FirestoreRepo.UpdateScheduled on the in-memory store.
func (f *fakeSchedRepo) UpdateScheduled(ctx context.Context, p ScheduledUpdateParams) (*ScheduledPost, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.updates++
	if f.updateErr != nil {
		return nil, false, f.updateErr
	}
	cur := f.find(p.UID, p.ID)
	if cur == nil {
		return nil, false, ErrScheduledNotFound
	}
	if cur.Status != ScheduledPending || cur.Draft == nil {
		return nil, false, ErrScheduledNotPending
	}
	changedText := p.Text != nil && *p.Text != cur.Draft.Text
	changedPolicy := p.ReplyPolicy != nil && *p.ReplyPolicy != cur.Draft.ReplyPolicy
	moved := p.PublishAt != nil && !p.PublishAt.Equal(cur.PublishAt)
	if !changedText && !changedPolicy && !moved {
		return copyScheduled(cur), false, nil
	}
	if cur.PublishAt.Sub(p.Now) < ScheduledEditLockout {
		return nil, false, ErrScheduledLocked
	}
	if moved {
		n := f.windowCount(p.UID, *p.PublishAt, p.WindowCap+2)
		if !cur.PublishAt.Before(p.PublishAt.Add(-ScheduledWindowRadius)) && !cur.PublishAt.After(p.PublishAt.Add(ScheduledWindowRadius)) {
			n--
		}
		if n >= int64(p.WindowCap) {
			return nil, false, ErrScheduledWindowFull
		}
		cur.PublishAt = *p.PublishAt
	}
	if changedText {
		cur.Draft.Text = *p.Text
	}
	if changedPolicy {
		cur.Draft.ReplyPolicy = *p.ReplyPolicy
	}
	cur.UpdatedAt = p.Now
	return copyScheduled(cur), true, nil
}

// nowPublisher is the SweepRepo of the Post now tests: PublishScheduled marks the item in the fake store, unless hook
// decides otherwise (a race lost, a permanent failure, an error).
type nowPublisher struct {
	repo  *fakeSchedRepo
	hook  func(p PublishParams) (PublishResult, error)
	calls []PublishParams
}

func (n *nowPublisher) DueScheduled(context.Context, time.Time, int, *ScheduledDueCursor) (ScheduledDuePage, error) {
	panic("not used")
}

func (n *nowPublisher) TransitionScheduled(context.Context, ScheduledRef, ScheduledTransition, time.Time, time.Duration) (ScheduledRef, bool, error) {
	panic("not used")
}

func (n *nowPublisher) BumpScheduledAttempts(context.Context, ScheduledRef, time.Time) (ScheduledRef, bool, error) {
	panic("not used")
}

func (n *nowPublisher) PublishScheduled(_ context.Context, p PublishParams) (PublishResult, error) {
	n.calls = append(n.calls, p)
	if n.hook != nil {
		return n.hook(p)
	}
	n.repo.mu.Lock()
	defer n.repo.mu.Unlock()
	d := n.repo.find(p.UID, p.ID)
	if d == nil || d.Status != ScheduledPending {
		return PublishResult{Outcome: PublishNoop}, nil
	}
	ScheduledTransition{To: ScheduledPublished, PostID: "1000000000000000001"}.apply(d, p.Now, p.TerminalTTL)
	post := p.Draft
	post.ID = "1000000000000000001"
	return PublishResult{Outcome: PublishPublished, Post: &post, Attempts: 1}, nil
}

func newEditEnv(ps ...*ScheduledPost) (*schedSvcEnv, *nowPublisher) {
	e := newSchedSvcEnv(ps...)
	pub := &nowPublisher{repo: e.repo}
	e.svc.sweep.Repo = pub
	e.svc.sweep.Limits = defaultSweepLimits()
	return e, pub
}

func errCode(err error) connect.Code {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.Code
	}
	return connect.CodeOf(err)
}

func (e *schedSvcEnv) ctx() context.Context { return googleCtx(context.Background(), schedUID) }

func TestPublishScheduledNow(t *testing.T) {
	pendingWith := func(mut func(*ScheduledPost)) func(*schedSvcEnv) *ScheduledPost {
		return func(e *schedSvcEnv) *ScheduledPost {
			p := e.pendingAt(1, e.clock.Add(time.Hour))
			if mut != nil {
				mut(p)
			}
			return p
		}
	}
	tests := []struct {
		name       string
		item       func(*schedSvcEnv) *ScheduledPost
		mediaOn    bool
		hook       func(r *fakeSchedRepo, p PublishParams) (PublishResult, error)
		wantCode   connect.Code
		wantStatus ScheduledStatus
		wantFeat   string
		wantCalls  int
	}{
		{"pending is published", pendingWith(nil), true, nil, 0, ScheduledPublished, "", 1},
		{"overdue pending is still publishable", pendingWith(func(p *ScheduledPost) { p.PublishAt = p.PublishAt.Add(-48 * time.Hour) }), true, nil, 0, ScheduledPublished, "", 1},
		{"already published is a replay", pendingWith(func(p *ScheduledPost) {
			p.Status, p.PostID, p.Draft = ScheduledPublished, "123", nil
		}), true, nil, 0, ScheduledPublished, "", 0},
		{"cancelled", pendingWith(func(p *ScheduledPost) { p.Status, p.Draft = ScheduledCancelled, nil }), true, nil, connect.CodeFailedPrecondition, "", "", 0},
		{"failed", pendingWith(func(p *ScheduledPost) { p.Status, p.Draft, p.Failure = ScheduledFailed, nil, FailureInternal }), true, nil, connect.CodeFailedPrecondition, "", "", 0},
		{"media flag off", pendingWith(func(p *ScheduledPost) { p.Draft.Media = []MediaRef{{ID: "1"}} }), false, nil, connect.CodeFailedPrecondition, "", "media", 0},
		{"unsupported schema", pendingWith(func(p *ScheduledPost) { p.SchemaVersion = ScheduledSchemaVersion + 1 }), true, nil, connect.CodeFailedPrecondition, "", "", 0},
		{"sweep won the race", pendingWith(nil), true, func(r *fakeSchedRepo, p PublishParams) (PublishResult, error) {
			d := r.find(p.UID, p.ID)
			ScheduledTransition{To: ScheduledPublished, PostID: "77"}.apply(d, p.Now, p.TerminalTTL)
			return PublishResult{Outcome: PublishNoop}, nil
		}, 0, ScheduledPublished, "", 1},
		{"cancel won the race", pendingWith(nil), true, func(r *fakeSchedRepo, p PublishParams) (PublishResult, error) {
			ScheduledTransition{To: ScheduledCancelled}.apply(r.find(p.UID, p.ID), p.Now, p.TerminalTTL)
			return PublishResult{Outcome: PublishNoop}, nil
		}, connect.CodeFailedPrecondition, "", "", 1},
		{"media gone retires the item", pendingWith(nil), true, func(r *fakeSchedRepo, p PublishParams) (PublishResult, error) {
			ScheduledTransition{To: ScheduledFailed, Failure: FailureMediaUnavailable}.apply(r.find(p.UID, p.ID), p.Now, p.TerminalTTL)
			return PublishResult{Outcome: PublishFailed, Failure: FailureMediaUnavailable}, nil
		}, 0, ScheduledFailed, "", 1},
		{"edit lands before the transaction: the new draft is published", pendingWith(nil), true, func(r *fakeSchedRepo, p PublishParams) (PublishResult, error) {
			d := r.find(p.UID, p.ID)
			if p.Draft.Text == "edited meanwhile" {
				ScheduledTransition{To: ScheduledPublished, PostID: "55"}.apply(d, p.Now, p.TerminalTTL)
				return PublishResult{Outcome: PublishPublished, Post: &Post{ID: "55"}}, nil
			}
			d.Draft.Text = "edited meanwhile" // the first transaction sees another update time and publishes nothing
			return PublishResult{Outcome: PublishNoop}, nil
		}, 0, ScheduledPublished, "", 2},
		{"transient error", pendingWith(nil), true, func(*fakeSchedRepo, PublishParams) (PublishResult, error) {
			return PublishResult{}, errors.New("deadline")
		}, connect.CodeUnknown, "", "", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, pub := newEditEnv()
			item := tt.item(e)
			e.repo.docs[schedUID] = append(e.repo.docs[schedUID], item)
			if tt.hook != nil {
				pub.hook = func(p PublishParams) (PublishResult, error) { return tt.hook(e.repo, p) }
			}
			got, err := e.svc.PublishScheduledNow(e.ctx(), schedUID, schedKeyFor(5), item.ID, tt.mediaOn)
			if len(pub.calls) != tt.wantCalls {
				t.Errorf("publish calls = %d, want %d", len(pub.calls), tt.wantCalls)
			}
			if tt.wantCode != 0 || tt.wantFeat != "" {
				var ae *apierr.Error
				if !errors.As(err, &ae) && tt.wantCode != connect.CodeUnknown {
					t.Fatalf("err = %v, want an apierr", err)
				}
				if err == nil {
					t.Fatal("no error")
				}
				if ae != nil && tt.wantFeat != "" && ae.Metadata["feature"] != tt.wantFeat {
					t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeat)
				}
				if ae != nil && ae.Code != tt.wantCode && tt.wantFeat == "" {
					t.Errorf("code = %v, want %v", ae.Code, tt.wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("err = %v", err)
			}
			if got.Status != tt.wantStatus || got.Draft != nil {
				t.Errorf("got status %v draft %v, want %v and no draft", got.Status, got.Draft, tt.wantStatus)
			}
			if tt.wantStatus == ScheduledPublished && got.PostID == "" {
				t.Error("no post id")
			}
		})
	}
}

func TestPublishScheduledNow_Shape(t *testing.T) {
	e, pub := newEditEnv()
	valid := strings.Repeat("a", 32)
	tests := []struct{ name, key, id, field string }{
		{"bad key", "short", valid, "idempotency_key"},
		{"bad id", schedKeyFor(1), "NOT-HEX", "scheduled_id"},
	}
	for _, tt := range tests {
		_, err := e.svc.PublishScheduledNow(e.ctx(), schedUID, tt.key, tt.id, true)
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
			t.Errorf("%s: %v, want VALIDATION", tt.name, err)
		}
	}
	if _, err := e.svc.PublishScheduledNow(e.ctx(), schedUID, schedKeyFor(1), valid, true); errCode(err) != connect.CodeNotFound {
		t.Errorf("unknown id: %v, want NOT_FOUND", err)
	}
	// Another user's item is NOT_FOUND for the caller (the path is built from the caller's uid).
	other := e.pendingAt(2, e.clock.Add(time.Hour))
	other.UID = "uid-other"
	e.repo.docs["uid-other"] = []*ScheduledPost{other}
	if _, err := e.svc.PublishScheduledNow(e.ctx(), schedUID, schedKeyFor(1), other.ID, true); errCode(err) != connect.CodeNotFound {
		t.Errorf("foreign id: %v, want NOT_FOUND", err)
	}
	if len(pub.calls) != 0 {
		t.Error("publish ran for a refused request")
	}
	bare := newSchedSvcEnv()
	if _, err := bare.svc.PublishScheduledNow(bare.ctx(), schedUID, schedKeyFor(1), valid, true); !errors.Is(err, errNoScheduledRepo) {
		t.Errorf("no sweep repo: %v", err)
	}
}

func TestUpdateScheduled(t *testing.T) {
	str := func(s string) *string { return &s }
	pol := func(p postsv1.ReplyPolicy) *int32 { v := int32(p); return &v }
	at := func(e *schedSvcEnv, d time.Duration) (time.Time, bool) { return e.clock.Add(d), true }
	tests := []struct {
		name      string
		mut       func(*ScheduledPost)
		in        func(*schedSvcEnv, *UpdateScheduledInput)
		wantCode  connect.Code
		wantField string
		wantFeat  string
		check     func(*testing.T, *ScheduledPost)
		wantWrite int
	}{
		{name: "text", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("new text") }, wantWrite: 1,
			check: func(t *testing.T, p *ScheduledPost) {
				if p.Draft.Text != "new text" {
					t.Errorf("text = %q", p.Draft.Text)
				}
			}},
		{name: "same text is a no-op", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("x") }, wantWrite: 1},
		{name: "time moves to the whole minute", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.PublishAt, in.HasPublishAt = at(e, 3*time.Hour+30*time.Second)
		}, wantWrite: 1, check: func(t *testing.T, p *ScheduledPost) {
			if want := schedClock.Add(3 * time.Hour).Truncate(time.Minute); !p.PublishAt.Equal(want) {
				t.Errorf("PublishAt = %v, want %v", p.PublishAt, want)
			}
		}},
		{name: "policy", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.ReplyPolicy = pol(postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING)
		}, wantWrite: 1, check: func(t *testing.T, p *ScheduledPost) {
			if p.Draft.ReplyPolicy != ReplyPolicyFollowing {
				t.Errorf("policy = %q", p.Draft.ReplyPolicy)
			}
		}},
		{name: "policy flag off", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.ReplyPolicy = pol(postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING)
			in.ReplyAudienceEnabled = false
		}, wantCode: connect.CodeFailedPrecondition, wantFeat: "reply_audience"},
		{name: "nothing set", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {}, wantCode: connect.CodeInvalidArgument, wantField: "scheduled_id"},
		{name: "empty text refused", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("  ") }, wantCode: connect.CodeInvalidArgument},
		{name: "empty text allowed with media", mut: func(p *ScheduledPost) { p.Draft.Media = []MediaRef{{ID: "1"}} },
			in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("") }, wantWrite: 1},
		{name: "too long text", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str(strings.Repeat("a", 5000)) }, wantCode: connect.CodeInvalidArgument},
		{name: "unavailable policy", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.ReplyPolicy = pol(postsv1.ReplyPolicy_REPLY_POLICY_VERIFIED)
		}, wantCode: connect.CodeInvalidArgument, wantField: "reply_policy"},
		{name: "invalid time", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.HasPublishAt = true }, wantCode: connect.CodeInvalidArgument, wantField: "publish_at"},
		{name: "time too soon", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.PublishAt, in.HasPublishAt = at(e, time.Minute)
		}, wantCode: connect.CodeInvalidArgument, wantField: "publish_at"},
		{name: "time too far", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.PublishAt, in.HasPublishAt = at(e, 2000*time.Hour)
		}, wantCode: connect.CodeInvalidArgument, wantField: "publish_at"},
		{name: "within 60 s of publish_at is locked", mut: func(p *ScheduledPost) { p.PublishAt = schedClock.Add(59 * time.Second) },
			in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("late edit") }, wantCode: connect.CodeFailedPrecondition},
		{name: "exactly 60 s away is editable", mut: func(p *ScheduledPost) { p.PublishAt = schedClock.Add(60 * time.Second) },
			in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("edge edit") }, wantWrite: 1},
		{name: "published", mut: func(p *ScheduledPost) { p.Status, p.Draft, p.PostID = ScheduledPublished, nil, "9" },
			in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("after") }, wantCode: connect.CodeFailedPrecondition},
		{name: "cancelled", mut: func(p *ScheduledPost) { p.Status, p.Draft = ScheduledCancelled, nil },
			in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.Text = str("after") }, wantCode: connect.CodeFailedPrecondition},
		{name: "unknown id", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			in.ScheduledID = strings.Repeat("b", 32)
			in.Text = str("x")
		}, wantCode: connect.CodeNotFound},
		{name: "bad key", in: func(e *schedSvcEnv, in *UpdateScheduledInput) { in.IdempotencyKey = "k"; in.Text = str("x") }, wantCode: connect.CodeInvalidArgument, wantField: "idempotency_key"},
		{name: "window full", in: func(e *schedSvcEnv, in *UpdateScheduledInput) {
			for i := 0; i < 3; i++ {
				e.repo.docs[schedUID] = append(e.repo.docs[schedUID], e.pendingAt(10+i, e.clock.Add(5*time.Hour+time.Duration(i)*time.Minute)))
			}
			in.PublishAt, in.HasPublishAt = at(e, 5*time.Hour)
		}, wantCode: connect.CodeFailedPrecondition},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e, _ := newEditEnv()
			item := e.pendingAt(1, e.clock.Add(time.Hour))
			if tt.mut != nil {
				tt.mut(item)
			}
			e.repo.docs[schedUID] = []*ScheduledPost{item}
			in := UpdateScheduledInput{IdempotencyKey: schedKeyFor(7), ScheduledID: item.ID, ReplyAudienceEnabled: true}
			tt.in(e, &in)
			got, err := e.svc.UpdateScheduled(e.ctx(), schedUID, in)
			if tt.wantCode != 0 || tt.wantFeat != "" {
				var ae *apierr.Error
				if !errors.As(err, &ae) {
					t.Fatalf("err = %v, want an apierr", err)
				}
				if tt.wantCode != 0 && ae.Code != tt.wantCode {
					t.Errorf("code = %v, want %v (%v)", ae.Code, tt.wantCode, err)
				}
				if tt.wantField != "" && ae.Metadata["field"] != tt.wantField {
					t.Errorf("field = %q, want %q", ae.Metadata["field"], tt.wantField)
				}
				if tt.wantFeat != "" && ae.Metadata["feature"] != tt.wantFeat {
					t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeat)
				}
				return
			}
			if err != nil {
				t.Fatalf("err = %v", err)
			}
			if tt.check != nil {
				tt.check(t, got)
			}
			if e.repo.updates != tt.wantWrite {
				t.Errorf("repo updates = %d, want %d", e.repo.updates, tt.wantWrite)
			}
		})
	}
}

// TestUpdateScheduled_Replay: the same edit twice leaves the same item and the second call changes nothing.
func TestUpdateScheduled_Replay(t *testing.T) {
	e, _ := newEditEnv()
	item := e.pendingAt(1, e.clock.Add(time.Hour))
	e.repo.docs[schedUID] = []*ScheduledPost{item}
	txt := "edited"
	in := UpdateScheduledInput{IdempotencyKey: schedKeyFor(7), ScheduledID: item.ID, Text: &txt, PublishAt: e.clock.Add(2 * time.Hour), HasPublishAt: true}
	first, err := e.svc.UpdateScheduled(e.ctx(), schedUID, in)
	if err != nil {
		t.Fatal(err)
	}
	// The clock moves to inside the lockout of the NEW time: a replay still answers from state, not a bounds error.
	e.clock = first.PublishAt.Add(-30 * time.Second)
	second, err := e.svc.UpdateScheduled(e.ctx(), schedUID, in)
	if err != nil || second.Draft.Text != first.Draft.Text || !second.PublishAt.Equal(first.PublishAt) {
		t.Fatalf("replay = %v %v, want the first result", second, err)
	}
}

// ---- server ----

type fakeEditor struct {
	nowArgs     []any
	updateIn    UpdateScheduledInput
	updateUID   string
	item        *ScheduledPost
	err         error
	calls       int
	hadDeadline bool
}

func (f *fakeEditor) PublishScheduledNow(ctx context.Context, uid, key, id string, media bool) (*ScheduledPost, error) {
	f.calls++
	f.nowArgs = []any{uid, key, id, media}
	_, f.hadDeadline = ctx.Deadline()
	return f.item, f.err
}

func (f *fakeEditor) UpdateScheduled(ctx context.Context, uid string, in UpdateScheduledInput) (*ScheduledPost, error) {
	f.calls++
	f.updateUID, f.updateIn = uid, in
	_, f.hadDeadline = ctx.Deadline()
	return f.item, f.err
}

func editCalls() []schedCall {
	return []schedCall{
		{"PublishScheduledPostNow", func(s *Server, ctx context.Context) error {
			_, err := s.PublishScheduledPostNow(ctx, connect.NewRequest(&postsv1.PublishScheduledPostNowRequest{}))
			return err
		}},
		{"UpdateScheduledPost", func(s *Server, ctx context.Context) error {
			_, err := s.UpdateScheduledPost(ctx, connect.NewRequest(&postsv1.UpdateScheduledPostRequest{}))
			return err
		}},
	}
}

// TestScheduledEditServer_FlagModes: both RPCs need FEATURE_POSTS and FEATURE_SCHEDULED_POSTS on for the caller; neither
// reaches the service otherwise.
func TestScheduledEditServer_FlagModes(t *testing.T) {
	tests := []struct {
		name        string
		on          map[string]bool
		wantFeature string
		wantReach   bool
	}{
		{"posts off", map[string]bool{"scheduled_posts": true}, "", false},
		{"scheduled_posts off", map[string]bool{"posts": true}, "scheduled_posts", false},
		{"both off", nil, "", false},
		{"both on", map[string]bool{"posts": true, "scheduled_posts": true}, "", true},
	}
	for _, tt := range tests {
		for _, c := range editCalls() {
			t.Run(tt.name+"/"+c.name, func(t *testing.T) {
				ed := &fakeEditor{item: &ScheduledPost{PublishAt: schedBase, CreatedAt: schedNow}}
				srv := NewServer(nil, namedFlags(tt.on), WithScheduledEditor(ed))
				err := c.call(srv, callerCtx("u1"))
				if tt.wantReach {
					if err != nil || ed.calls != 1 || !ed.hadDeadline {
						t.Fatalf("err %v calls %d deadline %v", err, ed.calls, ed.hadDeadline)
					}
					return
				}
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != tt.wantFeature {
					t.Errorf("feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
				}
				if ed.calls != 0 {
					t.Error("the service was reached while a flag is off")
				}
			})
		}
	}
	// A caller outside the allowlist/percent bucket is refused too (per-caller, unlike List and Cancel).
	srv := NewServer(nil, namedFlags(map[string]bool{"posts": true}), WithScheduledEditor(&fakeEditor{}))
	if err := editCalls()[0].call(srv, callerCtx("u1")); errCode(err) != connect.CodeFailedPrecondition {
		t.Errorf("err = %v", err)
	}
}

func TestScheduledEditServer_WithoutEditorIsUnimplemented(t *testing.T) {
	srv := NewServer(nil, namedFlags{"posts": true, "scheduled_posts": true})
	for _, c := range editCalls() {
		if err := c.call(srv, callerCtx("u1")); connect.CodeOf(err) != connect.CodeUnimplemented {
			t.Errorf("%s: %v, want Unimplemented", c.name, err)
		}
	}
}

func TestScheduledEditServer_MapsTheRequests(t *testing.T) {
	at := time.Date(2026, 11, 3, 10, 0, 30, 0, time.UTC)
	on := namedFlags{"posts": true, "scheduled_posts": true, "media": true, "reply_audience": true}
	ed := &fakeEditor{item: &ScheduledPost{ID: "abc", PublishAt: at, Status: ScheduledPublished, PostID: "9", CreatedAt: schedNow}}
	srv := NewServer(nil, on, WithScheduledEditor(ed))

	resp, err := srv.PublishScheduledPostNow(callerCtx("u1"), connect.NewRequest(&postsv1.PublishScheduledPostNowRequest{IdempotencyKey: "k", ScheduledId: "sid"}))
	if err != nil || ed.nowArgs[0] != "u1" || ed.nowArgs[1] != "k" || ed.nowArgs[2] != "sid" || ed.nowArgs[3] != true {
		t.Fatalf("now: %v %v", err, ed.nowArgs)
	}
	if got := resp.Msg.GetScheduledPost(); got.GetPostId() != "9" || got.GetStatus() != postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PUBLISHED {
		t.Errorf("now response = %v", got)
	}

	txt, pol := "hi", postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING
	cases := []struct {
		name    string
		req     *postsv1.UpdateScheduledPostRequest
		text    bool
		policy  bool
		hasAt   bool
		wantAt  time.Time
		wantRAE bool
	}{
		{"nothing set", &postsv1.UpdateScheduledPostRequest{}, false, false, false, time.Time{}, true},
		{"all set", &postsv1.UpdateScheduledPostRequest{Text: &txt, ReplyPolicy: &pol, PublishAt: timestamppb.New(at)}, true, true, true, at, true},
		{"invalid timestamp", &postsv1.UpdateScheduledPostRequest{PublishAt: &timestamppb.Timestamp{Seconds: 1 << 60}}, false, false, true, time.Time{}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			c.req.IdempotencyKey, c.req.ScheduledId = "k", "sid"
			if _, err := srv.UpdateScheduledPost(callerCtx("u1"), connect.NewRequest(c.req)); err != nil {
				t.Fatal(err)
			}
			in := ed.updateIn
			if ed.updateUID != "u1" || in.IdempotencyKey != "k" || in.ScheduledID != "sid" || (in.Text != nil) != c.text || (in.ReplyPolicy != nil) != c.policy ||
				in.HasPublishAt != c.hasAt || !in.PublishAt.Equal(c.wantAt) || in.ReplyAudienceEnabled != c.wantRAE {
				t.Errorf("input = %+v", in)
			}
			if c.text && *in.Text != "hi" || c.policy && *in.ReplyPolicy != int32(pol) {
				t.Errorf("values = %+v", in)
			}
		})
	}
	ed.err = errors.New("boom")
	if _, err := srv.UpdateScheduledPost(callerCtx("u1"), connect.NewRequest(&postsv1.UpdateScheduledPostRequest{})); err == nil {
		t.Error("service error swallowed")
	}
}
