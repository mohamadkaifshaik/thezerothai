package timeline

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// SetHomeTabs (ADR-0030 D6, W5-9) lives in this file so it stays out of the feed code. The timeline never touches users/{uid}:
// the pinned tabs are stored by identity behind HomeTabsStore.

// limitHomeTabs is the `limit` metadata of the LIMIT_REACHED answer.
const limitHomeTabs = "home_tabs"

// maxHomeTabsFallback is the cap when HomeTabsDeps.Max is unset (HOME_TABS_MAX_PINNED default).
const maxHomeTabsFallback = 5

// HomeTabsStore is the consumer-side seam to users/{uid}.homeTabs (ADR-0030 D1, D6); identity implements it
// (*identity.HomeTabsAdapter), so the storage can move without changing a caller.
type HomeTabsStore interface {
	// Current is the caller's stored tabs, cache-first (0 reads when the account-status interceptor loaded the profile).
	Current(ctx context.Context, uid string) ([]identity.HomeTab, error)
	// Replace runs one transaction: reads the idempotency document and users/{uid} fresh, applies next to the stored tabs (it
	// must be pure: it reruns on a retry), writes homeTabs field-level and the idempotency document. A replay returns the
	// stored tabs with no write; the same key with another requestHash is identity.ErrKeyReused.
	Replace(ctx context.Context, uid, key, requestHash string, next func(current []identity.HomeTab) ([]identity.HomeTab, error)) ([]identity.HomeTab, error)
}

// HomeTabsDeps wires SetHomeTabs. Without WithHomeTabs the RPC stays Unimplemented.
type HomeTabsDeps struct {
	Store HomeTabsStore
	// Lists validates a LIST tab the caller does not already hold (GetList's visibility rules, cache-first).
	Lists lists.Reader
	// Flags answers the per-caller FEATURE_LISTS question (lists.Guard and the hidden-kind rule).
	Flags lists.FlagChecker
	// Max is HOME_TABS_MAX_PINNED (0 = 5).
	Max int
}

// WithHomeTabs wires SetHomeTabs (W5-9).
func WithHomeTabs(d HomeTabsDeps) Option {
	return func(s *Server) {
		if d.Max <= 0 {
			d.Max = maxHomeTabsFallback
		}
		s.homeTabs = &d
	}
}

// errTabNotValidated means a tab was not stored in the transaction's fresh read and was not validated before it (the cached
// profile was stale); SetHomeTabs validates again.
var errTabNotValidated = errors.New("timeline: home tab not validated")

// errTabsLimit is the cap breach (sent tabs plus the stored tabs of a kind that is off for the caller).
var errTabsLimit = errors.New("timeline: home tabs limit")

func tabsValidation() error {
	return apierr.Validation("tabs", "tabs must be distinct lists you can read")
}

// tabKey identifies a tab by kind and id.
type tabKey struct{ kind, id string }

// visibleKind reports whether stored tabs of this kind are shown (and so owned by the sent order) for uid.
func (d *HomeTabsDeps) visibleKind(uid, kind string) bool {
	return kind == identity.HomeTabKindList && d.Flags != nil && d.Flags.Enabled(uid, lists.FlagName)
}

// parseTabs checks the shape of the sent tabs (0 reads): kind LIST only (COMMUNITY is refused until its timeline ships), a
// well-formed id, no duplicate. Titles in the request are ignored.
func parseTabs(in []*commonv1.HomeTab) ([]tabKey, error) {
	out := make([]tabKey, 0, len(in))
	seen := map[tabKey]bool{}
	for _, t := range in {
		if t.GetKind() != commonv1.HomeTabKind_HOME_TAB_KIND_LIST || !ids.ValidPostID(t.GetId()) {
			return nil, tabsValidation()
		}
		k := tabKey{identity.HomeTabKindList, t.GetId()}
		if seen[k] {
			return nil, tabsValidation()
		}
		seen[k] = true
		out = append(out, k)
	}
	return out, nil
}

// tabsHash is the canonical request body for IDEMPOTENCY_KEY_REUSED: the ordered kind:id pairs.
func tabsHash(tabs []tabKey) string {
	parts := make([]string, len(tabs))
	for i, t := range tabs {
		parts[i] = t.kind + ":" + t.id
	}
	return idempotency.HashRequest("tabs=" + strings.Join(parts, ","))
}

// SetHomeTabs replaces the caller's pinned Home tabs (proto: TimelineService.SetHomeTabs).
//
// Order: key format and tab shape (VALIDATION, 0 reads), the cap on the sent tabs (LIMIT_REACHED home_tabs), then the
// FEATURE_LISTS gate when any tab is sent (an empty request skips it: "unpin everything" is accepted with lists off, but
// stored LIST tabs are a kind that is off for the caller, so they are kept, see below), then validation of every tab not
// already stored, then one identity transaction. Stored tabs of a kind that is off for the caller are kept after the sent
// ones and count toward the cap.
//
// Budget (ADR-0030 table; reads count the account-status interceptor's caller `users` read): worst 19 cold (interceptor 1,
// idempotency 1, users 1, <= 5 new list docs, caller graph 1, and for another user's list its owner's profile and graph, all
// cache-first), typical 4; writes 2 (users field-level, idempotency), 1 when the order is unchanged, + 1 TTL delete later;
// a replay reads 2 (idempotency, users) and writes 0.
func (s *Server) SetHomeTabs(ctx context.Context, req *connect.Request[timelinev1.SetHomeTabsRequest]) (*connect.Response[timelinev1.SetHomeTabsResponse], error) {
	h := s.homeTabs
	if h == nil || h.Store == nil || h.Lists == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("SetHomeTabs is not wired"))
	}
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, 0, "unauthenticated")
	}
	logger.SetRequestField(ctx, fieldOp, "set_home_tabs")
	if !idempotency.KeyFormatValid(req.Msg.GetIdempotencyKey()) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16 to 64 characters of A-Z a-z 0-9 _ -")
	}
	sent, err := parseTabs(req.Msg.GetTabs())
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, "tabs", len(sent))
	if len(sent) > h.Max {
		return nil, limitReached(ctx)
	}
	if len(sent) > 0 {
		if err := lists.Guard(ctx, h.Flags, uid); err != nil {
			return nil, err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()

	var stored []identity.HomeTab
	for attempt := 0; attempt < 2; attempt++ {
		titles, err := s.validateNewTabs(ctx, h, uid, sent, attempt == 0)
		if err != nil {
			return nil, mapTabsErr(ctx, uid, err)
		}
		stored, err = h.Store.Replace(ctx, uid, req.Msg.GetIdempotencyKey(), tabsHash(sent), func(cur []identity.HomeTab) ([]identity.HomeTab, error) {
			return mergeTabs(h, uid, sent, titles, cur)
		})
		if errors.Is(err, errTabNotValidated) {
			continue // the cached profile was behind the document: validate against the fresh tabs once more
		}
		if err != nil {
			return nil, mapTabsErr(ctx, uid, err)
		}
		return connect.NewResponse(&timelinev1.SetHomeTabsResponse{Tabs: tabsToProto(h, uid, stored)}), nil
	}
	return nil, tabsValidation()
}

func limitReached(ctx context.Context) error {
	logger.SetRequestField(ctx, "outcome", "rejected:limit_reached")
	logger.SetRequestField(ctx, "limit", limitHomeTabs)
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "pinned tab limit reached").
		WithMeta("limit", limitHomeTabs)
}

// validateNewTabs reads each sent tab that is not already stored (cache-first profile) through lists.Reader and returns the
// title to store for it: the list's name when the caller owns it, "" for another user's list (ADR-0030 D6: no foreign text
// on users/{uid}). A list the caller may not read is the one VALIDATION answer.
func (s *Server) validateNewTabs(ctx context.Context, h *HomeTabsDeps, uid string, sent []tabKey, useStored bool) (map[tabKey]string, error) {
	have := map[tabKey]bool{}
	if useStored { // the second pass (the cached profile was behind the document) validates every sent tab
		cur, err := h.Store.Current(ctx, uid)
		if err != nil {
			return nil, err
		}
		for _, t := range cur {
			have[tabKey{t.Kind, t.ID}] = true
		}
	}
	titles := map[tabKey]string{}
	for _, k := range sent {
		if have[k] {
			continue
		}
		v, err := h.Lists.Get(ctx, uid, k.id)
		if err != nil {
			if errors.Is(err, lists.ErrNotFound) {
				return nil, tabsValidation()
			}
			return nil, err
		}
		if v.Owner.UserID == uid {
			titles[k] = v.Header.Name
		} else {
			titles[k] = ""
		}
	}
	return titles, nil
}

// mergeTabs builds the new stored order from the fresh stored tabs: the sent tabs in order (a stored one keeps its stored
// title; a new one takes its validated title or is errTabNotValidated), then the stored tabs of a kind that is off for the
// caller, which the sender cannot see or move. Over the cap is errTabsLimit. Pure: the transaction may rerun it.
func mergeTabs(h *HomeTabsDeps, uid string, sent []tabKey, titles map[tabKey]string, cur []identity.HomeTab) ([]identity.HomeTab, error) {
	have := map[tabKey]identity.HomeTab{}
	for _, t := range cur {
		have[tabKey{t.Kind, t.ID}] = t
	}
	out := make([]identity.HomeTab, 0, len(sent)+len(cur))
	for _, k := range sent {
		if t, ok := have[k]; ok {
			out = append(out, t)
			continue
		}
		title, ok := titles[k]
		if !ok {
			return nil, errTabNotValidated
		}
		out = append(out, identity.HomeTab{Kind: k.kind, ID: k.id, Title: title})
	}
	for _, t := range cur {
		if !h.visibleKind(uid, t.Kind) {
			out = append(out, t)
		}
	}
	if len(out) > h.Max {
		return nil, errTabsLimit
	}
	return out, nil
}

// tabsToProto renders the stored tabs as GetMe would: only kinds that are on for the caller.
func tabsToProto(h *HomeTabsDeps, uid string, tabs []identity.HomeTab) []*commonv1.HomeTab {
	out := make([]*commonv1.HomeTab, 0, len(tabs))
	for _, t := range tabs {
		if h.visibleKind(uid, t.Kind) {
			out = append(out, &commonv1.HomeTab{Kind: commonv1.HomeTabKind_HOME_TAB_KIND_LIST, Id: t.ID, Title: t.Title})
		}
	}
	return out
}

// mapTabsErr maps the store and reader errors at the handler boundary (never a raw Firestore error to the client).
func mapTabsErr(ctx context.Context, uid string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.As(err, &ae):
		return err
	case errors.Is(err, errTabsLimit):
		return limitReached(ctx)
	case errors.Is(err, identity.ErrKeyReused):
		logger.SetRequestField(ctx, "outcome", "rejected:key_reused")
		return apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	case errors.Is(err, identity.ErrNotFound):
		return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "profile not found")
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err):
		logger.SetRequestField(ctx, "outcome", "contention")
		slog.WarnContext(ctx, "home_tabs_contention", "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("timeline: set home tabs: %w", err), uid)
}
