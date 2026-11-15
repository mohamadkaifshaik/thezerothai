package location

import (
	"context"
	"sort"
	"strconv"
	"sync"
	"time"
)

// fakeRepo mirrors FirestoreRepo's rules in memory (the emulator tests prove the real one): idempotency replay and reuse,
// current consent, the daily cap counted from records since IST midnight, and the writes.
type fakeRepo struct {
	mu       sync.Mutex
	areas    map[string]StoredArea
	consents map[string][]ConsentRecord // per uid, id order
	idem     map[string]string          // key -> request hash
	writes   int                        // committed transactions that wrote more than the idempotency doc
	reads    int
	err      error
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{areas: map[string]StoredArea{}, consents: map[string][]ConsentRecord{}, idem: map[string]string{}}
}

func (f *fakeRepo) Area(_ context.Context, uid string) (*StoredArea, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	if f.err != nil {
		return nil, f.err
	}
	if a, ok := f.areas[uid]; ok {
		return &a, nil
	}
	return nil, nil
}

func (f *fakeRepo) latest(uid string) *ConsentRecord {
	cs := f.consents[uid]
	if len(cs) == 0 {
		return nil
	}
	c := cs[len(cs)-1]
	return &c
}

func (f *fakeRepo) LatestConsent(_ context.Context, uid string) (*ConsentRecord, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	if f.err != nil {
		return nil, f.err
	}
	return f.latest(uid), nil
}

func (f *fakeRepo) state(uid string) State {
	if a, ok := f.areas[uid]; ok {
		return State{Area: &a}
	}
	return State{Latest: f.latest(uid)}
}

// replay answers the idempotency check: (result, true, err) when the key is known.
func (f *fakeRepo) replay(uid, key, hash string) (WriteResult, bool, error) {
	h, ok := f.idem[key]
	if !ok {
		return WriteResult{}, false, nil
	}
	if h != hash {
		return WriteResult{}, true, ErrKeyReused
	}
	return WriteResult{Outcome: Replayed, State: f.state(uid)}, true, nil
}

func (f *fakeRepo) SetArea(_ context.Context, p SetParams) (WriteResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return WriteResult{}, f.err
	}
	if res, ok, err := f.replay(p.UID, p.IdemKey, p.RequestHash); ok {
		return res, err
	}
	now := p.Now.UTC()
	cur, has := f.areas[p.UID]
	var res WriteResult
	switch {
	case !has || cur.ConsentCopyVersion < p.MinCopyVersion:
		if p.Grant == nil {
			return WriteResult{}, ErrConsentRequired
		}
		n := 0
		for _, c := range f.consents[p.UID] {
			if !c.At.Before(istMidnight(now)) {
				n++
			}
		}
		if n >= p.ConsentsPerDay {
			return WriteResult{}, ErrConsentLimit
		}
		a := StoredArea{AreaID: p.AreaID, Purposes: []string{PurposePlansNearby}, ConsentCopyVersion: p.Grant.CopyVersion, AdultConfirmedAt: now, ConsentedAt: now, UpdatedAt: now}
		f.areas[p.UID] = a
		f.append(p.UID, ConsentRecord{ID: p.ConsentID, Purpose: PurposePlansNearby, Action: ActionGranted, CopyVersion: p.Grant.CopyVersion, AdultConfirmed: p.Grant.AdultConfirmed, At: now})
		f.writes++
		res = WriteResult{Outcome: Written, State: State{Area: &a}}
	case cur.AreaID == p.AreaID:
		res = WriteResult{Outcome: Unchanged, State: State{Area: &cur}}
	default:
		cur.AreaID, cur.UpdatedAt = p.AreaID, now
		f.areas[p.UID] = cur
		f.writes++
		res = WriteResult{Outcome: Written, State: State{Area: &cur}}
	}
	f.idem[p.IdemKey] = p.RequestHash
	return res, nil
}

func (f *fakeRepo) append(uid string, c ConsentRecord) {
	f.consents[uid] = append(f.consents[uid], c)
	sort.Slice(f.consents[uid], func(i, j int) bool { return f.consents[uid][i].ID < f.consents[uid][j].ID })
}

func (f *fakeRepo) ClearArea(_ context.Context, p ClearParams) (WriteResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return WriteResult{}, f.err
	}
	if res, ok, err := f.replay(p.UID, p.IdemKey, p.RequestHash); ok {
		return res, err
	}
	var res WriteResult
	if cur, ok := f.areas[p.UID]; ok {
		delete(f.areas, p.UID)
		rec := ConsentRecord{ID: p.ConsentID, Purpose: PurposePlansNearby, Action: ActionWithdrawn, CopyVersion: cur.ConsentCopyVersion, At: p.Now.UTC()}
		f.append(p.UID, rec)
		f.writes++
		res = WriteResult{Outcome: Written, State: State{Latest: &rec}}
	} else {
		res = WriteResult{Outcome: Unchanged, State: State{Latest: f.latest(p.UID)}}
	}
	f.idem[p.IdemKey] = p.RequestHash
	return res, nil
}

// fakeIDs mints increasing 19-digit ids.
type fakeIDs struct {
	mu sync.Mutex
	n  int64
}

func (g *fakeIDs) Generate() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.n++
	s := strconv.FormatInt(g.n, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return s
}

// fakeFlags is a FlagChecker: on lists the uids the flag is on for; off is the kill switch.
type fakeFlags struct {
	on  map[string]bool
	off bool
}

func (f fakeFlags) Enabled(uid, name string) bool { return name == FlagName && !f.off && f.on[uid] }
func (f fakeFlags) GloballyOff(name string) bool  { return name == FlagName && f.off }

// fakeClock is a settable clock.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }
