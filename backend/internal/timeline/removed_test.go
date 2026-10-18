package timeline

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeRemovals is a posts.Removals that records its cutoffs and charges a fixed number of reads per call.
type fakeRemovals struct {
	ids       []string
	truncated bool
	err       error
	reads     int64
	cutoffs   []time.Time
}

func (f *fakeRemovals) RemovedSince(ctx context.Context, cutoff time.Time) ([]string, bool, error) {
	f.cutoffs = append(f.cutoffs, cutoff)
	budget.FromContext(ctx).AddReads(f.reads)
	return f.ids, f.truncated, f.err
}

func withRemovals(r *rig, f *fakeRemovals) *fakeRemovals {
	r.srv.deps.Removals = f
	return f
}

func TestRemovedIDs_HomeRefreshCarriesTheIDsAndUsesTheTokenIssueTime(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	cold := r.mustHome("", "", 20)
	issued := r.clock.Now()
	f := withRemovals(r, &fakeRemovals{ids: []string{"9", "8"}, reads: 1})

	// A refresh two days later: the cutoff is the token's issue time minus the lag, whatever the posts' times are.
	r.clock.Advance(48 * time.Hour)
	resp, counter, err := r.home("me", cold.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(resp.RemovedIds, []string{"9", "8"}) {
		t.Fatalf("removed_ids = %v", resp.RemovedIds)
	}
	if want := []time.Time{issued.Add(-removalLag)}; len(f.cutoffs) != 1 || !f.cutoffs[0].Equal(want[0]) {
		t.Fatalf("cutoffs = %v, want %v", f.cutoffs, want)
	}
	if got, ok := r.info.Get(fieldRemoved); !ok || fmt.Sprint(got) != "2" {
		t.Fatalf("logged %s = %v, want 2", fieldRemoved, got)
	}
	// The log's reads are charged to the request: the same refresh without a log costs one read less.
	r2 := newRig(t)
	r2.follow("me", 3)
	c2 := r2.mustHome("", "", 20)
	r2.clock.Advance(48 * time.Hour)
	_, base, err := r2.home("me", c2.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if counter.Reads() != base.Reads()+1 {
		t.Fatalf("reads = %d, want %d (+1 for the log)", counter.Reads(), base.Reads()+1)
	}
}

func TestRemovedIDs_UserRefreshCarriesTheIDs(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.seedUser("bob", 3)
	cold := r.mustUser("me", "bob", false, "", "", 20)
	f := withRemovals(r, &fakeRemovals{ids: []string{"7"}})
	r.clock.Advance(time.Minute)
	resp, _, err := r.user("me", "bob", false, cold.SinceToken, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(resp.RemovedIds, []string{"7"}) || len(f.cutoffs) != 1 {
		t.Fatalf("removed_ids = %v, log calls = %d", resp.RemovedIds, len(f.cutoffs))
	}
}

// Only a since_token refresh consults the log: cold opens and page tokens never carry removed_ids and never cost
// a log read (ADR-0016 D10).
func TestRemovedIDs_OnlyRefreshConsultsTheLog(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	f := withRemovals(r, &fakeRemovals{ids: []string{"1"}, reads: 1})
	cold := r.mustHome("", "", 5)
	if len(f.cutoffs) != 0 || len(cold.RemovedIds) != 0 {
		t.Fatalf("cold open: log calls=%d removed_ids=%v", len(f.cutoffs), cold.RemovedIds)
	}
	if cold.NextPageToken != "" {
		if page := r.mustHome("", cold.NextPageToken, 5); len(f.cutoffs) != 0 || len(page.RemovedIds) != 0 {
			t.Fatalf("page: log calls=%d removed_ids=%v", len(f.cutoffs), page.RemovedIds)
		}
	}
	u := newRig(t)
	u.seedUser("bob", 30)
	uf := withRemovals(u, &fakeRemovals{ids: []string{"1"}})
	uc := u.mustUser("me", "bob", false, "", "", 5)
	if up := u.mustUser("me", "bob", false, "", uc.NextPageToken, 5); len(uf.cutoffs) != 0 || len(up.RemovedIds) != 0 {
		t.Fatalf("user page: log calls=%d removed_ids=%v", len(uf.cutoffs), up.RemovedIds)
	}
}

// A log that cannot answer completely rejects the refresh like an expired since_token, before any post, graph or
// profile-dependent read (home) / any post read (user): the client drops the token and cold-opens.
func TestRemovedIDs_TruncatedRejectsTheSinceToken(t *testing.T) {
	t.Parallel()
	t.Run("home", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		r.follow("me", 3)
		cold := r.mustHome("", "", 20)
		withRemovals(r, &fakeRemovals{truncated: true, reads: 1})
		r.posts.queries, r.graph.calls = nil, nil
		_, counter, err := r.home("me", cold.SinceToken, "", 20)
		wantField(t, err, fieldSince)
		if counter.Reads() != 1 || len(r.posts.queries) != 0 || len(r.graph.calls) != 0 {
			t.Fatalf("reads=%d queries=%v graph=%v, want only the log read", counter.Reads(), r.posts.queries, r.graph.calls)
		}
		if got, ok := r.info.Get(fieldRemovedReset); !ok || got != true {
			t.Fatalf("logged %s = %v, want true", fieldRemovedReset, got)
		}
	})
	t.Run("user", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		r.seedUser("bob", 3)
		cold := r.mustUser("me", "bob", false, "", "", 20)
		withRemovals(r, &fakeRemovals{truncated: true})
		r.clock.Advance(5 * time.Minute)
		r.posts.queries = nil
		_, _, err := r.user("me", "bob", false, cold.SinceToken, "", 20)
		wantField(t, err, fieldSince)
		if len(r.posts.queries) != 0 {
			t.Fatalf("a rejected refresh ran post queries %v", r.posts.queries)
		}
	})
}

func TestRemovedIDs_LogErrorFailsTheRefreshWithoutPostReads(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	cold := r.mustHome("", "", 20)
	withRemovals(r, &fakeRemovals{err: errors.New("firestore down")})
	r.posts.queries = nil
	_, _, err := r.home("me", cold.SinceToken, "", 20)
	var ae *apierr.Error
	if err == nil || (errors.As(err, &ae) && ae.Metadata["field"] != "") {
		t.Fatalf("err = %v, want a non-validation failure", err)
	}
	if len(r.posts.queries) != 0 {
		t.Fatalf("queries after a log failure: %v", r.posts.queries)
	}
}

func TestRemovedIDs_NoLogWiredIsANoop(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	cold := r.mustHome("", "", 20)
	resp := r.mustHome(cold.SinceToken, "", 20)
	if len(resp.RemovedIds) != 0 {
		t.Fatalf("removed_ids = %v with no log", resp.RemovedIds)
	}
}

// The lag must cover a card served from a stale post cache plus a stale log cache (see removalLag).
func TestRemovalLag_CoversBothCaches(t *testing.T) {
	t.Parallel()
	if removalLag < 2*60*time.Second {
		t.Fatalf("removalLag = %v, want at least 2 x CACHE_TTL (60 s max)", removalLag)
	}
}

// namedFlags enables only the listed flag names.
type namedFlags map[string]bool

func (f namedFlags) Enabled(_, name string) bool { return f[name] }

// TestRemovedIDs_FlagOffReadsNothing: FEATURE_REMOVED_IDS off for the caller means a refresh never consults the log
// (0 reads, no rejection even if the log would truncate), while the posts flag still lets the RPC through.
func TestRemovedIDs_FlagOffReadsNothing(t *testing.T) {
	t.Parallel()
	r := newRig(t)
	r.follow("me", 3)
	cold := r.mustHome("", "", 20)
	f := withRemovals(r, &fakeRemovals{ids: []string{"9"}, truncated: true, reads: 50})
	r.srv.deps.Flags = namedFlags{"posts": true}
	r.clock.Advance(time.Hour)
	resp, _, err := r.home("me", cold.SinceToken, "", 20)
	if err != nil {
		t.Fatalf("refresh with the flag off: %v", err)
	}
	if len(f.cutoffs) != 0 || len(resp.RemovedIds) != 0 {
		t.Fatalf("log consulted %d times, removed_ids=%v, want 0/none", len(f.cutoffs), resp.RemovedIds)
	}
}
