package posts

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

// TestCreate_PollsGate (ADR-0029 D2, W6-4): a request with a poll while FEATURE_POLLS is off for the caller is
// FEATURE_DISABLED feature=polls with 0 reads, 0 writes and no repo call, and it comes after content_disclosure in the
// ADR-0010 D2 order. A caller with the flag on reaches the W6-4 skeleton (Unimplemented, still 0 repo calls) until W6-5
// stores the poll: a poll is never silently dropped. A request without a poll is unaffected either way.
func TestCreate_PollsGate(t *testing.T) {
	tests := []struct {
		name        string
		in          CreateInput
		wantFeature string // FEATURE_DISABLED feature, "" = not rejected by a flag
		wantUnimpl  bool
	}{
		{"no poll, flag off", CreateInput{}, "", false},
		{"no poll, flag on", CreateInput{PollsEnabled: true}, "", false},
		{"poll, flag off", CreateInput{HasPoll: true}, "polls", false},
		{"poll, flag on", CreateInput{HasPoll: true, PollsEnabled: true}, "", true},
		{"poll and a label, both flags off: content_disclosure first", CreateInput{HasPoll: true, MadeWithAI: true}, "content_disclosure", false},
		{"poll and a label, disclosure on, polls off", CreateInput{HasPoll: true, MadeWithAI: true, DisclosureEnabled: true}, "polls", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			tt.in.IdempotencyKey, tt.in.Text = key1, "hello"
			p, c, err := e.create(tt.in)
			switch {
			case tt.wantFeature != "":
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != tt.wantFeature || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
				}
			case tt.wantUnimpl:
				if connect.CodeOf(err) != connect.CodeUnimplemented || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("err=%v reads=%d writes=%d creates=%d, want Unimplemented and nothing touched", err, c.Reads(), c.Writes(), e.repo.createCalls)
				}
			default:
				if err != nil || p == nil {
					t.Fatalf("post = %v, err = %v", p, err)
				}
			}
		})
	}
}

// pollCaptureSvc records the CreateInput the handler built.
type pollCaptureSvc struct {
	Service
	got CreateInput
}

func (s *pollCaptureSvc) Create(_ context.Context, _ string, in CreateInput) (*Post, error) {
	s.got = in
	return &Post{ID: "1"}, nil
}

// TestServer_CreatePostMapsThePollFlag: the handler sets HasPoll from the request and PollsEnabled from the registry for
// the caller (FEATURE_POLLS), never from the request.
func TestServer_CreatePostMapsThePollFlag(t *testing.T) {
	tests := []struct {
		name     string
		flags    namedFlags
		poll     *postsv1.PollDraft
		wantPoll bool
		wantOn   bool
	}{
		{"no poll, flag off", namedFlags{"posts": true}, nil, false, false},
		{"poll, flag off", namedFlags{"posts": true}, &postsv1.PollDraft{Choices: []string{"a", "b"}}, true, false},
		{"poll, flag on", namedFlags{"posts": true, "polls": true}, &postsv1.PollDraft{Choices: []string{"a", "b"}}, true, true},
		{"no poll, flag on", namedFlags{"posts": true, "polls": true}, nil, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc := &pollCaptureSvc{}
			srv := NewServer(svc, tt.flags)
			if _, err := srv.CreatePost(callerCtx("u1"), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "hi", Poll: tt.poll})); err != nil {
				t.Fatal(err)
			}
			if svc.got.HasPoll != tt.wantPoll || svc.got.PollsEnabled != tt.wantOn {
				t.Errorf("HasPoll=%v PollsEnabled=%v, want %v/%v", svc.got.HasPoll, svc.got.PollsEnabled, tt.wantPoll, tt.wantOn)
			}
		})
	}
}
