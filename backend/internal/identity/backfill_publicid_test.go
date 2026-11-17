package identity

import (
	"context"
	"errors"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fakeBackfillStore models users/{uid} (publicId, status) and publicIds/{id} -> uid with the transaction rules of
// FirestoreRepo: re-read and re-check the status, create-only lookups, field-level publicId.
type fakeBackfillStore struct {
	users   map[string]Profile
	lookups map[string]string
	// beforeTx runs at the start of every transaction (to change the account between the page read and the write).
	beforeTx func(uid string)
	scanErr  error
	txErr    map[string]error
	scans    []string
	mints    int
	repairs  int
}

func newFakeBackfillStore() *fakeBackfillStore {
	return &fakeBackfillStore{users: map[string]Profile{}, lookups: map[string]string{}, txErr: map[string]error{}}
}

func (f *fakeBackfillStore) user(uid, publicID string, st AccountStatus) {
	f.users[uid] = Profile{UserID: uid, PublicID: publicID, Status: st}
}

func (f *fakeBackfillStore) ScanPublicIDs(_ context.Context, after string, limit int) ([]PublicIDScanRow, error) {
	f.scans = append(f.scans, after)
	if f.scanErr != nil {
		return nil, f.scanErr
	}
	uids := make([]string, 0, len(f.users))
	for uid := range f.users {
		if uid > after {
			uids = append(uids, uid)
		}
	}
	sort.Strings(uids)
	if len(uids) > limit {
		uids = uids[:limit]
	}
	rows := make([]PublicIDScanRow, 0, len(uids))
	for _, uid := range uids {
		p := f.users[uid]
		row := PublicIDScanRow{UID: uid, PublicID: p.PublicID, Status: p.Status}
		if ValidPublicID(p.PublicID) {
			row.LookupOwner, row.LookupExists = f.lookups[p.PublicID]
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// txUser is the in-transaction read and status rule; ok=false carries the outcome.
func (f *fakeBackfillStore) txUser(uid string) (Profile, PublicIDTxResult, bool) {
	if f.beforeTx != nil {
		f.beforeTx(uid)
	}
	p, found := f.users[uid]
	switch {
	case !found:
		return p, PublicIDTxGone, false
	case p.Status == AccountStatusDeleting:
		return p, PublicIDTxDeleting, false
	case p.Status != AccountStatusActive && p.Status != AccountStatusSuspended:
		return p, PublicIDTxOtherStatus, false
	}
	return p, 0, true
}

func (f *fakeBackfillStore) MintPublicIDForBackfill(_ context.Context, uid, publicID string, _ time.Time) (PublicIDTxResult, error) {
	if err := f.txErr[uid]; err != nil {
		return 0, err
	}
	p, skip, ok := f.txUser(uid)
	switch {
	case !ok:
		return skip, nil
	case p.PublicID != "":
		return PublicIDTxAlreadyOK, nil
	}
	if _, taken := f.lookups[publicID]; taken {
		return 0, ErrPublicIDCollision
	}
	f.mints++
	p.PublicID = publicID
	f.users[uid] = p
	f.lookups[publicID] = uid
	return PublicIDTxWrote, nil
}

func (f *fakeBackfillStore) RepairPublicIDLookup(_ context.Context, uid, publicID string, _ time.Time) (PublicIDTxResult, error) {
	if err := f.txErr[uid]; err != nil {
		return 0, err
	}
	p, skip, ok := f.txUser(uid)
	switch {
	case !ok:
		return skip, nil
	case p.PublicID != publicID:
		return PublicIDTxGone, nil
	}
	if owner, exists := f.lookups[publicID]; exists {
		if owner == uid {
			return PublicIDTxAlreadyOK, nil
		}
		return PublicIDTxForeign, nil
	}
	f.repairs++
	f.lookups[publicID] = uid
	return PublicIDTxWrote, nil
}

func TestBackfillPublicIDsPage_Classifies(t *testing.T) {
	for _, tc := range []struct {
		name     string
		seed     func(f *fakeBackfillStore)
		dryRun   bool
		want     PublicIDBackfillCounts
		conflict string // the reason of the one conflict, "" = none
		check    func(t *testing.T, f *fakeBackfillStore)
	}{
		{name: "mints an ACTIVE account without an id", seed: func(f *fakeBackfillStore) { f.user("a1", "", AccountStatusActive) },
			want: PublicIDBackfillCounts{Scanned: 1, Minted: 1},
			check: func(t *testing.T, f *fakeBackfillStore) {
				id := f.users["a1"].PublicID
				if !ValidPublicID(id) || f.lookups[id] != "a1" {
					t.Errorf("a1 id %q lookups %v", id, f.lookups)
				}
			}},
		{name: "mints a SUSPENDED account", seed: func(f *fakeBackfillStore) { f.user("s1", "", AccountStatusSuspended) },
			want: PublicIDBackfillCounts{Scanned: 1, Minted: 1}},
		{name: "never mints a DELETING account", seed: func(f *fakeBackfillStore) { f.user("d1", "", AccountStatusDeleting) },
			want:  PublicIDBackfillCounts{Scanned: 1, SkippedDeleting: 1},
			check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "never repairs a DELETING account", seed: func(f *fakeBackfillStore) { f.user("d2", pid('d'), AccountStatusDeleting) },
			want:  PublicIDBackfillCounts{Scanned: 1, SkippedDeleting: 1},
			check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "skips an unknown status", seed: func(f *fakeBackfillStore) { f.user("x1", "", AccountStatusUnspecified) },
			want: PublicIDBackfillCounts{Scanned: 1, SkippedStatus: 1}},
		{name: "an account with its lookup is ok", seed: func(f *fakeBackfillStore) {
			f.user("o1", pid('k'), AccountStatusActive)
			f.lookups[pid('k')] = "o1"
		}, want: PublicIDBackfillCounts{Scanned: 1, AlreadyOK: 1}, check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "repairs a missing lookup with the same id", seed: func(f *fakeBackfillStore) { f.user("r1", pid('r'), AccountStatusSuspended) },
			want: PublicIDBackfillCounts{Scanned: 1, Repaired: 1},
			check: func(t *testing.T, f *fakeBackfillStore) {
				if f.lookups[pid('r')] != "r1" || f.users["r1"].PublicID != pid('r') || f.mints != 0 {
					t.Errorf("lookups %v id %q mints %d; want the same id re-created", f.lookups, f.users["r1"].PublicID, f.mints)
				}
			}},
		{name: "a lookup naming another account is a conflict, untouched", seed: func(f *fakeBackfillStore) {
			f.user("c1", pid('c'), AccountStatusActive)
			f.lookups[pid('c')] = "someone-else"
		}, want: PublicIDBackfillCounts{Scanned: 1, Conflicts: 1}, conflict: PublicIDConflictForeignLookup,
			check: func(t *testing.T, f *fakeBackfillStore) {
				wantNoWrites(t, f)
				if f.lookups[pid('c')] != "someone-else" {
					t.Error("the foreign lookup changed")
				}
			}},
		{name: "an undecodable lookup (no owner) is a conflict, untouched", seed: func(f *fakeBackfillStore) {
			f.user("q1", pid('q'), AccountStatusActive)
			f.lookups[pid('q')] = ""
		}, want: PublicIDBackfillCounts{Scanned: 1, Conflicts: 1}, conflict: PublicIDConflictForeignLookup,
			check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "a malformed stored id is a conflict, untouched", seed: func(f *fakeBackfillStore) { f.user("m1", "NotAnID", AccountStatusActive) },
			want: PublicIDBackfillCounts{Scanned: 1, Conflicts: 1}, conflict: PublicIDConflictInvalidID,
			check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "dry run counts and writes nothing", dryRun: true, seed: func(f *fakeBackfillStore) {
			f.user("a1", "", AccountStatusActive)
			f.user("r1", pid('r'), AccountStatusActive)
			f.user("d1", "", AccountStatusDeleting)
		}, want: PublicIDBackfillCounts{Scanned: 3, Minted: 1, Repaired: 1, SkippedDeleting: 1},
			check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "an account that turned DELETING after the page read is skipped", seed: func(f *fakeBackfillStore) {
			f.user("t1", "", AccountStatusActive)
			f.beforeTx = func(uid string) { f.user(uid, "", AccountStatusDeleting) }
		}, want: PublicIDBackfillCounts{Scanned: 1, SkippedDeleting: 1}, check: func(t *testing.T, f *fakeBackfillStore) { wantNoWrites(t, f) }},
		{name: "an account minted after the page read is ok", seed: func(f *fakeBackfillStore) {
			f.user("t2", "", AccountStatusActive)
			f.beforeTx = func(uid string) { f.user(uid, pid('t'), AccountStatusActive); f.lookups[pid('t')] = uid }
		}, want: PublicIDBackfillCounts{Scanned: 1, AlreadyOK: 1}},
		{name: "an account erased after the page read is gone", seed: func(f *fakeBackfillStore) {
			f.user("g1", "", AccountStatusActive)
			f.beforeTx = func(uid string) { delete(f.users, uid) }
		}, want: PublicIDBackfillCounts{Scanned: 1, Gone: 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeBackfillStore()
			tc.seed(f)
			res, err := BackfillPublicIDsPage(context.Background(), f, "", PublicIDBackfillOptions{DryRun: tc.dryRun})
			if err != nil {
				t.Fatal(err)
			}
			if res.Counts != tc.want {
				t.Errorf("counts = %+v, want %+v", res.Counts, tc.want)
			}
			switch {
			case tc.conflict == "" && len(res.ConflictList) != 0:
				t.Errorf("conflicts = %+v, want none", res.ConflictList)
			case tc.conflict != "" && (len(res.ConflictList) != 1 || res.ConflictList[0].Reason != tc.conflict):
				t.Errorf("conflicts = %+v, want one %s", res.ConflictList, tc.conflict)
			}
			if tc.check != nil {
				tc.check(t, f)
			}
		})
	}
}

func wantNoWrites(t *testing.T, f *fakeBackfillStore) {
	t.Helper()
	if f.mints != 0 || f.repairs != 0 {
		t.Errorf("mints %d repairs %d, want no writes", f.mints, f.repairs)
	}
}

func TestBackfillPublicIDsPage_CollisionRetry(t *testing.T) {
	t.Run("a taken id is redrawn", func(t *testing.T) {
		f := newFakeBackfillStore()
		f.user("a1", "", AccountStatusActive)
		f.lookups[pid('1')], f.lookups[pid('2')] = "x", "y"
		res, err := BackfillPublicIDsPage(context.Background(), f, "", PublicIDBackfillOptions{NewID: seqIDs(pid('1'), pid('2'), pid('3'))})
		if err != nil {
			t.Fatal(err)
		}
		if res.Counts.Minted != 1 || res.Counts.Collisions != 2 || f.users["a1"].PublicID != pid('3') {
			t.Errorf("counts %+v id %q; want minted on the third draw", res.Counts, f.users["a1"].PublicID)
		}
	})
	t.Run("three collisions stop the page before the account", func(t *testing.T) {
		f := newFakeBackfillStore()
		f.user("a0", "", AccountStatusActive)
		f.user("a1", "", AccountStatusActive)
		for _, c := range []byte("123") {
			f.lookups[pid(c)] = "x"
		}
		res, err := BackfillPublicIDsPage(context.Background(), f, "", PublicIDBackfillOptions{NewID: seqIDs(pid('0'), pid('1'), pid('2'), pid('3'))})
		if !errors.Is(err, ErrPublicIDCollision) {
			t.Fatalf("err = %v, want ErrPublicIDCollision", err)
		}
		if res.Last != "a0" || res.Counts.Scanned != 1 || res.Counts.Minted != 1 || f.users["a1"].PublicID != "" {
			t.Errorf("last %q counts %+v; want a0 done and a1 untouched", res.Last, res.Counts)
		}
	})
}

func TestBackfillPublicIDsPage_PagingAndIdempotency(t *testing.T) {
	f := newFakeBackfillStore()
	for _, uid := range []string{"u1", "u2", "u3", "u4", "u5"} {
		f.user(uid, "", AccountStatusActive)
	}
	opts := PublicIDBackfillOptions{Limit: 2}
	var total PublicIDBackfillCounts
	after := ""
	for range 10 {
		res, err := BackfillPublicIDsPage(context.Background(), f, after, opts)
		if err != nil {
			t.Fatal(err)
		}
		total, after = total.Add(res.Counts), res.Last
		if !res.More {
			break
		}
	}
	if total.Minted != 5 || after != "u5" || strings.Join(f.scans, ",") != ",u2,u4" {
		t.Fatalf("total %+v after %q scans %q", total, after, f.scans)
	}
	// Resume after u3 reads only u4 and u5; a second full run writes nothing.
	res, err := BackfillPublicIDsPage(context.Background(), f, "u3", PublicIDBackfillOptions{})
	if err != nil || res.Counts.Scanned != 2 || res.Counts.AlreadyOK != 2 {
		t.Fatalf("resume = %+v, %v", res.Counts, err)
	}
	mints := f.mints
	res, err = BackfillPublicIDsPage(context.Background(), f, "", PublicIDBackfillOptions{})
	if err != nil || res.Counts.AlreadyOK != 5 || f.mints != mints || res.More {
		t.Fatalf("second run = %+v, %v, mints %d -> %d", res.Counts, err, mints, f.mints)
	}
}

func TestBackfillPublicIDsPage_ErrorsCarryNoIDs(t *testing.T) {
	f := newFakeBackfillStore()
	f.user("Ab3dEf6hIj9kLm2nOp5qRs8tUv1w", "", AccountStatusActive)
	f.user("Zz3dEf6hIj9kLm2nOp5qRs8tUv1w", pid('z'), AccountStatusActive)
	f.txErr["Ab3dEf6hIj9kLm2nOp5qRs8tUv1w"] = errors.New("rpc error: documents/users/Ab3dEf6hIj9kLm2nOp5qRs8tUv1w and publicIds/" + pid('1'))
	f.txErr["Zz3dEf6hIj9kLm2nOp5qRs8tUv1w"] = errors.New("rpc error: users/Zz3dEf6hIj9kLm2nOp5qRs8tUv1w publicIds/" + pid('z'))
	_, err := BackfillPublicIDsPage(context.Background(), f, "", PublicIDBackfillOptions{NewID: seqIDs(pid('1'))})
	if err == nil {
		t.Fatal("want the mint error")
	}
	delete(f.txErr, "Ab3dEf6hIj9kLm2nOp5qRs8tUv1w")
	_, rerr := BackfillPublicIDsPage(context.Background(), f, "Ab3dEf6hIj9kLm2nOp5qRs8tUv1w", PublicIDBackfillOptions{})
	if rerr == nil {
		t.Fatal("want the repair error")
	}
	for _, e := range []error{err, rerr} {
		msg := logger.CauseChain(e)
		for _, raw := range []string{"Ab3dEf6hIj9kLm2nOp5qRs8tUv1w", "Zz3dEf6hIj9kLm2nOp5qRs8tUv1w", pid('1'), pid('z')} {
			if strings.Contains(msg, raw) {
				t.Errorf("error %q carries a raw id", msg)
			}
		}
	}
	f.scanErr = errors.New("scan failed after Zz3dEf6hIj9kLm2nOp5qRs8tUv1w")
	if _, err := BackfillPublicIDsPage(context.Background(), f, "Zz3dEf6hIj9kLm2nOp5qRs8tUv1w", PublicIDBackfillOptions{}); err == nil ||
		strings.Contains(logger.CauseChain(err), "Zz3dEf6hIj9kLm2nOp5qRs8tUv1w") {
		t.Errorf("scan error = %v", err)
	}
}

// deadlineStore records whether every call carried its own deadline.
type deadlineStore struct {
	*fakeBackfillStore
	missing int
}

func (d *deadlineStore) note(ctx context.Context) {
	if _, ok := ctx.Deadline(); !ok {
		d.missing++
	}
}

func (d *deadlineStore) ScanPublicIDs(ctx context.Context, after string, limit int) ([]PublicIDScanRow, error) {
	d.note(ctx)
	return d.fakeBackfillStore.ScanPublicIDs(ctx, after, limit)
}

func (d *deadlineStore) MintPublicIDForBackfill(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	d.note(ctx)
	return d.fakeBackfillStore.MintPublicIDForBackfill(ctx, uid, publicID, now)
}

func (d *deadlineStore) RepairPublicIDLookup(ctx context.Context, uid, publicID string, now time.Time) (PublicIDTxResult, error) {
	d.note(ctx)
	return d.fakeBackfillStore.RepairPublicIDLookup(ctx, uid, publicID, now)
}

func TestBackfillPublicIDsPage_CallTimeoutPerCall(t *testing.T) {
	f := newFakeBackfillStore()
	f.user("a1", "", AccountStatusActive)
	f.user("r1", pid('r'), AccountStatusActive)
	d := &deadlineStore{fakeBackfillStore: f}
	res, err := BackfillPublicIDsPage(context.Background(), d, "", PublicIDBackfillOptions{CallTimeout: time.Minute})
	if err != nil || res.Counts.Minted != 1 || res.Counts.Repaired != 1 {
		t.Fatalf("res %+v err %v", res.Counts, err)
	}
	if d.missing != 0 {
		t.Errorf("%d store calls had no deadline", d.missing)
	}
}
