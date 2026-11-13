package config

import "fmt"

// DegradedMode gates writes/media at the platform level (the "degraded-mode switch" rule).
type DegradedMode string

const (
	DegradedOff      DegradedMode = "off"
	DegradedReadonly DegradedMode = "readonly"
	DegradedNoMedia  DegradedMode = "nomedia"
)

func (m DegradedMode) valid() bool {
	switch m {
	case DegradedOff, DegradedReadonly, DegradedNoMedia:
		return true
	default:
		return false
	}
}

// AppCheckMode controls whether a missing/invalid App Check token rejects the request.
type AppCheckMode string

const (
	AppCheckEnforce AppCheckMode = "enforce"
	AppCheckMonitor AppCheckMode = "monitor"
)

func (m AppCheckMode) valid() bool {
	switch m {
	case AppCheckEnforce, AppCheckMonitor:
		return true
	default:
		return false
	}
}

// ProfileMediaRetire is PROFILE_MEDIA_RETIRE: which replaced or removed profile images the
// retire step deletes after the grace. It is per-project retention config, not a FEATURE_ flag (no cohort, no
// allowlist), and it defaults to off: nothing is deleted until a project's operator has applied the media bucket's
// customTime lifecycle rule there and set it.
type ProfileMediaRetire string

const (
	// ProfileMediaRetireOff (default): the step publishes nothing and acks every message without acting.
	ProfileMediaRetireOff ProfileMediaRetire = "off"
	// ProfileMediaRetireAll: AVATAR images (the only profile image since the banner was removed). Set after the media
	// bucket's customTime lifecycle rule exists in the project (a tagged object without the rule outlives its TTL'd media
	// doc and escapes the account eraser) and after the app release that shows a placeholder for an avatar image that no
	// longer loads.
	ProfileMediaRetireAll ProfileMediaRetire = "all"
	// profileMediaRetireLegacyBanner is the value that once retired banners only. Banners are gone, so it parses as off
	// (it never covered avatars): a project that still sets it keeps starting and deletes nothing. Remove it once no
	// environment sets it.
	profileMediaRetireLegacyBanner = "banner"
)

func (m ProfileMediaRetire) valid() bool {
	switch m {
	case ProfileMediaRetireOff, ProfileMediaRetireAll:
		return true
	default:
		return false
	}
}

// Allows reports whether the switch lets the step retire an image of this media purpose ("AVATAR", the stored purpose
// name). It is the one rule publish, handler and opsctl share, so the three can never disagree.
func (m ProfileMediaRetire) Allows(purpose string) bool {
	return m == ProfileMediaRetireAll && purpose == "AVATAR"
}

// MediaOrphanSweep is MEDIA_ORPHAN_SWEEP: the kill switch of the media orphan sweep (internal/media/orphan_sweep.go), the
// last step of the daily-maintenance cron. Per-project operations config, not a FEATURE_ flag (no cohort, no allowlist, no
// RPC), and it defaults to off: a project marks or deletes nothing until its operator sets it.
type MediaOrphanSweep string

const (
	// MediaOrphanSweepOff (default): the step reads and writes nothing. Marks already written stay (the marked images keep
	// being refused by the attach and the resolvers) until the switch is raised again.
	MediaOrphanSweepOff MediaOrphanSweep = "off"
	// MediaOrphanSweepMark: phase 1 and the restore paths only. The sweep marks, holds, keeps and restores, but never
	// claims or deletes: a soak that shows what delete would remove.
	MediaOrphanSweepMark MediaOrphanSweep = "mark"
	// MediaOrphanSweepDelete: both phases (mark, then claim and delete at least OrphanGrace later).
	MediaOrphanSweepDelete MediaOrphanSweep = "delete"
)

func (m MediaOrphanSweep) valid() bool {
	switch m {
	case MediaOrphanSweepOff, MediaOrphanSweepMark, MediaOrphanSweepDelete:
		return true
	default:
		return false
	}
}

// Runs reports whether the sweep reads and writes at all (mark or delete). The zero value is off.
func (m MediaOrphanSweep) Runs() bool {
	return m == MediaOrphanSweepMark || m == MediaOrphanSweepDelete
}

// Deletes reports whether the sweep may claim and delete (delete only).
func (m MediaOrphanSweep) Deletes() bool { return m == MediaOrphanSweepDelete }

// ParseMediaOrphanSweep parses MEDIA_ORPHAN_SWEEP: "" is off, anything outside off|mark|delete is an error (startup fails).
func ParseMediaOrphanSweep(v string) (MediaOrphanSweep, error) {
	if v == "" {
		return MediaOrphanSweepOff, nil
	}
	m := MediaOrphanSweep(v)
	if !m.valid() {
		return "", fmt.Errorf("config: invalid MEDIA_ORPHAN_SWEEP %q (want off|mark|delete)", v)
	}
	return m, nil
}

// ParseProfileMediaRetire parses PROFILE_MEDIA_RETIRE: "" and the legacy "banner" are off, anything outside off|all is an
// error. Load uses it, and so does opsctl, which has no Cloud Run environment and reads the same variable from the
// operator's shell.
func ParseProfileMediaRetire(v string) (ProfileMediaRetire, error) {
	if v == "" || v == profileMediaRetireLegacyBanner {
		return ProfileMediaRetireOff, nil
	}
	m := ProfileMediaRetire(v)
	if !m.valid() {
		return "", fmt.Errorf("config: invalid PROFILE_MEDIA_RETIRE %q (want off|all)", v)
	}
	return m, nil
}
