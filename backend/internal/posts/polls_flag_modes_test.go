package posts

import (
	"strconv"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestServer_PollsFlagModes (off/allowlist/percent/on, ADR-0029 D12): the handler's PollsEnabled follows the real registry for
// the caller, and the service refuses a poll exactly when it is false (FEATURE_DISABLED feature=polls, 0 reads and writes),
// before any Firestore access. The percent rows pick one caller on either side of the bucket so the row is deterministic.
func TestServer_PollsFlagModes(t *testing.T) {
	t.Parallel()
	in, out := "uid-in", "uid-out"
	var inPct, outPct string
	pct50 := flags.NewRegistry(flags.Spec{Name: PollsFlagName, Mode: flags.Percent, Percent: 50})
	for i := 0; inPct == "" || outPct == ""; i++ {
		uid := "pct-" + strconv.Itoa(i)
		if pct50.Enabled(uid, PollsFlagName) {
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
			tt.spec.Name = PollsFlagName
			reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, tt.spec)
			capture := &pollCaptureSvc{}
			_, err := NewServer(capture, reg).CreatePost(callerCtx(tt.uid), connect.NewRequest(&postsv1.CreatePostRequest{
				IdempotencyKey: key1, Text: "hi", Poll: &postsv1.PollDraft{Choices: []string{"a", "b"}, DurationMinutes: 60}}))
			if err != nil {
				t.Fatal(err)
			}
			if capture.got.PollsEnabled != tt.want {
				t.Fatalf("PollsEnabled = %v, want %v", capture.got.PollsEnabled, tt.want)
			}
			e := newCreateEnv()
			capture.got.IdempotencyKey, capture.got.Text = key1, "hi"
			_, c, err := e.create(capture.got)
			if tt.want {
				if err != nil {
					t.Fatalf("enabled caller refused: %v", err)
				}
				return
			}
			ae := wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if ae.Metadata["feature"] != "polls" || c.Reads() != 0 || c.Writes() != 0 || e.repo.createCalls != 0 {
				t.Fatalf("feature=%q reads=%d writes=%d creates=%d", ae.Metadata["feature"], c.Reads(), c.Writes(), e.repo.createCalls)
			}
		})
	}
}
