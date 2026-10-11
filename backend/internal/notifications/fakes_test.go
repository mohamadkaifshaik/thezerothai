package notifications

import (
	"context"
	"errors"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

var errBoom = errors.New("boom")

// fakeRepo is an in-memory Repo.
type fakeRepo struct {
	mu        sync.Mutex
	rows      map[string]map[string]Notification // uid -> id -> row
	devices   map[string][]Device                // uid -> devices (insertion order)
	createErr error
	listErr   error
	devErr    error
	creates   int
	addActors int
	removed   []string // "uid/deviceID/onlyIfToken"
	lastList  ListQuery
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{rows: map[string]map[string]Notification{}, devices: map[string][]Device{}}
}

func (f *fakeRepo) Create(_ context.Context, uid string, n Notification) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates++
	if f.createErr != nil {
		return false, f.createErr
	}
	if f.rows[uid] == nil {
		f.rows[uid] = map[string]Notification{}
	}
	if _, ok := f.rows[uid][n.ID]; ok {
		return false, nil
	}
	f.rows[uid][n.ID] = n
	return true, nil
}

func (f *fakeRepo) AddActor(_ context.Context, uid, id string, a Actor, at time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.addActors++
	n, ok := f.rows[uid][id]
	if !ok {
		return nil
	}
	have := false
	for _, x := range n.ActorIDs {
		have = have || x == a.UserID
	}
	if !have {
		n.ActorIDs = append(n.ActorIDs, a.UserID)
	}
	n.Actor, n.CreatedAt = a, at
	f.rows[uid][id] = n
	return nil
}

// List mirrors the Firestore query: (createdAt, id) descending, strictly after Before, strictly before After.
func (f *fakeRepo) List(_ context.Context, uid string, q ListQuery) ([]Notification, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastList = q
	if f.listErr != nil {
		return nil, f.listErr
	}
	var all []Notification
	for _, n := range f.rows[uid] {
		all = append(all, n)
	}
	sort.Slice(all, func(i, j int) bool {
		if !all[i].CreatedAt.Equal(all[j].CreatedAt) {
			return all[i].CreatedAt.After(all[j].CreatedAt)
		}
		return all[i].ID > all[j].ID
	})
	var out []Notification
	for _, n := range all {
		if q.Before != nil && !sortsBefore(n, *q.Before) {
			continue
		}
		if q.After != nil && !sortsAfter(n, *q.After) {
			continue
		}
		out = append(out, n)
		if len(out) == q.Limit {
			break
		}
	}
	return out, nil
}

// sortsBefore: n is strictly older than c in (createdAt, id) order.
func sortsBefore(n Notification, c cursor.Cursor) bool {
	return n.CreatedAt.Before(c.CreatedAt) || (n.CreatedAt.Equal(c.CreatedAt) && n.ID < c.DocID)
}

// sortsAfter: n is strictly newer than c.
func sortsAfter(n Notification, c cursor.Cursor) bool {
	return n.CreatedAt.After(c.CreatedAt) || (n.CreatedAt.Equal(c.CreatedAt) && n.ID > c.DocID)
}

func (f *fakeRepo) Devices(_ context.Context, uid string, limit int) ([]Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.devErr != nil {
		return nil, f.devErr
	}
	d := f.devices[uid]
	if len(d) > limit {
		d = d[:limit]
	}
	return append([]Device(nil), d...), nil
}

func (f *fakeRepo) RegisterDevice(_ context.Context, uid string, d Device, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.devices[uid] = append(f.devices[uid], d)
	return nil
}

func (f *fakeRepo) RemoveDevice(_ context.Context, uid, deviceID, onlyIfToken string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.removed = append(f.removed, uid+"/"+deviceID+"/"+onlyIfToken)
	kept := f.devices[uid][:0:0]
	for _, d := range f.devices[uid] {
		if d.ID != deviceID {
			kept = append(kept, d)
		}
	}
	f.devices[uid] = kept
	return nil
}

// fakeDirectory serves profiles; uids not in the map are "gone, suspended or deleting".
type fakeDirectory struct {
	profiles  map[string]identity.Profile
	err       error
	forgotten []string
	seenAt    time.Time
}

func newDirectory(uids ...string) *fakeDirectory {
	d := &fakeDirectory{profiles: map[string]identity.Profile{}}
	for _, u := range uids {
		d.profiles[u] = identity.Profile{UserID: u, Handle: "h_" + u, DisplayName: "N " + u, AvatarURL: "https://x/" + u, Status: identity.AccountStatusActive}
	}
	return d
}

func (d *fakeDirectory) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	if d.err != nil {
		return nil, d.err
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			if u == uids[0] && !d.seenAt.IsZero() {
				p.NotificationsSeenAt = d.seenAt
			}
			out[u] = p
		}
	}
	return out, nil
}

func (d *fakeDirectory) LookupProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, []string, error) {
	p, err := d.GetProfiles(ctx, uids)
	return p, nil, err
}

func (d *fakeDirectory) ResolveHandles(context.Context, []string) (map[string]string, error) {
	return nil, nil
}

func (d *fakeDirectory) Forget(uids ...string) { d.forgotten = append(d.forgotten, uids...) }

// fakeSocial serves per-recipient graph snapshots.
type fakeSocial struct {
	snaps map[string]graph.Snapshot
	err   error
}

func (s *fakeSocial) Snapshot(_ context.Context, uid string) (graph.Snapshot, error) {
	if s.err != nil {
		return graph.Snapshot{}, s.err
	}
	return s.snaps[uid], nil
}

// fakeSender records pushes; tokens in dead answer ErrTokenUnregistered, tokens in fail answer errBoom.
type fakeSender struct {
	mu   sync.Mutex
	sent []sentPush
	dead map[string]bool
	fail map[string]bool
}

type sentPush struct {
	Token string
	Push  Push
}

func (s *fakeSender) Send(_ context.Context, token string, p Push) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.dead[token]:
		return ErrTokenUnregistered
	case s.fail[token]:
		return errBoom
	}
	s.sent = append(s.sent, sentPush{token, p})
	return nil
}

type fakeFlags map[string]bool

func (f fakeFlags) Enabled(uid, name string) bool { return name == FlagName && f[uid] }

type allFlags struct{}

func (allFlags) Enabled(_, name string) bool { return name == FlagName }

type fakePublisher struct {
	data [][]byte
	err  error
}

func (p *fakePublisher) Publish(_ context.Context, data []byte) error {
	if p.err != nil {
		return p.err
	}
	p.data = append(p.data, data)
	return nil
}

type fakeSeen struct {
	uid string
	at  time.Time
	err error
}

func (s *fakeSeen) MarkNotificationsSeen(_ context.Context, uid string, at time.Time) error {
	s.uid, s.at = uid, at
	return s.err
}

func mustNoErr(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

const (
	postA = "1000000000000000001"
	postB = "1000000000000000002"
)
