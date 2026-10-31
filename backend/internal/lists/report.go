package lists

import (
	"context"
	"errors"
	"time"
)

// ErrOwnList is what ListReporter answers when the caller owns the list they are reporting.
var ErrOwnList = errors.New("lists: own list")

// ReportedList is the evidence of one list at report time (plan W5-44): the owner (the report's target owner), the owner's
// handle and the list's name and description. No member ids, no member count: the evidence holds no uid but OwnerUID.
type ReportedList struct {
	// OwnerUID becomes the report's TargetOwnerID (so `suspend-user --report` accepts a list report). Never in a response or a log.
	OwnerUID    string
	OwnerHandle string
	Name        string
	Description string
	CreatedAt   time.Time
}

// ListReporter is the part of the service a list report needs. The apiserver adapts it to moderation.ListLookup (moderation
// defines the interface and never imports lists); the service returned by New implements it.
type ListReporter interface {
	ReportableList(ctx context.Context, callerUID, listID string) (ReportedList, error)
}

var _ ListReporter = (*service)(nil)

// ReportableList implements ListReporter: the caller may report exactly the lists ADR-0030 D3 lets them see (a missing,
// malformed-id, private, hidden, blocked or inactive-owner list is ErrNotFound after the same reads as GetList, so a
// private list answers like a missing one). The caller's own list is ErrOwnList. It checks no flag: the report handler has
// already required `reports` on and `lists` not globally off, so a user dropped from the lists allowlist can still report what
// they saw.
//
// Firestore, worst case: the list 1 (instance cache, 0 warm), the caller's graph 1, the owner's profile 1 (directory cache,
// 0 warm), the owner's graph 1 (cache-first); the owner as caller reads the list and their profile only (2).
func (s *service) ReportableList(ctx context.Context, callerUID, listID string) (ReportedList, error) {
	a, err := s.resolve(ctx, callerUID, listID, false)
	if err != nil {
		return ReportedList{}, err
	}
	if a.isOwner {
		return ReportedList{}, ErrOwnList
	}
	l := a.list
	return ReportedList{OwnerUID: l.OwnerID, OwnerHandle: a.owner.Handle, Name: l.Name, Description: l.Description, CreatedAt: l.CreatedAt}, nil
}
