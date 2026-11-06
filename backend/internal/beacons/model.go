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

// Participant states of beacons/{beaconId}/beaconParticipants/{uid} (the stored strings of ParticipantState).
// REQUESTED -> ACCEPTED | DECLINED | WITHDRAWN; ACCEPTED -> LEFT | REMOVED.
const (
	PStateRequested = "requested"
	PStateAccepted  = "accepted"
	PStateDeclined  = "declined"
	PStateWithdrawn = "withdrawn"
	PStateLeft      = "left"
	PStateRemoved   = "removed"
)

// canRequestAgain reports whether a (possibly absent, "") participant row lets its user request to join: a row that
// ended in DECLINED, WITHDRAWN, LEFT or REMOVED is reused; REQUESTED (already_requested) and ACCEPTED (a no-op success)
// are the caller's to answer.
func canRequestAgain(state string) bool {
	switch state {
	case "", PStateDeclined, PStateWithdrawn, PStateLeft, PStateRemoved:
		return true
	}
	return false
}

// Participant is one beacons/{beaconId}/beaconParticipants/{uid} row.
type Participant struct {
	BeaconID string
	UID      string
	State    string
	// Note is the requester's note (0-140 code points), shown to the organiser on REQUESTED rows only.
	Note        string
	RequestedAt time.Time
	RespondedAt time.Time
	// ExpireAt is the beacon's expireAt (the TTL on this collection group).
	ExpireAt time.Time
}

// ParticipantRow is a participant with their live profile row.
type ParticipantRow struct {
	Participant Participant
	User        identity.Profile
}

// ParticipantsPage is one page of ListParticipants, oldest first, with the opaque next token ("" = no more).
type ParticipantsPage struct {
	Rows          []ParticipantRow
	NextPageToken string
}

// MyBeaconsInput is a ListMyBeacons request after the transport layer. Role is RoleOrganiser, RoleParticipant (accepted
// and requested rows) or "" for all; Past selects beacons whose end passed, else the upcoming ones.
type MyBeaconsInput struct {
	Role      string
	Past      bool
	Limit     int32
	PageToken string
}

// ListParticipantsInput is a ListParticipants request after the transport layer: Requested selects the REQUESTED rows
// (organiser only), else the ACCEPTED ones.
type ListParticipantsInput struct {
	BeaconID  string
	Requested bool
	Limit     int32
	PageToken string
}

// Membership is one users/{uid}/beaconMemberships/{beaconId} row: the user's relationship with a beacon, holding no other
// user's uid (R3), so it may dangle after the organiser's erasure.
type Membership struct {
	BeaconID string
	// Role is RoleOrganiser, RoleParticipant or RoleRequester.
	Role string
	// State mirrors the beacon status for the organiser ("open", "cancelled") and the participant state otherwise.
	State string
	// Pending is true exactly while Role is RoleRequester and State is requested (the pending-request cap, R10).
	Pending     bool
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
	// ErrFull: a request or an accept while every seat is taken.
	ErrFull = errors.New("beacons: beacon full")
	// ErrAlreadyRequested: a request while a REQUESTED row exists.
	ErrAlreadyRequested = errors.New("beacons: already requested")
	// ErrNotRequested: a withdraw or a response without a REQUESTED row.
	ErrNotRequested = errors.New("beacons: not requested")
	// ErrNotParticipant: a leave or a removal without an ACCEPTED row.
	ErrNotParticipant = errors.New("beacons: not a participant")
	// ErrPendingLimit: the requester holds BEACONS_MAX_PENDING_REQUESTS live requests.
	ErrPendingLimit = errors.New("beacons: pending request limit reached")
	// ErrOrganiser: the organiser asked to join their own beacon.
	ErrOrganiser = errors.New("beacons: the organiser cannot join")
)

// RequestParams is one RequestToJoin write. Now decides the beacon's state and stamps requestedAt.
type RequestParams struct {
	UID, BeaconID, IdemKey, RequestHash, Note string
	MaxPending                                int
	Now                                       time.Time
}

// ParticipantResult is what the five participation writes answer: the beacon and the caller's (or the target's)
// participant row as stored, or as they are now on a replay.
type ParticipantResult struct {
	Outcome     Outcome
	Beacon      Beacon
	Participant Participant
}

// RespondParams is one RespondToJoinRequest write by the organiser UID on TargetUID's REQUESTED row.
type RespondParams struct {
	UID, BeaconID, TargetUID, IdemKey, RequestHash string
	Accept                                         bool
	Now                                            time.Time
}

// StateParams is one Withdraw (TargetUID == UID), Leave (TargetUID == UID) or Remove (UID is the organiser) write.
type StateParams struct {
	UID, BeaconID, TargetUID, IdemKey, RequestHash string
	Now                                            time.Time
}

// MembershipQuery is one ListMemberships read of users/{UID}/beaconMemberships: Roles filters the role (nil = all); Past
// selects endAt < Now (most recent first) else endAt >= Now (soonest first); resumes after (AfterEndAt, AfterID).
type MembershipQuery struct {
	UID        string
	Roles      []string
	Past       bool
	Now        time.Time
	AfterEndAt time.Time
	AfterID    string
	Limit      int
}

// ParticipantQuery is one ListParticipants read: the rows of BeaconID in State, oldest first (respondedAt for ACCEPTED,
// requestedAt for REQUESTED), resuming after (AfterAt, AfterUID).
type ParticipantQuery struct {
	BeaconID string
	State    string
	AfterAt  time.Time
	AfterUID string
	Limit    int
}

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

	// Participation (PR 3): one transaction each, idempotency first, the beacon and the participant row read before any
	// write, acceptedCount and status kept on the beacon.
	Request(ctx context.Context, p RequestParams) (ParticipantResult, error)
	Withdraw(ctx context.Context, p StateParams) (ParticipantResult, error)
	Respond(ctx context.Context, p RespondParams) (ParticipantResult, error)
	Leave(ctx context.Context, p StateParams) (ParticipantResult, error)
	Remove(ctx context.Context, p StateParams) (ParticipantResult, error)
	// GetParticipant reads one participant row outside any transaction: ErrNotFound when there is none.
	GetParticipant(ctx context.Context, beaconID, uid string) (Participant, error)
	// ListMemberships runs MembershipQuery (reads = rows returned, minimum 1).
	ListMemberships(ctx context.Context, q MembershipQuery) ([]Membership, error)
	// GetBeacons reads the named beacons in one GetAll; missing ids are absent from the map.
	GetBeacons(ctx context.Context, ids []string) (map[string]Beacon, error)
	// ListParticipants runs ParticipantQuery (reads = rows returned, minimum 1).
	ListParticipants(ctx context.Context, q ParticipantQuery) ([]Participant, error)
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

	// Participation (PR 3). Each proves the caller may see the beacon first (NOT_FOUND / not_member), then applies the
	// proto's rules; the organiser-only ones answer FORBIDDEN not_organiser to anyone else.
	RequestToJoin(ctx context.Context, uid, key, beaconID, note string) (ViewerState, error)
	WithdrawJoinRequest(ctx context.Context, uid, key, beaconID string) error
	RespondToJoinRequest(ctx context.Context, uid, key, beaconID, targetUID string, accept bool) (View, error)
	LeaveBeacon(ctx context.Context, uid, key, beaconID string) error
	RemoveParticipant(ctx context.Context, uid, key, beaconID, targetUID string) (View, error)
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
