package beacons

// audience.go is F28b: an UpdateBeacon may widen a beacon's audience, never narrow it, so nobody loses access to a plan
// they joined or asked to join (owner, 2026-11-15). Two audiences exist, a community (communityId = the community's id)
// and public (communityId = ""), ordered community < public. Every community is PUBLIC to read (communities.proto F6), so
// a community plan made public exposes no community content, and everyone who could see it still can. One community into
// another is neither wider nor narrower: the members of the first would lose it, so it is refused as incompatible.

import "github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"

// AudienceMove is how a requested audience compares with the stored one.
type AudienceMove int

const (
	// AudienceSame: the stored audience resent, not a change.
	AudienceSame AudienceMove = iota
	// AudienceWiden: a community beacon made public, the one change UpdateBeacon accepts.
	AudienceWiden
	// AudienceNarrow: a public beacon moved into a community (ErrAudienceNarrowing).
	AudienceNarrow
	// AudienceIncompatible: a community beacon moved into another community (ErrAudienceIncompatible).
	AudienceIncompatible
)

// Audience refusal reasons, metadata["reason"] of the VALIDATION "audience" answer.
const (
	reasonAudienceNarrowing    = "audience_narrowing"
	reasonAudienceIncompatible = "audience_incompatible"
)

// audienceMove compares the stored communityId from with the requested to ("" = public on both sides). It is the one
// decision both the service (on the beacon it resolved, to gate the community before the transaction) and the repository
// (on the beacon read inside the transaction, the authority) apply.
func audienceMove(from, to string) AudienceMove {
	switch {
	case from == to:
		return AudienceSame
	case to == "":
		return AudienceWiden
	case from == "":
		return AudienceNarrow
	default:
		return AudienceIncompatible
	}
}

// err is the refusal of m: ErrAudienceNarrowing, ErrAudienceIncompatible, or nil for a move UpdateBeacon accepts.
func (m AudienceMove) err() error {
	switch m {
	case AudienceNarrow:
		return ErrAudienceNarrowing
	case AudienceIncompatible:
		return ErrAudienceIncompatible
	}
	return nil
}

// audienceRefused is the wire answer of a refused move: INVALID_ARGUMENT + VALIDATION "audience" with the reason.
func audienceRefused(reason, message string) *apierr.Error {
	return apierr.Validation("audience", message).WithMeta("reason", reason)
}
