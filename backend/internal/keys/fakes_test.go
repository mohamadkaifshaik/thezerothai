package keys

import (
	"bytes"
	"context"
	"sync"
	"time"
)

// fakeRepo mirrors the Firestore repository's rules in memory: the cap of 5 devices, key mismatch, the 24 h last-seen
// refresh, the pool cap with excess dropped (oldest stay), dedupe by package bytes, unknown device, remove of a missing
// device succeeding, and the claim rules (one-time package consumed, last resort reused, exclusion, inactivity).
type fakeRepo struct {
	mu         sync.Mutex
	devices    map[string][]Device // per uid, oldest first
	pool       map[string][][]byte // uid|deviceID -> packages in insertion order
	lastResort map[string][]byte
	err        error
	calls      int
	// listCalls and activeCalls count the device reads of GetDevices (List and ActiveDevices) separately from calls.
	listCalls, activeCalls int
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{devices: map[string][]Device{}, pool: map[string][][]byte{}, lastResort: map[string][]byte{}}
}

func devKey(uid, id string) string { return uid + "|" + id }

func (f *fakeRepo) view(uid string, d Device) Device {
	k := devKey(uid, d.ID)
	d.PoolCount = len(f.pool[k])
	d.HasLastResort = len(f.lastResort[k]) > 0
	return d
}

func (f *fakeRepo) find(uid, id string) int {
	for i, d := range f.devices[uid] {
		if d.ID == id {
			return i
		}
	}
	return -1
}

func (f *fakeRepo) Register(_ context.Context, uid string, d Device, now time.Time) (Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return Device{}, f.err
	}
	if i := f.find(uid, d.ID); i >= 0 {
		cur := f.devices[uid][i]
		if !bytes.Equal(cur.SignatureKey, d.SignatureKey) {
			return Device{}, ErrKeyMismatch
		}
		if now.Sub(cur.LastSeenAt) > seenRefreshInterval {
			cur.LastSeenAt = now
			f.devices[uid][i] = cur
		}
		return f.view(uid, cur), nil
	}
	if len(f.devices[uid]) >= MaxDevicesPerUser {
		return Device{}, ErrDeviceLimit
	}
	d.CreatedAt, d.LastSeenAt = now, now
	f.devices[uid] = append(f.devices[uid], d)
	return f.view(uid, d), nil
}

func (f *fakeRepo) List(_ context.Context, uid string) ([]Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.listCalls++
	if f.err != nil {
		return nil, f.err
	}
	out := make([]Device, 0, len(f.devices[uid]))
	for _, d := range f.devices[uid] {
		out = append(out, f.view(uid, d))
	}
	return out, nil
}

func (f *fakeRepo) Remove(_ context.Context, uid, deviceID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return f.err
	}
	i := f.find(uid, deviceID)
	if i < 0 {
		return nil
	}
	f.devices[uid] = append(f.devices[uid][:i:i], f.devices[uid][i+1:]...)
	delete(f.pool, devKey(uid, deviceID))
	delete(f.lastResort, devKey(uid, deviceID))
	return nil
}

func (f *fakeRepo) Upload(_ context.Context, uid, deviceID string, packages [][]byte, lastResort []byte, now time.Time) (int, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return 0, false, f.err
	}
	i := f.find(uid, deviceID)
	if i < 0 {
		return 0, false, ErrNotFound
	}
	k := devKey(uid, deviceID)
	for _, p := range packages {
		if len(f.pool[k]) >= MaxPoolSize {
			break
		}
		dup := false
		for _, have := range f.pool[k] {
			if bytes.Equal(have, p) {
				dup = true
				break
			}
		}
		if !dup {
			f.pool[k] = append(f.pool[k], append([]byte(nil), p...))
		}
	}
	if len(lastResort) > 0 { // the repository's presence rule: empty bytes are none
		f.lastResort[k] = append([]byte(nil), lastResort...)
	}
	if cur := f.devices[uid][i]; now.Sub(cur.LastSeenAt) > seenRefreshInterval {
		cur.LastSeenAt = now
		f.devices[uid][i] = cur
	}
	return len(f.pool[k]), len(f.lastResort[k]) > 0, nil
}

func (f *fakeRepo) ActiveDevices(_ context.Context, uid string, now time.Time) ([]Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.activeCalls++
	if f.err != nil {
		return nil, f.err
	}
	out := make([]Device, 0, len(f.devices[uid]))
	for _, d := range f.devices[uid] {
		if d.Active(now) {
			out = append(out, f.view(uid, d))
		}
	}
	return out, nil
}

// Claim mirrors FirestoreRepo.Claim: a non-empty exclude must name one of the target's devices (inactive ones included),
// else ErrExcludeNotFound with nothing consumed; per remaining active device one pool package is consumed (which one is
// unspecified, as in the repository; here the oldest), else the last-resort package is returned (kept), else
// HasKeyPackage is false. LastSeenAt is untouched.
func (f *fakeRepo) Claim(_ context.Context, targetUID, excludeDeviceID string, now time.Time) ([]Claimed, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	if excludeDeviceID != "" && f.find(targetUID, excludeDeviceID) < 0 {
		return nil, ErrExcludeNotFound
	}
	out := []Claimed{}
	for _, d := range f.devices[targetUID] {
		if d.ID == excludeDeviceID || !d.Active(now) {
			continue
		}
		k := devKey(targetUID, d.ID)
		c := Claimed{DeviceID: d.ID, SignatureKey: cloneBytes(d.SignatureKey)}
		if pool := f.pool[k]; len(pool) > 0 {
			c.KeyPackage, c.HasKeyPackage = cloneBytes(pool[0]), true
			f.pool[k] = pool[1:]
		} else if lr := f.lastResort[k]; len(lr) > 0 {
			c.KeyPackage, c.HasKeyPackage, c.LastResort = cloneBytes(lr), true, true
		}
		out = append(out, c)
	}
	return out, nil
}

// fakePermission is a Permission: refuse maps a target to the (cause-specific) error the messaging rules would give;
// every one wraps ErrCannotMessage. calls counts the checks.
type fakePermission struct {
	mu     sync.Mutex
	refuse map[string]error
	calls  []string
	err    error
	// shares maps a target to "shares an encrypted conversation with the caller"; sharesErr fails every such check;
	// sharesCalls records the targets asked about.
	shares      map[string]bool
	sharesErr   error
	sharesCalls []string
}

func (p *fakePermission) CanMessage(_ context.Context, _, targetUID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls = append(p.calls, targetUID)
	if p.err != nil {
		return p.err
	}
	return p.refuse[targetUID]
}

func (p *fakePermission) SharesEncryptedConversation(_ context.Context, _, targetUID string) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.sharesCalls = append(p.sharesCalls, targetUID)
	if p.sharesErr != nil {
		return false, p.sharesErr
	}
	return p.shares[targetUID], nil
}

// fakeConvID is the injected ConversationID: readable, order-dependent, so a test can tell the argument order.
func fakeConvID(callerUID, targetUID string) string { return "c-" + callerUID + "-" + targetUID }

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
