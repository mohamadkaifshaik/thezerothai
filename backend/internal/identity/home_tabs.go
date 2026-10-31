package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Home tabs (ADR-0030 D6, W5-9): the caller's pinned Home tabs live on users/{uid}.homeTabs, an array of at most
// HOME_TABS_MAX_PINNED maps {kind, id, title}. Identity owns the field; timeline writes it only through its consumer-side
// HomeTabsStore and lists only through lists.Pins, and this one adapter (HomeTabsAdapter) satisfies both.

// Home tab kinds as stored (and as identity.HomeTab.Kind). They mirror common.v1.HomeTabKind; identity keeps plain strings
// so this package has no proto import in its domain model.
const (
	HomeTabKindList      = "LIST"
	HomeTabKindCommunity = "COMMUNITY"
)

// ListsFlag and CommunitiesFlag are the wire names of the flags that gate a tab kind in GetMe.home_tabs (identity cannot
// import lists; GetMe reads the per-caller answer from the enabled_features list it already computed, 0 reads).
const (
	ListsFlag       = "lists"
	CommunitiesFlag = "communities"
)

// HomeTab is one pinned Home tab. Title is stored only for a list the owner owns ("" for another user's list, ADR-0030 D6).
type HomeTab struct {
	Kind  string `firestore:"kind" json:"k"`
	ID    string `firestore:"id" json:"i"`
	Title string `firestore:"title" json:"t"`
}

// ErrKeyReused is HomeTabsAdapter.Replace's answer when the idempotency key belongs to another request body.
var ErrKeyReused = errors.New("identity: idempotency key reused")

// rpcSetHomeTabs is the rpc name hashed into the idempotency document id (ADR-0030 D7).
const rpcSetHomeTabs = "SetHomeTabs"

// encodeHomeTabs is the comparable, immutable form Profile carries (a slice would make Profile incomparable and share a
// backing array between cached copies). "" = no tabs.
func encodeHomeTabs(tabs []HomeTab) string {
	if len(tabs) == 0 {
		return ""
	}
	b, err := json.Marshal(tabs)
	if err != nil { // a slice of plain strings cannot fail to marshal
		return ""
	}
	return string(b)
}

func decodeHomeTabs(enc string) []HomeTab {
	if enc == "" {
		return nil
	}
	var out []HomeTab
	if err := json.Unmarshal([]byte(enc), &out); err != nil {
		return nil
	}
	return out
}

// HomeTabs returns the profile's pinned tabs in order (a fresh slice; nil = none).
func (p Profile) HomeTabs() []HomeTab { return decodeHomeTabs(p.HomeTabsEnc) }

// visibleHomeTabs is GetMe's view: the tabs whose kind's flag is on for the caller. A kind this build does not know is
// dropped (a client hides what it cannot render, and storage keeps it).
func visibleHomeTabs(tabs []HomeTab, enabled []string) []HomeTab {
	var out []HomeTab
	for _, t := range tabs {
		flag := ""
		switch t.Kind {
		case HomeTabKindList:
			flag = ListsFlag
		case HomeTabKindCommunity:
			flag = CommunitiesFlag
		}
		if flag != "" && slices.Contains(enabled, flag) {
			out = append(out, t)
		}
	}
	return out
}

// HomeTabsAdapter implements timeline.HomeTabsStore and lists.Pins over users/{uid}.homeTabs. Every write is a field-level
// Update of homeTabs inside a transaction that read users/{uid} fresh (never Set, so a write after the eraser cannot
// recreate the document), followed by an in-place refresh of this instance's profile cache.
type HomeTabsAdapter struct {
	repo  *FirestoreRepo
	idem  *idempotency.Store
	cache *Cache
	now   func() time.Time
}

// NewHomeTabs builds the adapter on the repo, the shared idempotency store and the identity profile cache.
func NewHomeTabs(repo *FirestoreRepo, idem *idempotency.Store, cache *Cache) *HomeTabsAdapter {
	return &HomeTabsAdapter{repo: repo, idem: idem, cache: cache, now: time.Now}
}

// Current returns uid's stored tabs, cache-first through the 60 s profile cache (0 reads when the account-status
// interceptor has loaded the profile, else 1). Staleness bound: CACHE_TTL on another instance.
func (h *HomeTabsAdapter) Current(ctx context.Context, uid string) ([]HomeTab, error) {
	if p, ok := h.cache.GetProfile(uid); ok {
		return p.HomeTabs(), nil
	}
	p, err := h.repo.GetProfile(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("identity: home tabs current: %w", err), uid)
	}
	h.cache.SetProfile(p)
	return p.HomeTabs(), nil
}

// Replace runs the SetHomeTabs transaction (ADR-0030 D6, D7). Reads, fresh and in this order: the idempotency document,
// users/{uid} (2 reads). A record that exists with the same hash is a replay: the stored tabs are returned and nothing is
// written; with another hash it is ErrKeyReused. Otherwise next(current) (pure: it reruns on a transaction retry) yields the
// new order; writes: the field-level homeTabs update plus the idempotency document (2), or the idempotency document alone
// when nothing changed (1). The profile cache is updated from the written data only after the commit.
func (h *HomeTabsAdapter) Replace(ctx context.Context, uid, key, requestHash string, next func(current []HomeTab) ([]HomeTab, error)) ([]HomeTab, error) {
	idemKey := idempotency.Key(uid, rpcSetHomeTabs, key)
	var out []HomeTab
	var written *userDoc
	_, err := store.RunTransaction(ctx, h.repo.client, func(ctx context.Context, tx *firestore.Transaction) error {
		out, written = nil, nil
		rec, err := h.idem.Get(ctx, tx, idemKey)
		replay := err == nil
		if err != nil && !errors.Is(err, idempotency.ErrNotFound) {
			return err
		}
		if replay && rec.RequestHash != requestHash {
			return ErrKeyReused
		}
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(h.repo.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user for home tabs: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for home tabs: %w", err)
		}
		cur := slices.Clone(d.HomeTabs)
		if replay {
			out = cur
			return nil
		}
		nxt, err := next(cur)
		if err != nil {
			return err
		}
		out = nxt
		b := store.NewFirestoreTxBatch(tx, counter)
		if !slices.Equal(cur, nxt) {
			b.Update(h.repo.userRef(uid), []firestore.Update{homeTabsUpdate(nxt)})
			d.HomeTabs = nxt
			written = &d
		}
		h.idem.Put(b, idemKey, idempotency.Record{UID: uid, RPC: rpcSetHomeTabs, RequestHash: requestHash, ExpireAt: h.now().UTC().Add(idempotency.TTL)})
		return b.Err()
	})
	if err != nil {
		return nil, err
	}
	h.refresh(uid, written)
	return out, nil
}

// homeTabsUpdate is the field-level write: an empty order removes the field (a doc with no pins carries none).
func homeTabsUpdate(tabs []HomeTab) firestore.Update {
	if len(tabs) == 0 {
		return firestore.Update{Path: "homeTabs", Value: firestore.Delete}
	}
	return firestore.Update{Path: "homeTabs", Value: tabs}
}

// refresh replaces uid's cached profile with the document just written (no re-read). A nil doc means nothing was written.
func (h *HomeTabsAdapter) refresh(uid string, d *userDoc) {
	if d != nil {
		h.cache.SetProfile(d.toProfile(uid))
	}
}

// edit is the shared body of Unpin and Retitle: one transaction that reads users/{uid} fresh (1 read), lets fn change the
// order, and writes homeTabs field-level only when fn changed something (1 write). hit reports whether fn found its tab. A
// missing document is "nothing to do".
func (h *HomeTabsAdapter) edit(ctx context.Context, uid string, fn func(cur []HomeTab) (next []HomeTab, hit bool)) (bool, error) {
	var hit bool
	var written *userDoc
	_, err := store.RunTransaction(ctx, h.repo.client, func(ctx context.Context, tx *firestore.Transaction) error {
		hit, written = false, nil
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(h.repo.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return nil
			}
			return fmt.Errorf("identity: get user for home tabs: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for home tabs: %w", err)
		}
		nxt, found := fn(slices.Clone(d.HomeTabs))
		hit = found
		if !found || slices.Equal(d.HomeTabs, nxt) {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(h.repo.userRef(uid), []firestore.Update{homeTabsUpdate(nxt)})
		d.HomeTabs = nxt
		written = &d
		return b.Err()
	})
	if err != nil {
		return false, err
	}
	h.refresh(uid, written)
	return hit, nil
}

// Unpin implements lists.Pins: removes the LIST tab for listID from uid's order. 1 read, 1 write only when it is pinned.
func (h *HomeTabsAdapter) Unpin(ctx context.Context, uid, listID string) error {
	_, err := h.edit(ctx, uid, func(cur []HomeTab) ([]HomeTab, bool) {
		i := slices.IndexFunc(cur, func(t HomeTab) bool { return t.Kind == HomeTabKindList && t.ID == listID })
		if i < 0 {
			return cur, false
		}
		return slices.Delete(cur, i, i+1), true
	})
	return err
}

// Retitle implements lists.Pins: sets the stored title of uid's pinned tab for listID. pinned reports whether the list is
// pinned. 1 read; 1 write only when it is pinned under another title.
func (h *HomeTabsAdapter) Retitle(ctx context.Context, uid, listID, name string) (pinned bool, err error) {
	return h.edit(ctx, uid, func(cur []HomeTab) ([]HomeTab, bool) {
		i := slices.IndexFunc(cur, func(t HomeTab) bool { return t.Kind == HomeTabKindList && t.ID == listID })
		if i < 0 {
			return cur, false
		}
		cur[i].Title = name
		return cur, true
	})
}

// WithHomeTabs returns a copy of p holding tabs (for fakes and tests of other modules; storage goes through HomeTabsAdapter).
func (p Profile) WithHomeTabs(tabs []HomeTab) Profile {
	p.HomeTabsEnc = encodeHomeTabs(tabs)
	return p
}
