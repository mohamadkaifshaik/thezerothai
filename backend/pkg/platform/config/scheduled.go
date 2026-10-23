package config

import (
	"fmt"
	"time"
)

// MaxScheduledSweepLimit is the largest SCHEDULED_SWEEP_LIMIT the sweep query takes (CLAUDE.md rule 5: every query
// has a Limit of at most 50). A larger configured value is clamped, as ADR-0021 Sweep step 2 says.
const MaxScheduledSweepLimit = 50

// ScheduledConfig holds the SCHEDULED_* limits of scheduled posts (ADR-0021 D4 "Limits", "Sweep" and "Rollout,
// tests, runbook" Config). The foundation PR consumes the storage and quota subset (MaxPending, TerminalTTL,
// PerAuthorPerRun); the Schedule/List/Cancel service and the sweep read the rest.
type ScheduledConfig struct {
	// MaxPending is the most PENDING items one user holds (SCHEDULED_MAX_PENDING, default 25). The pending count()
	// runs with Limit(MaxPending+1), so it still costs 1 read. Soft: the count runs outside the transaction.
	MaxPending int
	// Horizon is how far ahead publish_at may be (SCHEDULED_HORIZON, default 1440h = 60 days).
	Horizon time.Duration
	// MinLead is the least time between now and publish_at (SCHEDULED_MIN_LEAD, default 2m).
	MinLead time.Duration
	// PerAuthorPerRun is the most items of one author a sweep run publishes (SCHEDULED_PER_AUTHOR_PER_RUN,
	// default 3) and also the cap on PENDING items within +/-4 min of a new publish_at (the window cap, review L-3).
	PerAuthorPerRun int
	// AuthorReadsWarn is the reads one author's items may spend in one run before a scheduled_author_reads warning
	// (SCHEDULED_AUTHOR_READS_WARN, default 40, review L-4).
	AuthorReadsWarn int
	// SweepLimit is the Limit of the due query (SCHEDULED_SWEEP_LIMIT, default 50, clamped to
	// MaxScheduledSweepLimit); SweepMaxPages the pages per run (SCHEDULED_SWEEP_MAX_PAGES, default 2);
	// SweepConcurrency the author workers at once (SCHEDULED_SWEEP_CONCURRENCY, default 4).
	SweepLimit       int
	SweepMaxPages    int
	SweepConcurrency int
	// MaxLateness is how overdue an item may be before the sweep fails it EXPIRED (SCHEDULED_MAX_LATENESS,
	// default 6h).
	MaxLateness time.Duration
	// MaxAttempts is the transient publish failures before an item is FAILED INTERNAL (SCHEDULED_MAX_ATTEMPTS,
	// default 3).
	MaxAttempts int
	// TerminalTTL is how long a PUBLISHED, CANCELLED or FAILED-and-dismissed doc is kept (expireAt = the time it
	// entered a terminal state + TerminalTTL; SCHEDULED_TERMINAL_TTL, default 168h = 7 days).
	TerminalTTL time.Duration
}

// loadScheduled reads and validates the SCHEDULED_* keys. Every bound below is a typo guard, not a product rule:
// a value outside it fails startup instead of silently changing what is published or how much is read.
func loadScheduled() (ScheduledConfig, error) {
	var (
		c   ScheduledConfig
		err error
	)
	ints := []struct {
		dst      *int
		key      string
		def      int
		min, max int
	}{
		{&c.MaxPending, "SCHEDULED_MAX_PENDING", 25, 1, 100},
		{&c.PerAuthorPerRun, "SCHEDULED_PER_AUTHOR_PER_RUN", 3, 1, 10},
		{&c.AuthorReadsWarn, "SCHEDULED_AUTHOR_READS_WARN", 40, 1, 1000},
		{&c.SweepLimit, "SCHEDULED_SWEEP_LIMIT", MaxScheduledSweepLimit, 1, 1000},
		{&c.SweepMaxPages, "SCHEDULED_SWEEP_MAX_PAGES", 2, 1, 10},
		{&c.SweepConcurrency, "SCHEDULED_SWEEP_CONCURRENCY", 4, 1, 16},
		{&c.MaxAttempts, "SCHEDULED_MAX_ATTEMPTS", 3, 1, 10},
	}
	for _, f := range ints {
		if *f.dst, err = getInt(f.key, f.def); err != nil {
			return ScheduledConfig{}, err
		}
		if *f.dst < f.min || *f.dst > f.max {
			return ScheduledConfig{}, fmt.Errorf("config: %s must be between %d and %d (got %d)", f.key, f.min, f.max, *f.dst)
		}
	}
	c.SweepLimit = min(c.SweepLimit, MaxScheduledSweepLimit)

	durs := []struct {
		dst      *time.Duration
		key      string
		def      time.Duration
		min, max time.Duration
	}{
		{&c.Horizon, "SCHEDULED_HORIZON", 1440 * time.Hour, time.Hour, 8760 * time.Hour},
		{&c.MinLead, "SCHEDULED_MIN_LEAD", 2 * time.Minute, time.Minute, 24 * time.Hour},
		{&c.MaxLateness, "SCHEDULED_MAX_LATENESS", 6 * time.Hour, time.Minute, 168 * time.Hour},
		{&c.TerminalTTL, "SCHEDULED_TERMINAL_TTL", 168 * time.Hour, time.Hour, 720 * time.Hour},
	}
	for _, f := range durs {
		if *f.dst, err = getDuration(f.key, f.def); err != nil {
			return ScheduledConfig{}, err
		}
		if *f.dst < f.min || *f.dst > f.max {
			return ScheduledConfig{}, fmt.Errorf("config: %s %v must be between %v and %v", f.key, *f.dst, f.min, f.max)
		}
	}
	if c.MinLead >= c.Horizon {
		return ScheduledConfig{}, fmt.Errorf("config: SCHEDULED_MIN_LEAD %v must be shorter than SCHEDULED_HORIZON %v", c.MinLead, c.Horizon)
	}
	return c, nil
}
