package identity

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// maxPublicIDAttempts bounds the runs of a mint (signup or lazy) that lost its create-only lookup write, each with a
	// fresh id. With 128 random bits a real collision is not expected in the lifetime of the service; the retries exist
	// so that one would be invisible, and the bound so that a broken generator cannot loop.
	maxPublicIDAttempts = 3
	// publicIDChunk is the most ids one GetAll of the PublicIDs lookups reads.
	publicIDChunk = 100
)

var _ PublicIDs = (*service)(nil)

// publicIDsMinting reports whether public ids are minted (signup and lazy) and the lookups answer: public_ids not
// globally off. No flags wired counts as globally off, so tests and old wiring behave exactly as before the feature.
func (s *service) publicIDsMinting() bool {
	return s.extras != nil && !s.extras.GloballyOff(PublicIDsFlag)
}

// publicIDsShown reports whether responses to callerUID carry public ids (and GetProfile serves the public_id arm).
func (s *service) publicIDsShown(callerUID string) bool {
	return s.extras != nil && callerUID != "" && s.extras.Enabled(callerUID, PublicIDsFlag)
}

// showPublicID is the response rule for the public id: present() always blanks it, and GetMe/GetProfile put the stored
// value back only for a caller with public_ids on.
func (s *service) showPublicID(out *Profile, stored Profile, callerUID string) {
	if s.publicIDsShown(callerUID) {
		out.PublicID = stored.PublicID
	}
}

// drawPublicID is the generator seam (tests replace s.newPublicID to force collisions).
func (s *service) drawPublicID() (string, error) {
	if s.newPublicID != nil {
		return s.newPublicID()
	}
	return NewPublicID()
}

// createProfileMinting runs the signup transaction. While public_ids is not globally off each run carries a fresh public
// id, and only a run whose id was already taken (ErrPublicIDCollision: the transaction read publicIds/{id} before any
// Auth call or write) is retried, at most maxPublicIDAttempts runs in all. Any other conflict (a pre-existing graph/{uid},
// say) is deterministic and returned after one run. Globally off it is the one run it always was, with no id and no
// extra read. Every error leaves with the uid and the drawn id redacted (Firestore's text names document paths).
func (s *service) createProfileMinting(ctx context.Context, uid, handle, handleLower, displayName string, authorize func(context.Context) (*AuthBaseline, error)) (Profile, error) {
	minting := s.publicIDsMinting()
	var lastErr error
	for range maxPublicIDAttempts {
		publicID := ""
		if minting {
			var err error
			if publicID, err = s.drawPublicID(); err != nil {
				return Profile{}, err
			}
		}
		profile, _, err := s.repo.CreateProfile(ctx, uid, handle, handleLower, displayName, publicID, s.now().UTC(), authorize)
		if err == nil {
			return profile, nil
		}
		if !minting || !errors.Is(err, ErrPublicIDCollision) {
			return Profile{}, logger.RedactErr(err, uid, publicID)
		}
		lastErr = logger.RedactErr(err, uid, publicID)
		logger.SetRequestField(ctx, "public_id_mint_conflicts", true)
	}
	return Profile{}, fmt.Errorf("identity: public id still conflicting after %d attempts: %w", maxPublicIDAttempts, lastErr)
}

// ensurePublicID is GetMe's lazy mint for an account created before public ids existed: only while public_ids is not
// globally off, only for an ACTIVE profile with no id, so a GetMe of an account that has one costs nothing extra. The
// transaction (1 read, 2 writes) re-checks both conditions on the fresh document. A failure never fails GetMe: WARN
// public_id_mint_failed (uid hash only, never the id) and the profile is answered without an id; the next GetMe retries.
func (s *service) ensurePublicID(ctx context.Context, p Profile) Profile {
	if p.PublicID != "" || p.Status != AccountStatusActive || !s.publicIDsMinting() {
		return p
	}
	var err error
	for range maxPublicIDAttempts {
		var publicID string
		if publicID, err = s.drawPublicID(); err != nil {
			break
		}
		var minted Profile
		minted, err = s.repo.EnsurePublicID(ctx, p.UserID, publicID, s.now().UTC())
		if err == nil {
			s.cache.SetProfile(minted)
			logger.SetRequestField(ctx, "public_id_minted", minted.PublicID == publicID)
			return minted
		}
		if !errors.Is(err, ErrPublicIDCollision) {
			err = logger.RedactErr(err, p.UserID, publicID)
			break
		}
	}
	if !errors.Is(err, ErrNotFound) {
		orDefault(s.reqLog).WarnContext(ctx, "public_id_mint_failed", append([]any{"uid_hash", logger.HashUID(p.UserID), "error", logger.CauseChain(logger.RedactErr(err, p.UserID))}, logger.TraceAttrs(ctx)...)...)
	}
	return p
}

// PublicIDsForUIDs implements PublicIDs: the uid -> public id cache, then the profile cache, then one GetAll on users per
// chunk of misses.
func (s *service) PublicIDsForUIDs(ctx context.Context, uids []string) (map[string]string, error) {
	out := map[string]string{}
	if !s.publicIDsMinting() || len(uids) == 0 {
		return out, nil
	}
	var misses []string
	seen := make(map[string]struct{}, len(uids))
	for _, uid := range uids {
		if _, dup := seen[uid]; dup {
			continue
		}
		seen[uid] = struct{}{}
		if !ValidUserID(uid) {
			continue
		}
		if pub, ok := s.cache.PublicIDForUID(uid); ok {
			out[uid] = pub
			continue
		}
		// A cached profile (60 s) answers either way: with its id, or "not minted yet" without a read. So does a
		// cached "no profile".
		if p, ok := s.cache.GetProfile(uid); ok {
			if p.PublicID != "" {
				s.cache.SetPublicID(uid, p.PublicID)
				out[uid] = p.PublicID
			}
			continue
		}
		if s.cache.GetNotFound(uid) {
			continue
		}
		misses = append(misses, uid)
	}
	if len(seen) > MaxPublicIDLookups {
		return nil, fmt.Errorf("identity: PublicIDsForUIDs of %d uids exceeds the limit of %d", len(seen), MaxPublicIDLookups)
	}
	for start := 0; start < len(misses); start += publicIDChunk {
		chunk := misses[start:min(start+publicIDChunk, len(misses))]
		found, err := s.repo.GetProfiles(ctx, chunk)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("identity: public ids for uids: %w", err), chunk...)
		}
		for _, uid := range chunk {
			p, ok := found[uid]
			if !ok {
				s.cache.SetNotFound(uid)
				continue
			}
			s.cache.SetProfile(p)
			if p.PublicID != "" {
				out[uid] = p.PublicID
			}
		}
	}
	return out, nil
}

// UIDsForPublicIDs implements PublicIDs: the public id -> uid cache and the 10 s negative cache, then one GetAll on
// publicIds per chunk of misses. Malformed ids never reach Firestore.
func (s *service) UIDsForPublicIDs(ctx context.Context, publicIDs []string) (map[string]string, error) {
	out := map[string]string{}
	if !s.publicIDsMinting() || len(publicIDs) == 0 {
		return out, nil
	}
	var misses []string
	seen := make(map[string]struct{}, len(publicIDs))
	for _, id := range publicIDs {
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		if !ValidPublicID(id) || s.cache.GetPublicIDFree(id) {
			continue
		}
		if uid, ok := s.cache.UIDForPublicID(id); ok {
			out[id] = uid
			continue
		}
		misses = append(misses, id)
	}
	if len(seen) > MaxPublicIDLookups {
		return nil, fmt.Errorf("identity: UIDsForPublicIDs of %d ids exceeds the limit of %d", len(seen), MaxPublicIDLookups)
	}
	for start := 0; start < len(misses); start += publicIDChunk {
		chunk := misses[start:min(start+publicIDChunk, len(misses))]
		found, err := s.repo.ResolvePublicIDs(ctx, chunk)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("identity: uids for public ids: %w", err), chunk...)
		}
		for _, id := range chunk {
			uid, ok := found[id]
			if !ok {
				s.cache.SetPublicIDFree(id)
				continue
			}
			s.cache.SetPublicID(uid, id)
			out[id] = uid
		}
	}
	return out, nil
}

// UIDForPublicID implements PublicIDs for one id.
func (s *service) UIDForPublicID(ctx context.Context, publicID string) (string, error) {
	m, err := s.UIDsForPublicIDs(ctx, []string{publicID})
	if err != nil {
		return "", err
	}
	uid, ok := m[publicID]
	if !ok {
		return "", ErrNotFound
	}
	return uid, nil
}
