package identity

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/handle"
)

func TestHandleCandidates(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{"order base+n then base_n", "riya", []string{"riya2", "riya_2", "riya3", "riya_3", "riya4", "riya_4", "riya5", "riya_5", "riya6", "riya_6", "riya7", "riya_7"}},
		{"trimmed and lower-cased", "  RiYa ", []string{"riya2", "riya_2", "riya3", "riya_3", "riya4", "riya_4", "riya5", "riya_5", "riya6", "riya_6", "riya7", "riya_7"}},
		{"empty input", "", nil},
		{"blank input", "   ", nil},
		{"invalid characters", "ri ya!", nil},
		{"too short", "ab", nil},
		{"too long", "abcdefghijklmnop", nil},
		{"reserved input", "support", nil},
		{"reserved input any case", "Admin", nil},
		{
			"truncated so the longest fits and the input itself is dropped", "abcdefghijklm2",
			[]string{"abcdefghijklm_2", "abcdefghijklm3", "abcdefghijklm_3", "abcdefghijklm4", "abcdefghijklm_4", "abcdefghijklm5", "abcdefghijklm_5", "abcdefghijklm6", "abcdefghijklm_6", "abcdefghijklm7", "abcdefghijklm_7"},
		},
		{"underscore and digit in the input", "riya_2x", []string{"riya_2x2", "riya_2x_2", "riya_2x3", "riya_2x_3", "riya_2x4", "riya_2x_4", "riya_2x5", "riya_2x_5", "riya_2x6", "riya_2x_6", "riya_2x7", "riya_2x_7"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := handleCandidates(tt.input, handleFormatIssue)
			if !slices.Equal(got, tt.want) {
				t.Errorf("candidates(%q) = %v, want %v", tt.input, got, tt.want)
			}
			if len(got) > 12 {
				t.Errorf("%d candidates, want at most 12", len(got))
			}
			for _, c := range got {
				if len(c) > handle.MaxLen || handleFormatIssue(c) != "" {
					t.Errorf("candidate %q is not a valid handle", c)
				}
			}
		})
	}
}

// Each candidate goes through the same check as the input: one the check rejects (reserved, here injected) is dropped.
func TestHandleCandidates_PerCandidateCheck(t *testing.T) {
	t.Parallel()
	if handleFormatIssue("admin") != "reserved" || handleFormatIssue("Support") != "reserved" {
		t.Fatal("handleFormatIssue must reject reserved words")
	}
	stricter := func(h string) string {
		if h == "riya2" || h == "riya_5" {
			return "reserved"
		}
		return handleFormatIssue(h)
	}
	got := handleCandidates("riya", stricter)
	if slices.Contains(got, "riya2") || slices.Contains(got, "riya_5") || len(got) != 10 {
		t.Errorf("candidates = %v, want the two rejected ones dropped", got)
	}
}

func TestSuggestHandles(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		input      string
		taken      map[string]string // handles/{lower} -> uid in the repo
		cached     map[string]string // positive handle cache
		free       []string          // negative "free" cache entries (must be ignored)
		repoErr    error
		want       []string
		wantReads  int      // batched ResolveHandles calls
		wantLookup []string // ids of the one batched read
		wantErr    bool
	}{
		{"first five free in order", "riya", nil, nil, nil, nil, []string{"riya2", "riya_2", "riya3", "riya_3", "riya4"}, 1, nil, false},
		{
			"taken ones skipped", "riya", map[string]string{"riya2": "u1", "riya_3": "u2"}, nil, nil, nil,
			[]string{"riya_2", "riya3", "riya4", "riya_4", "riya5"}, 1, nil, false,
		},
		{
			"positive cache skips the read for that candidate", "riya", nil, map[string]string{"riya2": "u1", "riya_2": "u2"}, nil, nil,
			[]string{"riya3", "riya_3", "riya4", "riya_4", "riya5"}, 1,
			[]string{"riya3", "riya_3", "riya4", "riya_4", "riya5", "riya_5", "riya6", "riya_6", "riya7", "riya_7"}, false,
		},
		{
			"negative cache is not trusted", "riya", map[string]string{"riya2": "u1"}, nil, []string{"riya2"}, nil,
			[]string{"riya_2", "riya3", "riya_3", "riya4", "riya_4"}, 1, nil, false,
		},
		{
			"fewer than five", "riya", map[string]string{
				"riya2": "a", "riya_2": "a", "riya3": "a", "riya_3": "a", "riya4": "a", "riya_4": "a",
				"riya5": "a", "riya_5": "a", "riya6": "a", "riya_6": "a", "riya7": "a",
			}, nil, nil, nil, []string{"riya_7"}, 1, nil, false,
		},
		{"empty input reads nothing", "", nil, nil, nil, nil, []string{}, 0, nil, false},
		{"invalid input reads nothing", "no way!", nil, nil, nil, nil, []string{}, 0, nil, false},
		{"reserved input reads nothing", "admin", nil, nil, nil, nil, []string{}, 0, nil, false},
		{"repo error", "riya", nil, nil, nil, errors.New("boom"), nil, 1, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			repo := newFakeRepo()
			for h, uid := range tt.taken {
				repo.handles[h] = uid
			}
			repo.resolveManyErr = tt.repoErr
			svc := newTestService(repo)
			for h, uid := range tt.cached {
				svc.cache.SetHandleUID(h, uid)
			}
			for _, h := range tt.free {
				svc.cache.SetHandleFree(h)
			}
			got, err := svc.SuggestHandles(context.Background(), tt.input)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if !tt.wantErr && (got == nil || !slices.Equal(got, tt.want)) {
				t.Errorf("SuggestHandles(%q) = %#v, want %v", tt.input, got, tt.want)
			}
			if repo.resolveManyCalls != tt.wantReads || repo.resolveCalls != 0 {
				t.Errorf("batched reads = %d, single reads = %d; want %d and 0", repo.resolveManyCalls, repo.resolveCalls, tt.wantReads)
			}
			if tt.wantLookup != nil && !slices.Equal(repo.resolveManyArgs[0], tt.wantLookup) {
				t.Errorf("batched read = %v, want %v", repo.resolveManyArgs[0], tt.wantLookup)
			}
			if len(got) > MaxHandleSuggestions {
				t.Errorf("%d suggestions, want at most %d", len(got), MaxHandleSuggestions)
			}
			if repo.createCalls+repo.updateCalls+repo.changeCalls != 0 {
				t.Error("SuggestHandles must never write")
			}
		})
	}
}

// A taken candidate learned from the read lands in the positive cache, so the next call skips it without a read.
func TestSuggestHandles_WarmsPositiveCache(t *testing.T) {
	t.Parallel()
	repo := newFakeRepo()
	repo.handles["riya2"] = "u1"
	svc := newTestService(repo)
	if _, err := svc.SuggestHandles(context.Background(), "riya"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SuggestHandles(context.Background(), "riya"); err != nil {
		t.Fatal(err)
	}
	if slices.Contains(repo.resolveManyArgs[1], "riya2") {
		t.Errorf("second read = %v, want riya2 answered from the positive cache", repo.resolveManyArgs[1])
	}
}

func TestServer_SuggestHandles_Flag(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		opts     []ServerOption
		wantOn   bool
		wantList []string
	}{
		{"no checker wired", nil, false, nil},
		{"flag off", []ServerOption{WithFlagChecker(fakeFlagChecker{})}, false, nil},
		{"on for another uid only", []ServerOption{WithFlagChecker(fakeFlagChecker{"other/" + HandleSuggestionsFlag: true})}, false, nil},
		{"on for the caller", []ServerOption{WithFlagChecker(fakeFlagChecker{"uid-1/" + HandleSuggestionsFlag: true})}, true, []string{"riya2", "riya_2"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc := &fakeService{suggestions: []string{"riya2", "riya_2"}}
			client, closeFn := newTestServerHTTPWithClaims(t, svc, authn.Claims{UID: "uid-1", EmailVerified: true, SignInProvider: "google.com"}, tt.opts...)
			defer closeFn()
			resp, err := client.SuggestHandles(context.Background(), connect.NewRequest(&identityv1.SuggestHandlesRequest{Handle: "riya"}))
			if tt.wantOn {
				if err != nil || !slices.Equal(resp.Msg.GetHandles(), tt.wantList) {
					t.Fatalf("SuggestHandles = %v, %v; want %v", resp, err, tt.wantList)
				}
				return
			}
			var cerr *connect.Error
			if !errors.As(err, &cerr) || cerr.Code() != connect.CodeFailedPrecondition {
				t.Fatalf("err = %v, want FAILED_PRECONDITION", err)
			}
			var feature string
			for _, d := range cerr.Details() {
				if v, derr := d.Value(); derr == nil {
					if info, ok := v.(*commonv1.ErrorDetail); ok && info.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
						feature = info.GetMetadata()["feature"]
					}
				}
			}
			if feature != HandleSuggestionsFlag {
				t.Errorf("FEATURE_DISABLED feature = %q, want %q (err %v)", feature, HandleSuggestionsFlag, cerr)
			}
			if svc.suggestCalls != 0 {
				t.Error("the service (and so Firestore) must not be reached with the flag off")
			}
		})
	}
}

// The handle limit the truncation relies on.
func TestSuggestionBaseFitsMaxLen(t *testing.T) {
	t.Parallel()
	longest := strings.Repeat("a", suggestionBaseMaxLen) + "_" + "7"
	if len(longest) != handle.MaxLen {
		t.Errorf("longest candidate is %d chars, want %d", len(longest), handle.MaxLen)
	}
}
