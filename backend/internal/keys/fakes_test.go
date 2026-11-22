package keys

import (
	"bytes"
	"context"
	"sync"
	"time"
)

// fakeRepo mirrors the Firestore repository's rules in memory: the cap of 5 devices, key mismatch, the 24 h last-seen
// refresh, the pool cap with excess dropped (oldest stay), dedupe by package bytes, unknown device, remove of a missing
// device succeeding, and the claim rules (one-time package consumed, last resort reused, exclusion, inactivity); and the
// removed marks: a marked id is refused by Register (before the cap; a live document under a mark is stamped removedAt
// as it is refused) and Upload (before NOT_FOUND), and a device whose
// document carries removedAt (removing) is skipped by every read but still holds its slot under the cap (at the cap,
// Register names the removing ids in a StuckRemovalsError).
type fakeRepo struct {
	mu         sync.Mutex
	devices    map[string][]Device // per uid, oldest first
	pool       map[string][][]byte // uid|deviceID -> packages in insertion order
	lastResort map[string][]byte
	// marks is uid|deviceID -> the removed mark; removing is uid|deviceID -> the device document carries removedAt.
	marks    map[string]RemovalMark
	removing map[string]bool
	// removedAt is uid|deviceID -> the removing document's removedAt; absent reads as long ago.
	removedAt map[string]time.Time
	err       error
	// markErr fails MarkRemoved only; removeErr fails Remove only.
	markErr   error
	removeErr error
	// beforeRemove and afterRemove, when set, run inside Remove and RemoveRemoving (under the lock), before the work and
	// after a successful delete.
	beforeRemove, afterRemove func()
	calls                     int
	// listCalls and activeCalls count the device reads of GetDevices (List and ActiveDevices) separately from calls.
	listCalls, activeCalls int
	// ops is every repository call in order (by method name).
	ops []string
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{devices: map[string][]Device{}, pool: map[string][][]byte{}, lastResort: map[string][]byte{},
		marks: map[string]RemovalMark{}, removing: map[string]bool{}, removedAt: map[string]time.Time{}}
}

// MarkRemoved mirrors FirestoreRepo.MarkRemoved: without a recent sign-in only a retry (a mark, and no device document
// or one already carrying removedAt) goes on, else ErrReauthRequired with nothing written; the mark is created once (a
// second call keeps the first time) and a present device document gets removedAt.
func (f *fakeRepo) MarkRemoved(_ context.Context, uid, deviceID string, now time.Time, recent bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ops = append(f.ops, "MarkRemoved")
	if f.markErr != nil {
		return f.markErr
	}
	k := devKey(uid, deviceID)
	_, marked := f.marks[k]
	retry := marked && (f.find(uid, deviceID) < 0 || !f.live(uid, deviceID))
	if !recent && !retry {
		return ErrReauthRequired
	}
	if !marked {
		f.marks[k] = RemovalMark{DeviceID: deviceID, RemovedAt: now, ExpireAt: now.Add(RemovalMarkTTL)}
	}
	if f.find(uid, deviceID) >= 0 && f.live(uid, deviceID) {
		f.removing[k] = true
		f.removedAt[k] = now
	}
	return nil
}

// live reports whether the device document does not carry removedAt.
func (f *fakeRepo) live(uid, id string) bool { return !f.removing[devKey(uid, id)] }

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
	f.ops = append(f.ops, "Register")
	if f.err != nil {
		return Device{}, f.err
	}
	if i := f.find(uid, d.ID); i >= 0 {
		if !f.live(uid, d.ID) {
			return Device{}, ErrDeviceRemoved
		}
		if _, marked := f.marks[devKey(uid, d.ID)]; marked {
			f.removing[devKey(uid, d.ID)] = true // a live document under a mark: stamped, then refused
			f.removedAt[devKey(uid, d.ID)] = now
			return Device{}, ErrDeviceStamped
		}
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
	if _, marked := f.marks[devKey(uid, d.ID)]; marked {
		return Device{}, ErrDeviceRemoved // before the count: a marked id never learns about the cap
	}
	if len(f.devices[uid]) >= MaxDevicesPerUser { // a removing device still holds its slot
		var stuck []string
		for _, have := range f.devices[uid] {
			if !f.live(uid, have.ID) && now.Sub(f.removedAt[devKey(uid, have.ID)]) >= StuckRemovalMinAge {
				stuck = append(stuck, have.ID) // a fresher one may be a REMOTE removal still in flight
			}
		}
		if len(stuck) > 0 {
			return Device{}, &StuckRemovalsError{DeviceIDs: stuck}
		}
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
		if f.live(uid, d.ID) {
			out = append(out, f.view(uid, d))
		}
	}
	return out, nil
}

func (f *fakeRepo) Remove(_ context.Context, uid, deviceID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ops = append(f.ops, "Remove")
	return f.removeLocked(uid, deviceID, false)
}

// RemoveRemoving mirrors FirestoreRepo.RemoveRemoving: a live device document is left alone (nil, nothing deleted).
func (f *fakeRepo) RemoveRemoving(_ context.Context, uid, deviceID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ops = append(f.ops, "RemoveRemoving")
	return f.removeLocked(uid, deviceID, true)
}

func (f *fakeRepo) removeLocked(uid, deviceID string, onlyRemoving bool) error {
	f.calls++
	if f.err != nil {
		return f.err
	}
	if f.removeErr != nil {
		return f.removeErr
	}
	if f.beforeRemove != nil {
		f.beforeRemove()
	}
	i := f.find(uid, deviceID)
	if i < 0 {
		return nil
	}
	if onlyRemoving && f.live(uid, deviceID) {
		return nil
	}
	f.devices[uid] = append(f.devices[uid][:i:i], f.devices[uid][i+1:]...)
	delete(f.pool, devKey(uid, deviceID))
	delete(f.lastResort, devKey(uid, deviceID))
	delete(f.removing, devKey(uid, deviceID))
	delete(f.removedAt, devKey(uid, deviceID))
	if f.afterRemove != nil {
		f.afterRemove()
	}
	return nil
}

func (f *fakeRepo) Upload(_ context.Context, uid, deviceID string, packages [][]byte, lastResort []byte, now time.Time) (int, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.ops = append(f.ops, "Upload")
	if f.err != nil {
		return 0, false, f.err
	}
	i := f.find(uid, deviceID)
	k := devKey(uid, deviceID)
	if i >= 0 && !f.live(uid, deviceID) {
		return 0, false, ErrDeviceRemoved
	}
	if i < 0 {
		if _, marked := f.marks[k]; marked {
			return 0, false, ErrDeviceRemoved
		}
		return 0, false, ErrNotFound
	}
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
		if d.Active(now) && f.live(uid, d.ID) {
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
	if excludeDeviceID != "" && (f.find(targetUID, excludeDeviceID) < 0 || !f.live(targetUID, excludeDeviceID)) {
		return nil, ErrExcludeNotFound
	}
	out := []Claimed{}
	for _, d := range f.devices[targetUID] {
		if d.ID == excludeDeviceID || !d.Active(now) || !f.live(targetUID, d.ID) {
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
