package posts

import (
	"strconv"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const testCommunityID = "1234567890123456789"

// TestCreate_CommunitiesGate: a request with community_id set is FEATURE_DISABLED feature=communities with 0
// reads, 0 writes and no repo call. With the flag off for the caller that is the permanent answer; with it on it is the temporary
// "not built yet" refusal (builds the gate), so a set community_id can never create an ordinary public post. It comes after
// polls in the order. A request without community_id is unaffected either way.
func TestCreate_CommunitiesGate(t *testing.T) {
	tests := []struct {
		name        string
		in          CreateInput
		wantFeature string // FEATURE_DISABLED feature, "" = not rejected by a flag
	}{
		{"no community, flag off", CreateInput{}, ""},
		{"no community, flag on", CreateInput{CommunitiesEnabled: true}, ""},
		{"community, flag off", CreateInput{CommunityID: testCommunityID}, "communities"},
		{"community, flag on (gate not built)", CreateInput{CommunityID: testCommunityID, CommunitiesEnabled: true}, "communities"},
		{"malformed community id is still the flag first", CreateInput{CommunityID: "not-an-id"}, "communities"},
		{"community and a poll, both flags off: polls first", CreateInput{CommunityID: testCommunityID, Poll: goodPoll()}, "polls"},
		{"community and a poll, polls on: communities", CreateInput{CommunityID: testCommunityID, Poll: goodPoll(), PollsEnabled: true}, "communities"},
		{"community and a label, disclosure off: content_disclosure first", CreateInput{CommunityID: testCommunityID, MadeWithAI: true}, "content_disclosure"},
		{"community and a reply, replies off: replies first", CreateInput{CommunityID: testCommunityID, ReplyToPostID: rReply1}, "replies"},
		{"community and a reply, replies on: communities (W5-26 owns the combination rule)", CreateInput{CommunityID: testCommunityID, ReplyToPostID: rReply1, RepliesEnabled: true}, "communities"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newCreateEnv()
			tt.in.IdempotencyKey, tt.in.Text = key1, "hello"
			p, c, err := e.create(tt.in)
			if tt.wantFeature != "" {
				ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if ae.Metadata["feature"] != tt.wantFeature || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
					t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
				}
				return
			}
			if err != nil || p == nil {
				t.Fatalf("post = %v, err = %v", p, err)
			}
		})
	}
}

// TestServer_CommunitiesFlagModes (off/allowlist/percent/on): the handler maps community_id from the request and
// CommunitiesEnabled from the registry for the caller, never from the request; the service then refuses a set community_id with
// FEATURE_DISABLED feature=communities in every mode, 0 reads and writes.
func TestServer_CommunitiesFlagModes(t *testing.T) {
	t.Parallel()
	in, out := "uid-in", "uid-out"
	var inPct, outPct string
	pct50 := flags.NewRegistry(flags.Spec{Name: CommunitiesFlagName, Mode: flags.Percent, Percent: 50})
	for i := 0; inPct == "" || outPct == ""; i++ {
		uid := "pct-" + strconv.Itoa(i)
		if pct50.Enabled(uid, CommunitiesFlagName) {
			inPct = uid
		} else {
			outPct = uid
		}
	}
	allow := map[string]struct{}{in: {}}
	tests := []struct {
		name string
		spec flags.Spec
		uid  string
		want bool
	}{
		{"off", flags.Spec{Mode: flags.Off, Allowlist: allow}, in, false},
		{"allowlist, listed", flags.Spec{Mode: flags.Allowlist, Allowlist: allow}, in, true},
		{"allowlist, not listed", flags.Spec{Mode: flags.Allowlist, Allowlist: allow}, out, false},
		{"percent 50, in bucket", flags.Spec{Mode: flags.Percent, Percent: 50}, inPct, true},
		{"percent 50, out of bucket", flags.Spec{Mode: flags.Percent, Percent: 50}, outPct, false},
		{"percent 0, allowlisted", flags.Spec{Mode: flags.Percent, Percent: 0, Allowlist: allow}, in, true},
		{"on", flags.Spec{Mode: flags.On}, out, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			tt.spec.Name = CommunitiesFlagName
			reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, tt.spec)
			capture := &pollCaptureSvc{}
			_, err := NewServer(capture, reg).CreatePost(callerCtx(tt.uid), connect.NewRequest(&postsv1.CreatePostRequest{
				IdempotencyKey: key1, Text: "hi", CommunityId: testCommunityID}))
			if err != nil {
				t.Fatal(err)
			}
			if capture.got.CommunityID != testCommunityID || capture.got.CommunitiesEnabled != tt.want {
				t.Fatalf("CommunityID=%q CommunitiesEnabled=%v, want %q/%v", capture.got.CommunityID, capture.got.CommunitiesEnabled, testCommunityID, tt.want)
			}
			e := newCreateEnv()
			capture.got.IdempotencyKey, capture.got.Text = key1, "hi"
			_, c, err := e.create(capture.got)
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if ae.Metadata["feature"] != "communities" || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
			}
		})
	}
	t.Run("no community_id never reads the flag into a refusal", func(t *testing.T) {
		t.Parallel()
		capture := &pollCaptureSvc{}
		reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On})
		if _, err := NewServer(capture, reg).CreatePost(callerCtx(in), connect.NewRequest(&postsv1.CreatePostRequest{IdempotencyKey: key1, Text: "hi"})); err != nil {
			t.Fatal(err)
		}
		if capture.got.CommunityID != "" || capture.got.CommunitiesEnabled {
			t.Fatalf("CommunityID=%q CommunitiesEnabled=%v, want empty/false", capture.got.CommunityID, capture.got.CommunitiesEnabled)
		}
	})
}
