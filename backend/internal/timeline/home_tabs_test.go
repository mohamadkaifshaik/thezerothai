package timeline

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	listA = "0000000000000000101"
	listB = "0000000000000000102"
	listC = "0000000000000000103"
	listD = "0000000000000000104"
	listE = "0000000000000000105"
	listF = "0000000000000000106"
	idemK = "0123456789abcdef0123"
)

// fakeTabsStore is HomeTabsStore over a map, with the idempotency semantics of the identity adapter. current can lag behind
// stored to model a stale profile cache.
type fakeTabsStore struct {
	mu       sync.Mutex
	stored   []identity.HomeTab
	cached   []identity.HomeTab // what Current answers; nil follows stored
	useCache bool
	seen     map[string]string // key -> hash
	writes   int
}

func (f *fakeTabsStore) Current(context.Context, string) ([]identity.HomeTab, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.useCache {
		return slices.Clone(f.cached), nil
	}
	return slices.Clone(f.stored), nil
}

func (f *fakeTabsStore) Replace(_ context.Context, _, key, hash string, next func([]identity.HomeTab) ([]identity.HomeTab, error)) ([]identity.HomeTab, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.seen == nil {
		f.seen = map[string]string{}
	}
	if h, ok := f.seen[key]; ok {
		if h != hash {
			return nil, identity.ErrKeyReused
		}
		return slices.Clone(f.stored), nil
	}
	nxt, err := next(slices.Clone(f.stored))
	if err != nil {
		return nil, err
	}
	f.seen[key] = hash
	if !slices.Equal(f.stored, nxt) {
		f.stored = nxt
		f.writes++
	}
	return slices.Clone(nxt), nil
}

// fakeReader is lists.Reader over a map; gets counts the Get calls (the cost driver).
type fakeReader struct {
	mu    sync.Mutex
	views map[string]lists.ListView
	gets  int
}

func (r *fakeReader) Get(_ context.Context, _, id string) (lists.ListView, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gets++
	v, ok := r.views[id]
	if !ok {
		return lists.ListView{}, lists.ErrNotFound
	}
	return v, nil
}
func (r *fakeReader) Members(context.Context, string, string) (lists.ListMembers, error) {
	return lists.ListMembers{}, lists.ErrNotFound
}
func (r *fakeReader) OwnedBy(context.Context, string) ([]lists.List, error) { return nil, nil }

func view(id, name, owner string) lists.ListView {
	return lists.ListView{Header: lists.Header{ID: id, Name: name}, Owner: identity.Profile{UserID: owner}}
}

func tabsServer(fl lists.FlagChecker, st HomeTabsStore, rd lists.Reader, max int) *Server {
	return NewServer(Deps{}, WithHomeTabs(HomeTabsDeps{Store: st, Lists: rd, Flags: fl, Max: max}))
}

func listsOn() lists.FlagChecker {
	return flags.NewRegistry(flags.Spec{Name: lists.FlagName, Mode: flags.On})
}

func sendTabs(s *Server, uid, key string, ids ...string) (*timelinev1.SetHomeTabsResponse, error) {
	req := &timelinev1.SetHomeTabsRequest{IdempotencyKey: key}
	for _, id := range ids {
		req.Tabs = append(req.Tabs, &commonv1.HomeTab{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: id, Title: "ignored on input"})
	}
	resp, err := s.SetHomeTabs(ctxFor(uid), connect.NewRequest(req))
	if err != nil {
		return nil, err
	}
	return resp.Msg, nil
}

func wantAPIErr(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta map[string]string) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err = %v, want an apierr", err)
	}
	if ae.Code != code || ae.Reason != reason {
		t.Fatalf("got %v/%v (%s), want %v/%v", ae.Code, ae.Reason, ae.Message, code, reason)
	}
	for k, v := range meta {
		if ae.Metadata[k] != v {
			t.Fatalf("metadata[%s] = %q, want %q", k, ae.Metadata[k], v)
		}
	}
}

func tabIDs(resp *timelinev1.SetHomeTabsResponse) []string {
	var out []string
	for _, t := range resp.GetTabs() {
		out = append(out, t.GetId())
	}
	return out
}

func TestSetHomeTabs_Rules(t *testing.T) {
	t.Parallel()
	views := map[string]lists.ListView{
		listA: view(listA, "Mine", "me"),
		listB: view(listB, "Theirs", "other"),
		listC: view(listC, "C", "me"),
		listD: view(listD, "D", "me"),
		listE: view(listE, "E", "me"),
		listF: view(listF, "F", "me"),
	}
	t.Run("six tabs is LIMIT_REACHED home_tabs with no reads", func(t *testing.T) {
		t.Parallel()
		rd := &fakeReader{views: views}
		_, err := sendTabs(tabsServer(listsOn(), &fakeTabsStore{}, rd, 5), "me", idemK, listA, listB, listC, listD, listE, listF)
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "home_tabs"})
		if rd.gets != 0 {
			t.Fatalf("lists read %d times, want 0", rd.gets)
		}
	})
	t.Run("five tabs fit, titles: own name, foreign empty", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{}
		resp, err := sendTabs(tabsServer(listsOn(), st, &fakeReader{views: views}, 5), "me", idemK, listA, listB, listC, listD, listE)
		if err != nil {
			t.Fatal(err)
		}
		if got := tabIDs(resp); !slices.Equal(got, []string{listA, listB, listC, listD, listE}) {
			t.Fatalf("tabs = %v", got)
		}
		if st.stored[0].Title != "Mine" || st.stored[1].Title != "" {
			t.Fatalf("titles = %q, %q; want own name and empty for a foreign list", st.stored[0].Title, st.stored[1].Title)
		}
	})
	t.Run("shape errors are VALIDATION tabs", func(t *testing.T) {
		t.Parallel()
		cases := map[string][]*commonv1.HomeTab{
			"duplicate":   {{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: listA}, {Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: listA}},
			"unspecified": {{Id: listA}},
			"community":   {{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_COMMUNITY, Id: listA}},
			"bad id":      {{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: "12"}},
		}
		for name, tabs := range cases {
			rd := &fakeReader{views: views}
			s := tabsServer(listsOn(), &fakeTabsStore{}, rd, 5)
			_, err := s.SetHomeTabs(ctxFor("me"), connect.NewRequest(&timelinev1.SetHomeTabsRequest{IdempotencyKey: idemK, Tabs: tabs}))
			wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
			if rd.gets != 0 {
				t.Fatalf("%s: lists read %d times, want 0", name, rd.gets)
			}
		}
	})
	t.Run("bad idempotency key", func(t *testing.T) {
		t.Parallel()
		_, err := sendTabs(tabsServer(listsOn(), &fakeTabsStore{}, &fakeReader{}, 5), "me", "short", listA)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
	})
	t.Run("missing and unreadable lists give one identical answer", func(t *testing.T) {
		t.Parallel()
		s := tabsServer(listsOn(), &fakeTabsStore{}, &fakeReader{views: map[string]lists.ListView{}}, 5)
		_, err := sendTabs(s, "me", idemK, listA)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
	})
	t.Run("a stored tab is kept without a read, even when its list is gone", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{stored: []identity.HomeTab{{Kind: "LIST", ID: listA, Title: "Old"}, {Kind: "LIST", ID: listB}}}
		rd := &fakeReader{views: map[string]lists.ListView{}}
		resp, err := sendTabs(tabsServer(listsOn(), st, rd, 5), "me", idemK, listB, listA)
		if err != nil {
			t.Fatal(err)
		}
		if rd.gets != 0 {
			t.Fatalf("lists read %d times, want 0 for stored tabs", rd.gets)
		}
		if got := tabIDs(resp); !slices.Equal(got, []string{listB, listA}) || st.stored[1].Title != "Old" {
			t.Fatalf("tabs = %v, stored = %+v", got, st.stored)
		}
	})
	t.Run("same order again with a new key writes only the idempotency record", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{}
		s := tabsServer(listsOn(), st, &fakeReader{views: views}, 5)
		if _, err := sendTabs(s, "me", idemK, listA, listC); err != nil {
			t.Fatal(err)
		}
		if _, err := sendTabs(s, "me", "another-key-0123456", listA, listC); err != nil {
			t.Fatal(err)
		}
		if st.writes != 1 {
			t.Fatalf("users writes = %d, want 1 (the second call changed nothing)", st.writes)
		}
	})
	t.Run("replay answers the stored tabs; the same key with other tabs is IDEMPOTENCY_KEY_REUSED", func(t *testing.T) {
		t.Parallel()
		st := &fakeTabsStore{}
		s := tabsServer(listsOn(), st, &fakeReader{views: views}, 5)
		if _, err := sendTabs(s, "me", idemK, listA); err != nil {
			t.Fatal(err)
		}
		resp, err := sendTabs(s, "me", idemK, listA)
		if err != nil || len(resp.GetTabs()) != 1 {
			t.Fatalf("replay = %v, %v", resp, err)
		}
		_, err = sendTabs(s, "me", idemK, listC)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED, nil)
	})
	t.Run("a tab absent from the fresh read and from the stale cache is validated on the second pass", func(t *testing.T) {
		t.Parallel()
		// The cache says listA is stored; the document no longer has it. Pass one skips the read; the transaction refuses;
		// pass two reads every sent tab and succeeds.
		st := &fakeTabsStore{useCache: true, cached: []identity.HomeTab{{Kind: "LIST", ID: listA}}}
		rd := &fakeReader{views: views}
		resp, err := sendTabs(tabsServer(listsOn(), st, rd, 5), "me", idemK, listA)
		if err != nil || rd.gets != 1 || len(resp.GetTabs()) != 1 {
			t.Fatalf("resp = %v, err = %v, gets = %d", resp, err, rd.gets)
		}
		// And a stale cache over a list that is not readable fails closed.
		st2 := &fakeTabsStore{useCache: true, cached: []identity.HomeTab{{Kind: "LIST", ID: listA}}}
		_, err = sendTabs(tabsServer(listsOn(), st2, &fakeReader{views: map[string]lists.ListView{}}, 5), "me", idemK, listA)
		wantAPIErr(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "tabs"})
	})
	t.Run("stored tabs of a hidden kind count toward the cap and are kept after the sent ones", func(t *testing.T) {
		t.Parallel()
		var hidden []identity.HomeTab
		for i := range 5 {
			hidden = append(hidden, identity.HomeTab{Kind: identity.HomeTabKindCommunity, ID: fmt.Sprintf("000000000000000020%d", i)})
		}
		st := &fakeTabsStore{stored: slices.Clone(hidden)}
		_, err := sendTabs(tabsServer(listsOn(), st, &fakeReader{views: views}, 5), "me", idemK, listA)
		wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "home_tabs"})
		if !slices.Equal(st.stored, hidden) {
			t.Fatalf("a refused call changed the stored tabs: %+v", st.stored)
		}
		st3 := &fakeTabsStore{stored: hidden[:2]}
		resp, err := sendTabs(tabsServer(listsOn(), st3, &fakeReader{views: views}, 5), "me", idemK, listA)
		if err != nil || len(resp.GetTabs()) != 1 {
			t.Fatalf("resp = %v, err = %v (hidden kinds are omitted from the response)", resp, err)
		}
		if len(st3.stored) != 3 || st3.stored[0].ID != listA || st3.stored[1].Kind != identity.HomeTabKindCommunity {
			t.Fatalf("stored = %+v, want the sent tab first, then the kept hidden ones", st3.stored)
		}
	})
}

// TestSetHomeTabs_FlagModes: LIST tabs need FEATURE_LISTS on for the caller in every mode (off, allowlist, percent, on) and the
// refusal comes before any read; an empty request is accepted whatever the flag says, and stored LIST tabs are kept (hidden)
// while the flag is off for the caller.
func TestSetHomeTabs_FlagModes(t *testing.T) {
	t.Parallel()
	allow := map[string]struct{}{"in": {}}
	tests := []struct {
		name    string
		spec    flags.Spec
		uid     string
		wantOff bool
	}{
		{"off", flags.Spec{Name: lists.FlagName, Mode: flags.Off, Allowlist: allow}, "in", true},
		{"allowlist, listed", flags.Spec{Name: lists.FlagName, Mode: flags.Allowlist, Allowlist: allow}, "in", false},
		{"allowlist, unlisted", flags.Spec{Name: lists.FlagName, Mode: flags.Allowlist, Allowlist: allow}, "out", true},
		{"percent 0", flags.Spec{Name: lists.FlagName, Mode: flags.Percent}, "in", true},
		{"percent 100", flags.Spec{Name: lists.FlagName, Mode: flags.Percent, Percent: 100}, "out", false},
		{"on", flags.Spec{Name: lists.FlagName, Mode: flags.On}, "out", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			fl := flags.NewRegistry(tt.spec)
			rd := &fakeReader{views: map[string]lists.ListView{listA: view(listA, "A", tt.uid)}}
			st := &fakeTabsStore{stored: []identity.HomeTab{{Kind: "LIST", ID: listC, Title: "kept"}}}
			s := tabsServer(fl, st, rd, 5)
			resp, err := sendTabs(s, tt.uid, idemK, listA)
			if tt.wantOff {
				wantAPIErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "lists"})
				if rd.gets != 0 || st.writes != 0 {
					t.Fatalf("a refused call read %d lists and wrote %d times", rd.gets, st.writes)
				}
				// Unpin everything is accepted; the LIST tab stored while the flag was on survives, hidden.
				resp, err = sendTabs(s, tt.uid, "empty-request-key-01", []string{}...)
				if err != nil || len(resp.GetTabs()) != 0 {
					t.Fatalf("empty request = %v, %v", resp, err)
				}
				if len(st.stored) != 1 || st.stored[0].ID != listC {
					t.Fatalf("stored = %+v, want the hidden LIST tab kept", st.stored)
				}
				return
			}
			if err != nil || len(resp.GetTabs()) != 1 {
				t.Fatalf("resp = %v, err = %v", resp, err)
			}
		})
	}
}

func TestSetHomeTabs_NotWiredAndUnauthenticated(t *testing.T) {
	t.Parallel()
	s := NewServer(Deps{})
	_, err := s.SetHomeTabs(ctxFor("me"), connect.NewRequest(&timelinev1.SetHomeTabsRequest{IdempotencyKey: idemK}))
	if connect.CodeOf(err) != connect.CodeUnimplemented {
		t.Fatalf("unwired code = %v, want Unimplemented", connect.CodeOf(err))
	}
	s = tabsServer(listsOn(), &fakeTabsStore{}, &fakeReader{}, 5)
	_, err = s.SetHomeTabs(context.Background(), connect.NewRequest(&timelinev1.SetHomeTabsRequest{IdempotencyKey: idemK}))
	wantAPIErr(t, err, connect.CodeUnauthenticated, 0, nil)
}
