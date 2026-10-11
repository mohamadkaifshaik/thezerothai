package posts

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

const (
	mid1 = "0000000000000000201"
	mid2 = "0000000000000000202"
)

// fakeJobs records PostDeleted calls.
type fakeJobs struct {
	calls []fakeJobCall
	err   error
}

type fakeJobCall struct {
	uid, postID string
	mediaIDs    []string
}

func (j *fakeJobs) PostDeleted(_ context.Context, uid, postID string, mediaIDs []string) error {
	j.calls = append(j.calls, fakeJobCall{uid, postID, mediaIDs})
	return j.err
}

func TestCreate_MediaPassedToRepo(t *testing.T) {
	tests := []struct {
		name string
		in   CreateInput
		ok   bool
	}{
		{"one image with text", CreateInput{Text: "hi", MediaIDs: []string{mid1}}, true},
		{"image only: empty text allowed", CreateInput{Text: "", MediaIDs: []string{mid1}}, true},
		{"blank text with image", CreateInput{Text: " \U0000200B ", MediaIDs: []string{mid1, mid2}}, true},
		{"parallel alt texts", CreateInput{Text: "hi", MediaIDs: []string{mid1, mid2}, MediaAltTexts: []string{"a dog", ""}}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			in := tt.in
			in.IdempotencyKey, in.MediaEnabled = key1, true
			p, c, err := e.create(in)
			if err != nil {
				t.Fatal(err)
			}
			got := e.repo.lastCreate
			if !reflect.DeepEqual(got.MediaIDs, in.MediaIDs) || !reflect.DeepEqual(got.MediaAlts, in.MediaAltTexts) {
				t.Fatalf("repo got ids=%v alts=%v", got.MediaIDs, got.MediaAlts)
			}
			if p == nil || c.Writes() != 4 {
				t.Fatalf("post=%v writes=%d (the fake models the base 4)", p, c.Writes())
			}
		})
	}
}

func TestCreate_MediaValidation(t *testing.T) {
	long := strings.Repeat("a", 1001)
	tests := []struct {
		name  string
		in    CreateInput
		field string
	}{
		{"five images", CreateInput{Text: "x", MediaIDs: []string{mid1, mid2, "0000000000000000203", "0000000000000000204", "0000000000000000205"}}, "media_ids"},
		{"malformed id", CreateInput{Text: "x", MediaIDs: []string{"abc"}}, "media_ids"},
		{"path-like id", CreateInput{Text: "x", MediaIDs: []string{"../users/uid-bob"}}, "media_ids"},
		{"duplicate id", CreateInput{Text: "x", MediaIDs: []string{mid1, mid1}}, "media_ids"},
		{"alts not parallel", CreateInput{Text: "x", MediaIDs: []string{mid1}, MediaAltTexts: []string{"a", "b"}}, "media_alt_texts"},
		{"alts without ids", CreateInput{Text: "x", MediaAltTexts: []string{"a"}}, "media_alt_texts"},
		{"alt too long", CreateInput{Text: "x", MediaIDs: []string{mid1}, MediaAltTexts: []string{long}}, "media_alt_texts"},
		{"alt control char", CreateInput{Text: "x", MediaIDs: []string{mid1}, MediaAltTexts: []string{"a\x00b"}}, "media_alt_texts"},
		{"no media, empty text", CreateInput{Text: "  "}, "text"},
		{"media but text has control char", CreateInput{Text: "a\x00", MediaIDs: []string{mid1}}, "text"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			in := tt.in
			in.IdempotencyKey, in.MediaEnabled = key1, true
			_, c, err := e.create(in)
			ae := wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if ae.Metadata["field"] != tt.field || c.Reads() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("field=%q reads=%d createCalls=%d", ae.Metadata["field"], c.Reads(), e.repo.createCalls)
			}
		})
	}
}

func TestCreate_MediaDisabledByFlag(t *testing.T) {
	e := newCreateEnv()
	_, c, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", MediaIDs: []string{mid1}, MediaEnabled: false})
	ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if ae.Metadata["feature"] != "media" || c.Reads() != 0 || e.repo.createCalls != 0 {
		t.Fatalf("feature=%q reads=%d", ae.Metadata["feature"], c.Reads())
	}
}

func TestCreate_MediaNotReadyIsOneAnswer(t *testing.T) {
	e := newCreateEnv()
	e.repo.createErr = fmt.Errorf("wrapped: %w", ErrMediaNotReady)
	_, _, err := e.create(CreateInput{IdempotencyKey: key1, Text: "x", MediaIDs: []string{mid1}, MediaEnabled: true})
	_ = wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
}

func TestCreate_MediaIdempotency(t *testing.T) {
	e := newCreateEnv()
	in := CreateInput{IdempotencyKey: key1, Text: "x", MediaIDs: []string{mid1}, MediaEnabled: true}
	first, _, err := e.create(in)
	if err != nil {
		t.Fatal(err)
	}
	replay, c, err := e.create(in)
	if err != nil || replay.ID != first.ID || c.Writes() != 0 {
		t.Fatalf("replay: id=%v err=%v writes=%d", replay, err, c.Writes())
	}
	other := in
	other.MediaIDs = []string{mid2}
	_, _, err = e.create(other)
	_ = wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// TestRequestHash_TextOnlyUnchanged pins the pre-P4 format, so idempotency records written before P4 still match.
func TestRequestHash_TextOnlyUnchanged(t *testing.T) {
	want := idempotency.HashRequest(fmt.Sprintf("v1|text=%q|media=%q|alts=%q|reply=%q|quote=%q", "hello", "", "", "", ""))
	if got := requestHash("hello", nil, nil); got != want {
		t.Fatalf("text-only hash changed: %s != %s", got, want)
	}
	if requestHash("hello", []string{mid1}, nil) == want || requestHash("hello", []string{mid1}, []string{"a"}) == requestHash("hello", []string{mid1}, []string{"b"}) {
		t.Fatal("media ids and alt texts must change the hash")
	}
}

func TestDelete_PublishesPostDeleteJob(t *testing.T) {
	tests := []struct {
		name     string
		media    []MediaRef
		jobsErr  error
		wantJobs int
	}{
		{"no images: no job", nil, nil, 0},
		{"two images: one job", []MediaRef{{ID: mid1}, {ID: mid2}}, nil, 1},
		{"publish failure does not fail the delete", []MediaRef{{ID: mid1}}, errors.New("pubsub down"), 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			jobs := &fakeJobs{err: tt.jobsErr}
			e := newDeleteEnv()
			e.svc.jobs = jobs
			e.repo.docs[pidMine].Media = tt.media
			c, outcome, err := e.del(pidMine)
			if err != nil || outcome != outcomeDeleted {
				t.Fatalf("err=%v outcome=%s", err, outcome)
			}
			if c.Writes() != 1 || c.Deletes() != 1 {
				t.Fatalf("writes=%d deletes=%d: publishing must not touch Firestore", c.Writes(), c.Deletes())
			}
			if len(jobs.calls) != tt.wantJobs {
				t.Fatalf("jobs = %d, want %d", len(jobs.calls), tt.wantJobs)
			}
			if tt.wantJobs == 1 {
				got := jobs.calls[0]
				if got.uid != testUID || got.postID != pidMine || len(got.mediaIDs) != len(tt.media) || got.mediaIDs[0] != mid1 {
					t.Fatalf("job = %+v", got)
				}
			}
		})
	}
}

func TestDelete_NoJobForNoopCases(t *testing.T) {
	jobs := &fakeJobs{}
	e := newDeleteEnv()
	e.svc.jobs = jobs
	e.repo.docs[pidOther].Media = []MediaRef{{ID: mid1}}
	if _, _, err := e.del(pidOther); err != nil { // someone else's post
		t.Fatal(err)
	}
	if _, _, err := e.del("0000000000000000999"); err != nil { // unknown post
		t.Fatal(err)
	}
	if len(jobs.calls) != 0 {
		t.Fatalf("jobs = %v, want none: a no-op delete must never publish", jobs.calls)
	}
}

func TestToProto_MediaCarriesThumb(t *testing.T) {
	p := post(pidMine, testUID)
	p.Media = []MediaRef{{ID: mid1, URL: "https://m/1.webp", ThumbURL: "https://m/1_t.webp", Width: 800, Height: 600, Blurhash: "LEHV6n", AltText: "dog"}}
	out := ToProto(p)
	if len(out.Media) != 1 {
		t.Fatalf("media = %d", len(out.Media))
	}
	m := out.Media[0]
	if m.MediaId != mid1 || m.Url != "https://m/1.webp" || m.ThumbUrl != "https://m/1_t.webp" || m.Width != 800 || m.Height != 600 || m.Blurhash != "LEHV6n" || m.AltText != "dog" {
		t.Fatalf("media ref = %+v", m)
	}
}
