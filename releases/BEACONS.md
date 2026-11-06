# Beacons ("Plans") readiness

Beacons are small meetups ("Plans") posted to a community or publicly: an organiser names an activity, a meeting
point, a start time, a duration and a number of open seats; others ask to join with a note, the organiser accepts or
declines, participants can leave, and the organiser can edit or cancel. The feature is behind `FEATURE_BEACONS`
(wire name `beacons`), off by default everywhere. This record says what shipped, how it was verified, how to roll it
out to a dev allowlist, what the pilot reads every day, and what still holds the verdict. The `releases/vX.Y.Z-readiness.md`
that gates a prod tag is written at tag time and cites this record.

## What shipped

Eight stacked pull requests, squash-merged in order:

- #708 `feat(beacons): proto` — `proto/dzeroth/beacons/v1/beacons.proto`: `BeaconService` (create, update, cancel,
  get, list public or by community, list mine, request to join, withdraw, respond, leave, remove participant, list
  participants); every list takes a limit and answers an opaque cursor; every write takes an idempotency key.
- #709 `feat(beacons): module` — `backend/internal/beacons`: Firestore layout `beacons/{beaconId}`,
  `beacons/{beaconId}/beaconParticipants/{uid}`, `users/{uid}/beaconMemberships/{beaconId}` (no other user's uid on a
  user-owned row), TTL on `expireAt`, the open-plans cap per user, the account eraser and export sections.
- #710 `feat(beacons): join` — the participation writes (request, withdraw, respond, leave, remove), the pending
  requests cap, seat accounting in one transaction per write.
- #711 `feat(beacons): moderation` — `REPORT_TARGET_TYPE_BEACON` with beacon evidence in `opsctl reports show`;
  `opsctl beacon hide|restore` (the platform hide: `NOT_FOUND` to everyone but the organiser, who still sees and
  manages it).
- #712 `feat(beacons): notifications` — `beacon_request`, `beacon_accepted`, `beacon_cancelled` through the
  notifications fan-out, chunked by the recipient cap.
- #714 `feat(app): beacons` — the Plans list (public and per community), plan detail and the create form, behind
  `enabled_features` `beacons`; the Plans rail entry and drawer entry.
- #715 `feat(app): plan join flow` — ask to join with a note, withdraw, leave, the organiser's People screen (accept,
  decline, decline and block, remove), My plans, edit; the three notification rows and their tap targets.
- this PR `chore(beacons): readiness` — `opsctl beacon counts`, the e2e smoke, the k6 list scenario, this record.

## Flags and limits

| Env | Default | Meaning |
|---|---|---|
| `FEATURE_BEACONS` | `off` | `off`, `allowlist`, `percent`, `on`; gates every `BeaconService` RPC. |
| `FEATURE_BEACONS_ALLOWLIST` | empty | Comma-separated Firebase uids (not a secret). Applies in `allowlist` and `percent`. |
| `FEATURE_BEACONS_PERCENT` | `0` | Only meaningful in `percent`. |
| `BEACONS_MAX_OPEN_PER_USER` | `5` | OPEN or FULL plans one organiser may hold; `LIMIT_REACHED` `beacons_open`. |
| `BEACONS_MAX_PENDING_REQUESTS` | `10` | Live join requests one user may hold; `LIMIT_REACHED` `beacon_requests_pending`. |
| `BEACONS_MAX_OPEN_SPOTS` | `20` | Seats beyond the organiser; `VALIDATION` `open_spots`. |
| `RATE_LIMIT_BEACONS_WRITE_PER_MIN` | `10` | Create, update, cancel per user per minute. |
| `RATE_LIMIT_BEACONS_ACTION_PER_MIN` | `20` | Request, withdraw, respond, leave, remove per user per minute. |
| `RATE_LIMIT_BEACONS_READ_PER_MIN` | `30` | Get and the lists per user per minute. |
| `BEACONS_CREATED_PER_DAY` | `10` | Daily creation quota per user. |

`scripts/promotion/flag-ceiling.json` caps `BEACONS` in dev at `allowlist` with at most 6 uids and 0 percent; the
promotion validators refuse a deploy above that. Text rules: title 1–60, details 0–300, meeting point 1–80, join
note 0–140 code points, each a single line.

## Rollout in dev

The order is off → allowlist → percent → on, never ahead of communities (a community plan needs
`FEATURE_COMMUNITIES` for the same users; a public plan does not).

1. Pick the pilot uids (at most 6, the ceiling) and make sure each is on `feature_communities_allowlist` first if the
   pilot uses a community audience.
2. In `infra/terraform/envs/dev` set `feature_beacons = "allowlist"` and `feature_beacons_allowlist = "<uid>,<uid>"`
   (the limits above are already explicit in `main.tf` at their defaults).
3. Open the PR; CI runs `terraform plan` and `check-flag-registry.sh`. A human applies.
4. Confirm with one allowlisted account: Plans appears in the rail, a public plan can be created, listed and
   cancelled. The e2e smoke does the same against the dev URL:
   `E2E_BEACONS_BASE_URL=<dev api> E2E_BEACONS_ID_TOKEN_A=<token> E2E_BEACONS_ID_TOKEN_B=<token> go test -tags=integration -run TestE2E_Beacons ./e2e/`
   (two allowlisted accounts with profiles; about 14 requests; it cancels what it creates).
5. Read the pilot every day with `opsctl beacon counts --project dzeroth-dev` (below). The brakes are
   `opsctl beacon hide BEACON_ID --project dzeroth-dev [--report R]` for one plan, and `feature_beacons = "off"` for
   the feature; both take effect on the next request.

## Pilot metrics

`opsctl beacon counts --project P` is read-only and prints four aggregate counts, one per line, nothing per plan or
per user:

```
beacons_open=…
beacons_full=…
beacons_cancelled=…
beacons_hidden=…
```

They come from count aggregations over `beacons/` (no document is read). `beacons_open` and `beacons_hidden` are
independent: a hidden OPEN plan is in both. `beacons_full` against `beacons_open` says whether plans fill;
`beacons_cancelled` against the sum says whether they happen. Participant-level counts (requests pending, seats
taken) are not here: a collection-group count over `beaconParticipants.state` needs a collection-group index in
`firebase/firestore.indexes.json`, a reviewed change for a later PR. The manual pilot's own tally (plans facilitated,
people who came) is the signal this record is waiting for.

## Verification

- `make ci` green on every PR (Go fmt, vet, unit tests with the 70% gate on `pkg/platform`, lint, buf lint and
  breaking, Flutter analyze and the full Flutter suite: 10,350 tests at #715).
- `make test-int` (or its inner command against standing emulators) on the backend PRs: the beacons repository
  integration tests (create, caps, participation, seat accounting, cancel, hidden, eraser, TTL fields), the apiserver
  lifecycle chain `TestBeaconNotifications_RequestAcceptCancelChain`, the moderation chain, and the account export
  golden with the `beacons` section.
- E2E smoke `TestE2E_BeaconsSmoke_RequestAcceptLeaveCancel` (`backend/e2e/beacons_smoke_test.go`) over the real
  handler against the emulators: create public → list public → get → request with a note → organiser lists the
  request and its note → accept → organiser lists who is going → participant gets `can_leave` with one seat taken →
  leave → cancel → `CANCELLED` on get and in My plans → cancel again (idempotent). Passed.
- Load (`make loadtest SCENARIO=beacons_list`, emulators, indicative only): 40 callers, 20 public plans,
  `ListBeacons` at 10 rps and `GetBeacon` at 3 rps for 2 minutes:

  | RPC | p95 | Requests |
  |---|---|---|
  | `ListBeacons` (page 20) | 20.6 ms | 1,200 |
  | `GetBeacon` | 6.9 ms | 360 |

  0 failed requests, 0 unexpected responses, 0 `ERROR` lines in the API log. `setup()` refuses a shape that would
  exceed the per-user read limiter instead of raising it.
- Fresh whole-branch code review on every PR with a fix pass for every Critical or Important finding, each fix with
  a failing-first test; the deferred minors are listed below.
- Not done: no deployment to dev or prod, no `terraform apply`, no traffic shift; nothing in this record was run
  against a GCP project.

## Policy notes

- **Public communities are the boundary.** Anyone who joins a public community sees and can request its plans. That
  is acceptable for an invited cohort and not for a public launch; private communities are the fix before `percent`.
- **No age gating.** "Adult-only" is a cohort policy enforced by who is allowlisted, not by the code. Nothing checks
  age anywhere.
- **Membership is not verified.** A plan says where and when to meet; the organiser decides whom to accept. Meeting
  points are named places, never coordinates.
- **Moderation.** Every plan is a report target; `opsctl beacon hide` is the only platform lever. The pending-requests
  cap, the per-minute buckets and the client's "Decline and block" are the brakes on repeat requests. Notifications
  are chunked by the recipient cap, so a cancel of a 20-seat plan is two events; a near-exhausted organiser daily
  budget can drop the second chunk (PR 5 ruling, with solution-architect).
- **Scheduler.** No reminders ship; the one free Scheduler job in prod is untouched.

## Known limits and carried items

- Participant-level pilot counts need a collection-group index (above).
- A cancel of a plan with more accepted participants than the recipient cap fans out in chunks; the daily cap
  admits each chunk whole or not at all (PR 5).
- `ListMyBeacons` shows organised rows and REQUESTED or ACCEPTED rows only; terminal rows are not history (PR 3).
- `ListParticipants` applies blocks between the viewer and the organiser only, not between participants (PR 3).
- An ex-member of a community whose plan accepted them still shows as ACCEPTED (PR 3, product ruling pending).
- Deferred review minors by PR: #709 (proto header wording, block-before-membership order in `resolve`, `p.Now`
  versus the repo clock on update and cancel); #710 (re-request on a full plan answers `full` before the no-op);
  #711 (`FEATURE_DISABLED` versus `NOT_FOUND` on a report of a community plan with communities off, test nits);
  #712 (a logger swap in a test, a fake helper, `beacon_hash` naming); #714 (a static flag-off test, a stale community
  chip, UNSPECIFIED copy); #715 (a plain-decline fallback without a graph repository, duplicated block copy, a
  nullable onboarding lookup, the edit form's read-only lines, a non-organiser deep link to edit).

## Verdict

Verdict: HOLD — pending the manual pilot signal (docs/beacons-plan.md section 8). The code is verified as above and
ready for the dev allowlist; the prod tag's readiness record is written once the pilot has run and this record's
policy notes have been accepted for the cohort.
