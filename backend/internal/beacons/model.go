package beacons

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Field limits in code points after trim and NFC (docs/beacons-plan.md section 3).
const (
	MinTitleRunes   = 1
	MaxTitleRunes   = 60
	MaxDetailsRunes = 300
	MinVenueRunes   = 1
	MaxVenueRunes   = 80
	MaxNoteRunes    = 140

	// MinDurationMin and MaxDurationMin bound duration_minutes.
	MinDurationMin = 15
	MaxDurationMin = 240
	// MinStartLead and MaxStartLead bound start_at relative to now.
	MinStartLead = 5 * time.Minute
	MaxStartLead = 30 * 24 * time.Hour
	// ExpireAfterStart is the Firestore TTL on expireAt, counted from start_at.
	ExpireAfterStart = 30 * 24 * time.Hour
)

// Activity is the stored form of BeaconActivity.
type Activity string

// The seven activities.
const (
	ActivityCoffee   Activity = "coffee"
	ActivityMeal     Activity = "meal"
	ActivityStudy    Activity = "study"
	ActivitySports   Activity = "sports"
	ActivityWalk     Activity = "walk"
	ActivityShopping Activity = "shopping"
	ActivityOther    Activity = "other"
)

// Cost is the stored form of BeaconCost.
type Cost string

// The three cost expectations.
const (
	CostFree            Cost = "free"
	CostEveryonePaysOwn Cost = "everyone_pays_own"
	CostSplitEvenly     Cost = "split_evenly"
)

// ChatPref is the stored form of ChatPreference: an expectation shown on the beacon, never enforced.
type ChatPref string

// The three conversation preferences.
const (
	ChatQuiet       ChatPref = "quiet"
	ChatTaskFocused ChatPref = "task_focused"
	ChatOpen        ChatPref = "open_to_chat"
)

// Status is a beacon's state. Open, Full and Cancelled are stored; Ended is derived at read time and never stored.
type Status string

// The four statuses.
const (
	StatusOpen      Status = "open"
	StatusFull      Status = "full"
	StatusCancelled Status = "cancelled"
	StatusEnded     Status = "ended"
)

// EligibilityEveryone is the only eligibility at v1 (docs/beacons-plan.md D4).
const EligibilityEveryone = "everyone"

// Beacon is one beacons/{beaconId} document as the module sees it.
type Beacon struct {
	ID          string
	OrganiserID string
	// CommunityID is "" for a public beacon.
	CommunityID   string
	Activity      Activity
	Title         string
	Details       string
	Venue         string
	StartAt       time.Time
	EndAt         time.Time
	DurationMin   int
	OpenSpots     int
	AcceptedCount int
	Cost          Cost
	ChatPref      ChatPref
	// Status is the stored status; read it through EffectiveStatus.
	Status Status
	// Hidden is the platform hide (opsctl): absent in storage means false. The organiser still sees a hidden beacon.
	Hidden    bool
	CreatedAt time.Time
	UpdatedAt time.Time
	ExpireAt  time.Time
}

// EffectiveStatus is the status a reader sees at now: CANCELLED is final; otherwise ENDED from EndAt on; otherwise the
// stored OPEN or FULL.
func (b Beacon) EffectiveStatus(now time.Time) Status {
	if b.Status == StatusCancelled {
		return StatusCancelled
	}
	if !now.Before(b.EndAt) {
		return StatusEnded
	}
	return b.Status
}

// Membership roles and states of users/{uid}/beaconMemberships/{beaconId}.
const (
	RoleOrganiser   = "organiser"
	RoleParticipant = "participant"
	RoleRequester   = "requester"
	RoleNone        = "none"
)

// Membership is one users/{uid}/beaconMemberships/{beaconId} row: the user's relationship with a beacon, holding no other
// user's uid (R3), so it may dangle after the organiser's erasure.
type Membership struct {
	BeaconID string
	// Role is RoleOrganiser, RoleParticipant or RoleRequester.
	Role string
	// State mirrors the beacon status for the organiser ("open", "cancelled") and the participant state otherwise.
	State       string
	CommunityID string
	StartAt     time.Time
	EndAt       time.Time
}

// ViewerState is the caller's relationship with a beacon, so the client renders the right action without a second call.
type ViewerState struct {
	// Role is RoleOrganiser, RoleParticipant or RoleNone.
	Role string
	// ParticipantState is "" when the viewer never requested (PR 3 fills it).
	ParticipantState string
	CanRequest       bool
	CanWithdraw      bool
	CanLeave         bool
	CanManage        bool
}

// View is one beacon as the caller may see it: the beacon with its effective status, the organiser's live profile row and
// the caller's state.
type View struct {
	Beacon    Beacon
	Organiser identity.Profile
	Viewer    ViewerState
}

// CreateInput is a CreateBeacon request after the transport layer. Exactly one of CommunityID and Public is set.
type CreateInput struct {
	Key         string
	CommunityID string
	Public      bool
	Activity    Activity
	Title       string
	Details     string
	Venue       string
	StartAt     time.Time
	DurationMin int
	OpenSpots   int
	Cost        Cost
	ChatPref    ChatPref
}

// UpdateInput is an UpdateBeacon request: a nil field is unchanged.
type UpdateInput struct {
	Key       string
	BeaconID  string
	Title     *string
	Details   *string
	Venue     *string
	OpenSpots *int
}

// ListInput is a ListBeacons request after the transport layer. Exactly one of CommunityID and Public is set; a zero
// From means now.
type ListInput struct {
	CommunityID string
	Public      bool
	From        time.Time
	Limit       int32
	PageToken   string
}

// Page is one page of views, soonest first, and the opaque next token ("" = no more; a page may be short while it is set,
// R8).
type Page struct {
	Views         []View
	NextPageToken string
}

// Outcome is how a repository write ended; the service logs it.
type Outcome int

const (
	// Written: the documents changed.
	Written Outcome = iota
	// Replayed: the idempotency record already existed and answered; nothing was written.
	Replayed
	// Unchanged: only the idempotency document was written.
	Unchanged
)

// Errors of the repository and the rules, mapped to Connect codes by the service only.
var (
	// ErrNotFound is the one cause-blind answer for a beacon the caller cannot see (missing, hidden, a block either way).
	ErrNotFound = errors.New("beacons: beacon not found")
	// ErrKeyReused: the idempotency key was used for a different request body.
	ErrKeyReused = errors.New("beacons: idempotency key reused")
	// ErrOpenLimit: the organiser holds BEACONS_MAX_OPEN_PER_USER live OPEN or FULL beacons.
	ErrOpenLimit = errors.New("beacons: open beacon limit reached")
	// ErrSpotsLimit: open_spots is above BEACONS_MAX_OPEN_SPOTS.
	ErrSpotsLimit = errors.New("beacons: open spots limit reached")
	// ErrNotOrganiser: an organiser-only action by someone else.
	ErrNotOrganiser = errors.New("beacons: not the organiser")
	// ErrNotMember: a community beacon and the caller is not a JOINED member (none or banned).
	ErrNotMember = errors.New("beacons: not a member of the community")
	// ErrEnded: a mutation on a beacon whose end time passed.
	ErrEnded = errors.New("beacons: beacon ended")
	// ErrCancelled: a mutation on a cancelled beacon.
	ErrCancelled = errors.New("beacons: beacon cancelled")
)

// CreateParams is one CreateBeacon write. Beacon carries every field but Status, AcceptedCount and the timestamps, which
// the repository sets.
type CreateParams struct {
	UID, ID, IdemKey, RequestHash string
	Beacon                        Beacon
	MaxOpenPerUser                int
}

// CreateResult is what Repo.Create answers: the beacon as stored, or as it is now on a replay.
type CreateResult struct {
	Outcome Outcome
	Beacon  Beacon
}

// UpdateParams is one UpdateBeacon write. Now decides ENDED.
type UpdateParams struct {
	UID, BeaconID, IdemKey, RequestHash string
	Title, Details, Venue               *string
	OpenSpots                           *int
	Now                                 time.Time
}

// UpdateResult is what Repo.Update answers: the beacon after the write (or as it is now on a replay).
type UpdateResult struct {
	Outcome Outcome
	Beacon  Beacon
}

// CancelParams is one CancelBeacon write. Now decides ENDED.
type CancelParams struct {
	UID, BeaconID, IdemKey, RequestHash string
	Now                                 time.Time
}

// CancelResult is what Repo.Cancel answers.
type CancelResult struct {
	Outcome Outcome
	Beacon  Beacon
}

// ListQuery is one ListByAudience read: communityId == CommunityID ("" = public), status in [open, full], startAt >= From,
// ordered by startAt then id, resuming after (AfterStartAt, AfterID) when AfterID is set, at most Limit docs.
type ListQuery struct {
	CommunityID  string
	From         time.Time
	AfterStartAt time.Time
	AfterID      string
	Limit        int
}

// Repo is the storage of the write path and the raw reads (FirestoreRepo in production). Every mutation is one
// transaction that reads the idempotency document first (a replay returns there) and writes it last.
type Repo interface {
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	Update(ctx context.Context, p UpdateParams) (UpdateResult, error)
	Cancel(ctx context.Context, p CancelParams) (CancelResult, error)
	// Get reads beacons/{id} outside any transaction: ErrNotFound when it does not exist. It does not decide who may see
	// the beacon; the service applies the visibility rules.
	Get(ctx context.Context, id string) (Beacon, error)
	// ListByAudience runs ListQuery (reads = docs returned, minimum 1). Hidden beacons are returned; filtering is the
	// service's.
	ListByAudience(ctx context.Context, q ListQuery) ([]Beacon, error)
}

// Service is everything the BeaconService handlers call for the RPCs this PR implements.
type Service interface {
	// CreateBeacon creates a beacon organised by uid. A replay and a beacon at the cap write nothing.
	CreateBeacon(ctx context.Context, uid string, in CreateInput) (View, error)
	// UpdateBeacon changes the set fields of one of uid's OPEN or FULL beacons.
	UpdateBeacon(ctx context.Context, uid string, in UpdateInput) (View, error)
	// CancelBeacon cancels one of uid's OPEN or FULL beacons; already CANCELLED is success with the idempotency doc only.
	CancelBeacon(ctx context.Context, uid, key, beaconID string) error
	// GetBeacon returns one beacon as viewer may see it.
	GetBeacon(ctx context.Context, viewer, beaconID string) (View, error)
	// ListBeacons returns a page of OPEN and FULL beacons of one audience, soonest first.
	ListBeacons(ctx context.Context, viewer string, in ListInput) (Page, error)
}

// Limits are the caps the service needs, from config (BeaconsConfig).
type Limits struct {
	MaxOpenPerUser     int
	MaxPendingRequests int
	MaxOpenSpots       int
}

// IDSource issues beacon ids (a Snowflake node). *snowflake.Node satisfies it.
type IDSource interface {
	Generate() string
}

// Deps is everything New needs.
type Deps struct {
	Repo      Repo
	Directory identity.Directory
	// Graph is the viewer's social context (cache-first, 60 s): a block in either direction hides a beacon.
	Graph graph.Reader
	// Communities answers the viewer's role in a community-audience beacon's community (cache-first, 60 s).
	Communities communities.Reader
	// CommunityFlags is the FEATURE_COMMUNITIES gate a community audience adds (the same registry as the beacons flag).
	CommunityFlags FlagChecker
	IDs            IDSource
	// CursorKey seals the page tokens of ListBeacons (cfg.CursorHMACKey).
	CursorKey []byte
	Limits    Limits
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}
