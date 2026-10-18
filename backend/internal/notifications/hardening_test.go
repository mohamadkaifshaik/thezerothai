package notifications

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"
)

// --- N-1: producer-side recipient cap ---

func TestRecipientCap(t *testing.T) {
	t.Parallel()
	isNew := func(uid string) bool { return uid == "newbie" }
	tests := []struct {
		name   string
		actor  string
		counts []int
		want   []bool
	}{
		{"established fits then drops whole event", "vet", []int{6, 4, 1, 4}, []bool{true, true, false, false}},
		{"new account has the lower tier", "newbie", []int{3, 2, 1}, []bool{true, true, false}},
		{"over-cap event is all or nothing", "vet", []int{9, 2, 1}, []bool{true, false, true}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := NewRecipientCap(10, 5, isNew)
			for i, n := range tt.counts {
				if ok, _, _ := c.Admit(tt.actor, n); ok != tt.want[i] {
					t.Errorf("Admit #%d (%d recipients) = %v, want %v", i, n, ok, tt.want[i])
				}
			}
		})
	}
	t.Run("nil cap admits everything", func(t *testing.T) {
		t.Parallel()
		if ok, _, _ := (*RecipientCap)(nil).Admit("x", 1000); !ok {
			t.Error("nil cap must admit")
		}
	})
	t.Run("actors are independent", func(t *testing.T) {
		t.Parallel()
		c := NewRecipientCap(2, 1, nil)
		c.Admit("a", 2)
		if ok, _, _ := c.Admit("b", 2); !ok {
			t.Error("b has its own allowance")
		}
	})
}

func TestEmittersDropOverCapEventsAndLogDistinctMessage(t *testing.T) {
	t.Parallel()
	const actor = "Zq8vK2mXr1TnB4yHc7LdPw3sEaGf"
	ev := Event{Type: TypeMention, ActorID: actor, RecipientIDs: []string{"b1", "b2", "b3"}, PostID: postA}

	t.Run("pubsub", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		pub := &fakePublisher{}
		em := NewPubSubEmitter(pub, allFlags{}, slog.New(slog.NewJSONHandler(&buf, nil))).WithRecipientCap(NewRecipientCap(5, 5, nil))
		mustNoErr(t, em.Emit(context.Background(), ev)) // 3 of 5
		mustNoErr(t, em.Emit(context.Background(), ev)) // 6 > 5: dropped
		if len(pub.data) != 1 {
			t.Fatalf("publishes = %d, want 1", len(pub.data))
		}
		if !strings.Contains(buf.String(), "notification_fanout_capped") || strings.Contains(buf.String(), actor) {
			t.Errorf("log = %s (want the cap line with a hashed actor)", buf.String())
		}
	})
	t.Run("inline", func(t *testing.T) {
		t.Parallel()
		r := newRig(t, nil)
		em := NewInlineEmitter(r.f, allFlags{}, slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))).WithRecipientCap(NewRecipientCap(1, 1, nil))
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"bob", "carol"}, At: t0}))
		em.Wait()
		if len(r.repo.rows) != 0 {
			t.Errorf("an over-cap event must write nothing: %v", r.repo.rows)
		}
	})
	t.Run("self and flag-filtered recipients are not charged", func(t *testing.T) {
		t.Parallel()
		pub := &fakePublisher{}
		em := NewPubSubEmitter(pub, fakeFlags{"b1": true}, nil).WithRecipientCap(NewRecipientCap(1, 1, nil))
		self := Event{Type: TypeMention, ActorID: "a", RecipientIDs: []string{"a", "b2", "b1"}, PostID: postA}
		mustNoErr(t, em.Emit(context.Background(), self))
		mustNoErr(t, em.Emit(context.Background(), Event{Type: TypeFollow, ActorID: "a", RecipientIDs: []string{"b2"}}))
		if len(pub.data) != 1 {
			t.Errorf("publishes = %d, want 1 (only b1 was eligible and charged)", len(pub.data))
		}
	})
}

// --- N-2: per-recipient push limit and collapse keys ---

func TestDeliver_PushLimitSkipsPushButWritesRows(t *testing.T) {
	t.Parallel()
	r := newRig(t, nil)
	r.f.d.PushLimit = NewPushLimiter(2)
	r.addDevice("bob", "dev-1", "tok-1")
	pushed, throttled := 0, 0
	for _, p := range []string{postA, postB, "1000000000000000003", "1000000000000000004"} {
		out, err := r.f.Deliver(context.Background(), Event{Type: TypeMention, ActorID: "alice", RecipientIDs: []string{"bob"}, PostID: p, At: t0})
		mustNoErr(t, err)
		if out.Created != 1 {
			t.Fatalf("the row must be written even when the push is throttled: %+v", out)
		}
		pushed += out.Pushed
		throttled += out.Throttled
	}
	if pushed != 2 || throttled != 2 || len(r.repo.rows["bob"]) != 4 {
		t.Errorf("pushed %d throttled %d rows %d, want 2/2/4", pushed, throttled, len(r.repo.rows["bob"]))
	}
	// Another recipient is unaffected.
	r.addDevice("carol", "dev-2", "tok-2")
	out, err := r.f.Deliver(context.Background(), Event{Type: TypeFollow, ActorID: "alice", RecipientIDs: []string{"carol"}, At: t0})
	mustNoErr(t, err)
	if out.Pushed != 1 || out.Throttled != 0 {
		t.Errorf("carol outcome = %+v", out)
	}
}

func TestNewPushLimiterNonPositiveIsUnlimited(t *testing.T) {
	t.Parallel()
	if NewPushLimiter(0) != nil {
		t.Error("0 must mean no limiter")
	}
}

func TestBuildMessageCollapsesByTypeAndKeepsID(t *testing.T) {
	t.Parallel()
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote} {
		t.Run(string(ty), func(t *testing.T) {
			t.Parallel()
			m := buildMessage("tok", Push{Type: ty, NotificationID: "like_" + postA + "_2026101012", PostID: postA, ActorID: "alice"})
			if m.Android.CollapseKey != string(ty) || m.Android.Notification.Tag != string(ty) || m.APNS.Headers["apns-collapse-id"] != string(ty) {
				t.Errorf("collapse = %q / %q / %q, want %q", m.Android.CollapseKey, m.Android.Notification.Tag, m.APNS.Headers["apns-collapse-id"], ty)
			}
			if m.Data["notificationId"] != "like_"+postA+"_2026101012" || m.Data["type"] != string(ty) {
				t.Errorf("data = %v", m.Data)
			}
		})
	}
}

// --- N-5: token validation ---

type fakeValidator struct {
	err   error
	calls int
}

func (v *fakeValidator) Validate(context.Context, string) error { v.calls++; return v.err }

func TestRegisterDevice_FCMValidation(t *testing.T) {
	t.Parallel()
	in := DeviceInput{IdempotencyKey: goodKey, DeviceID: "device-0123456789", Token: "fcm:APA91bH-token", Platform: PlatformAndroid}
	tests := []struct {
		name       string
		validator  TokenValidator
		wantStored bool
		wantCode   connect.Code
	}{
		{"nil validator accepts", nil, true, 0},
		{"valid token", &fakeValidator{}, true, 0},
		{"rejected token is a validation error", &fakeValidator{err: ErrTokenInvalid}, false, connect.CodeInvalidArgument},
		{"wrapped rejection too", &fakeValidator{err: errors.Join(errBoom, ErrTokenInvalid)}, false, connect.CodeInvalidArgument},
		{"permission denied fails open", &fakeValidator{err: &PushError{Code: "PERMISSION_DENIED"}}, true, 0},
		{"unknown error fails open", &fakeValidator{err: errBoom}, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			svc := NewService(Deps{Repo: repo, Directory: newDirectory(), Social: &fakeSocial{}, Seen: &fakeSeen{}, Validator: tt.validator, CursorKey: testKey})
			err := svc.RegisterDevice(context.Background(), "me", in)
			if tt.wantStored {
				mustNoErr(t, err)
				if len(repo.devices["me"]) != 1 {
					t.Errorf("devices = %+v", repo.devices)
				}
				return
			}
			if connectCode(err) != tt.wantCode || len(repo.devices["me"]) != 0 || strings.Contains(err.Error(), in.Token) {
				t.Errorf("err = %v, devices = %+v", err, repo.devices)
			}
		})
	}
	t.Run("shape errors never reach FCM", func(t *testing.T) {
		t.Parallel()
		v := &fakeValidator{}
		svc := NewService(Deps{Repo: newFakeRepo(), Directory: newDirectory(), Social: &fakeSocial{}, Seen: &fakeSeen{}, Validator: v, CursorKey: testKey})
		bad := in
		bad.Token = "a b"
		if err := svc.RegisterDevice(context.Background(), "me", bad); err == nil || v.calls != 0 {
			t.Errorf("err = %v, validator calls = %d", err, v.calls)
		}
	})
}

func TestInvalidTokenCodes(t *testing.T) {
	t.Parallel()
	for _, c := range []string{"INVALID_ARGUMENT", "UNREGISTERED", "SENDER_ID_MISMATCH"} {
		if !invalidTokenCodes[c] {
			t.Errorf("%s must reject the token", c)
		}
	}
	for _, c := range []string{"PERMISSION_DENIED", "QUOTA_EXCEEDED", "UNAVAILABLE", "INTERNAL", "UNKNOWN", "UNAUTHENTICATED"} {
		if invalidTokenCodes[c] {
			t.Errorf("%s must fail open", c)
		}
	}
	if err := (NopValidator{}).Validate(context.Background(), "x"); err != nil {
		t.Error(err)
	}
}

func TestNewRecipientCapNonPositiveIsUnlimited(t *testing.T) {
	t.Parallel()
	if NewRecipientCap(0, 5, nil) != nil || NewRecipientCap(5, 0, nil) != nil {
		t.Error("a non-positive limit must mean no cap")
	}
}
