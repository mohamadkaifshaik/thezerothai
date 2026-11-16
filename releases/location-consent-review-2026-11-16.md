# Location feature: consent copy review pack

Date: 2026-11-16. Local only (docs/ is git-ignored, .gitignore:43). Not legal advice: this is an inventory of what the source says and does, with file:line citations, for counsel to review.

Method: read-only pass over the working tree of branch `chore/infra-beacons-cancelled-per-day` (HEAD cf2f99aa when read). The session-start snapshot listed HEAD as ee411d9e; the checkout moved during the review, so line numbers below are from the current tree. Strings are Dart literals (there are no .arb or l10n files in app/; grep for `arb` and `l10n` returned nothing). Line numbers are for the files as read. Nothing was run, built, or deployed; the live app and the deployed Firestore state were not inspected.

Path prefixes: `app/lib/` = `A:`, `backend/internal/` = `B:`, `proto/` as written. Full paths are in the headings where needed.

## 0. Counts

- User-facing strings in the Location feature (sections 1.1 to 1.6): 68 rows (S-01 to S-68).
- Adjacent strings outside the feature that mention location or nearby (section 1.7): 6 rows, not counted above.
- Mismatches between copy and behaviour (section 3): 14 (M-01 to M-14): 6 omissions, 4 over-claims, 3 inconsistencies between surfaces, 1 ambiguity.
- Privacy page: no Location section and no plans/beacons section (section 4).
- Open questions for counsel (section 5): 12.

## 1. User-facing strings

Surfaces: Settings > Location (`/settings/location`), the consent screen (`/settings/location/consent`, the "rationale", which is a full screen, not a dialog), the area picker (`/area-picker`), Explore > Nearby tab and Explore settings, plan area labels and the plan form field, the desktop "Happening nearby" hero. There is no consent dialog in the code. Strings are quoted exactly as written in the source; `$x` is an interpolation.

### 1.1 Constants: `app/lib/features/location/domain/location_copy.dart`

| ID | Key | Verbatim text | File:line | Where shown |
|---|---|---|---|---|
| S-01 | kLocationSettingsTitle | `Location` | location_copy.dart:6 | Settings > Location title; also Settings row title (settings_screen.dart:1080) |
| S-02 | kLocationExplainer | `Dzeroth stores only the area you choose. It never reads your phone's location.` | location_copy.dart:7-9 | Settings > Location, area set (location_settings_screen.dart:140) and no area with flag on (:178) |
| S-03 | kLocationChooseArea | `Choose your area` | location_copy.dart:10 | Button with no area (location_settings_screen.dart:183) |
| S-04 | kLocationChangeArea | `Change area` | location_copy.dart:11 | Row, flag on (location_settings_screen.dart:153) |
| S-05 | kLocationClearArea | `Clear my area` | location_copy.dart:12 | Destructive row, no confirmation (location_settings_screen.dart:159) |
| S-06 | kLocationCleared | `Location cleared` | location_copy.dart:13 | Snackbar after clear (location_settings_screen.dart:90) |
| S-07 | kLocationNotSet | `Not set` | location_copy.dart:14 | Subtitle when no area (settings_screen.dart:1081; explore_settings_screen.dart:46) |
| S-08 | kLocationOffTitle | `Location is not available` | location_copy.dart:15 | Headline when flag off and no area, or no cubit (location_settings_screen.dart:61, :128) |
| S-09 | kLocationOffBody | `There is no area stored for your account.` | location_copy.dart:16 | Body under S-08 (same lines) |
| S-10 | kLocationOffStoredNote | `Location is switched off for now. Your stored area stays private to you, and you can clear it here.` | location_copy.dart:17-19 | Note when flag off and an area is stored (location_settings_screen.dart:136) |
| S-11 | kLocationRationaleTitle | `Before you choose an area` | location_copy.dart:21 | Consent screen AppBar (location_rationale_screen.dart:296) |
| S-12 | kLocationRationaleStored | `What is stored: the one area you pick (a neighbourhood or a city), the time you agreed and the version of this text. No coordinates, no device location.` | location_copy.dart:22-25 | Consent screen line 1 (location_rationale_screen.dart:309) |
| S-13 | kLocationRationaleWhy | `Why: so plans in or near your area can be shown to you.` | location_copy.dart:26-27 | Consent screen line 2 (:310) |
| S-14 | kLocationRationaleWho | `Who sees it: only you. A plan shows the area its organiser chose for the plan, never where you live.` | location_copy.dart:28-30 | Consent screen line 3 (:311) |
| S-15 | kLocationRationaleWithdraw | `Withdraw any time: Settings > Location > Clear my area removes it at once.` | location_copy.dart:31-33 | Consent screen line 4 (:312) |
| S-16 | (literal, uses kLocationConsentCopyVersion = 1) | `Notice version $kLocationConsentCopyVersion` | location_rationale_screen.dart:318; value location_copy.dart:4 | Consent screen, renders "Notice version 1" |
| S-17 | kLocationAdultTick | `I am 18 or older` | location_copy.dart:34 | Checkbox, required to continue (location_rationale_screen.dart:329) |
| S-18 | kLocationContinue | `Continue` | location_copy.dart:35 | Button, enabled only when ticked (location_rationale_screen.dart:341) |
| S-19 | kLocationPickerTitle | `Choose your area` | location_copy.dart:37 | Picker AppBar (area_picker_screen.dart:26); also the plan-form picker |
| S-20 | kLocationSearchHint | `Search areas and cities` | location_copy.dart:38 | Picker search field hint (area_picker_screen.dart:62) |
| S-21 | kLocationPickerEmptyTitle | `No areas match` | location_copy.dart:39 | Picker empty state (area_picker_screen.dart:35, :85) |
| S-22 | kLocationPickerEmptyBody | `Try another spelling or a nearby city.` | location_copy.dart:40 | Subtitle under S-21 (area_picker_screen.dart:86) |
| S-23 | kExploreSettingsTitle | `Explore settings` | location_copy.dart:42 | AppBar of Explore settings (explore_settings_screen.dart:21) |
| S-24 | kExploreSettingsNearbyGroup | `Nearby` | location_copy.dart:43 | Group title (explore_settings_screen.dart:35) |
| S-25 | kExploreSettingsAreaRow | `Your area` | location_copy.dart:44 | Row title (explore_settings_screen.dart:45) |
| S-26 | locationAllOf(city) | `All of $city` | location_copy.dart:47 | City row in picker (area_picker_screen.dart:130) |

### 1.2 Location screens, literals and errors

| ID | Verbatim text | File:line | Where shown |
|---|---|---|---|
| S-27 | `Loading location` (semanticsLabel) | location_settings_screen.dart:118 | Screen reader label while loading |
| S-28 | `Your area` (literal, same text as S-25) | location_settings_screen.dart:146 | Row title for the area |
| S-29 | `You agreed on ${at.day} ${month} ${at.year}.` (e.g. "You agreed on 16 Nov 2026.") | location_settings_screen.dart:234 | Under the area row; date from consent `at` (settings from area doc consentedAt) |
| S-30 | `Couldn't load areas.` | area_picker_screen.dart:77 | Fallback error text in picker |
| S-31 | `Please agree to the location notice to continue.` | location_error_messages.dart:20 | SetArea consent_required fallback |
| S-32 | `You've changed your location choice too many times today. Try again tomorrow.` (two literals joined, :22-23) | location_error_messages.dart:22-23 | Daily consent-change cap (LIMIT_REACHED) |
| S-33 | `Update the app to change your location settings.` | location_error_messages.dart:25 | Server requires newer copy than this build |
| S-34 | `Location is not available for your account right now.` | location_error_messages.dart:27 | FEATURE_DISABLED |
| S-35 | `Please sign in again.` | location_error_messages.dart:29 | Unauthenticated |
| S-36 | `Couldn't reach Dzeroth. Check your connection.` | location_error_messages.dart:30 | Network |
| S-37 | `Something went wrong. Please try again.` | location_error_messages.dart:31 | Any other error |

Errors are shown in snackbars from location_settings_screen.dart:85-87 and in the picker via AppErrorView (area_picker_screen.dart:74-79).

### 1.3 Settings

| ID | Verbatim text | File:line | Where shown |
|---|---|---|---|
| S-38 | `location` (lower case, joined into the Privacy category summary, which renders it capitalised) | settings_screen.dart:849 | Settings > Privacy row subtitle when the Location row is present |

### 1.4 Explore > Nearby tab (`app/lib/features/search/` and `app/lib/features/beacons/`)

| ID | Verbatim text | File:line | Where shown |
|---|---|---|---|
| S-39 | `Nearby` | search/domain/explore_tab.dart:5 | Explore tab label |
| S-40 | `Settings` | search/presentation/explore_screen.dart:154 | Tooltip of the Explore gear; with location on it opens Explore settings (:155-157) |
| S-41 | `See plans near you` | search/presentation/widgets/explore_nearby_section.dart:18 | Empty prompt title, no area |
| S-42 | `Choose an area to see public plans in it and around it.` | explore_nearby_section.dart:19-20 | Empty prompt body |
| S-43 | `Choose an area` | explore_nearby_section.dart:21 | Prompt button (:83) |
| S-44 | `Change area` | explore_nearby_section.dart:22 | Header text button (:212) |
| S-45 | `Your area` | explore_nearby_section.dart:23 | Scope chip, neighbourhood scope (:202) |
| S-46 | `All of $city` | explore_nearby_section.dart:26 | Scope chip, city scope (:201) |
| S-47 | `No plans near $area yet` (area falls back to `you`, :123) | explore_nearby_section.dart:29, :123 | Empty list title |
| S-48 | `Plans anyone can join show up here.` | explore_nearby_section.dart:124 | Empty list subtitle |
| S-49 | `A few plans` | explore_nearby_section.dart:38 | Count line when below the K-anonymity minimum |
| S-50 | `1 plan` / `$n plans` / `About $n plans` / `About 1000+ plans` | explore_nearby_section.dart:41-43 | Count line (n is the server count) |
| S-51 | `In your area` / `In your area · ${area.name}` | explore_nearby_section.dart:178 | Card heading |
| S-52 | `Try again` | explore_nearby_section.dart:97 | Error retry |
| S-53 | `Loading more plans` (semanticsLabel) | explore_nearby_section.dart:250 | Screen reader label |
| S-54 | `Load more` | explore_nearby_section.dart:260 | Paging button |

### 1.5 Plan area labels and plan form

| ID | Verbatim text | File:line | Where shown |
|---|---|---|---|
| S-55 | `In your area` | beacons/presentation/widgets/area_label.dart:33 | Nearby rows with same-area proximity |
| S-56 | `Nearby: $name` | area_label.dart:34 | Nearby rows with neighbouring-area proximity |
| S-57 | `In $city` | area_label.dart:35 | Nearby rows in the same city (city scope) |
| S-58 | `$name, $cityName` (or name alone for a city) | area_label.dart:36-41 | Plan area on plan cards and the plan page, no proximity |
| S-59 | `Area (optional)` | beacons/presentation/widgets/plan_form_fields.dart:505 | Plan create and edit form section title |
| S-60 | `Choose an area` | plan_form_fields.dart:506 | Field placeholder with no area (:564) |
| S-61 | `Clear area` | plan_form_fields.dart:507, :581 | Clear button tooltip |
| S-62 | `Pick the area of the meeting point, not where you live. People who choose this area see the plan in Nearby.` (two literals, :509-510) | plan_form_fields.dart:508-510, shown at :589 | Hint under the field |
| S-63 | `Area: $label` | plan_form_fields.dart:549 | Semantics label when set |

### 1.6 Desktop "Happening nearby" hero (`app/lib/features/beacons/presentation/widgets/happening_nearby_card.dart`)

| ID | Verbatim text | File:line | Where shown |
|---|---|---|---|
| S-64 | `$count tonight near ${nearby.areaName}. See plans` | happening_nearby_card.dart:85 | Semantics label of the card (screen readers only) |
| S-65 | `Happening nearby` (rendered uppercase) | happening_nearby_card.dart:119 | Eyebrow text |
| S-66 | `$count tonight.` where `$count` is "N plans", "N+ plans", "1 plan" (phrase from `TonightCount.phrase`, `app/lib/features/beacons/domain/tonight_plans.dart:34-36`) | happening_nearby_card.dart:127-134 | Headline, e.g. "14 plans tonight." |
| S-67 | `Near ${nearby.areaLabel}` | happening_nearby_card.dart:141 | Sub-line, e.g. "Near Indiranagar, Bengaluru" |
| S-68 | `See plans` | happening_nearby_card.dart:148 | Call to action |

Rows S-01 to S-68 cover sections 1.1 to 1.6 (68 rows; the `$count` phrase forms are in S-66 and S-50).

### 1.7 Adjacent strings (not the Location feature; listed so counsel does not conflate them)

| ID | Verbatim text | File:line | Note |
|---|---|---|---|
| A-01 | `Reach people nearby with plans they'll actually want to join.` | app/lib/features/advertise/presentation/advertise_screen.dart:89-90 | Advertise page, accent "coming" |
| A-02 | `Share what you want to do. Someone nearby wants that too.` | app/lib/features/auth/presentation/welcome_screen.dart:84 | Welcome; "nearby" is a social phrase, not the Location feature |
| A-03 | `Less scrolling. More connecting. Share what you want to do, and someone nearby wants that too.` | app/lib/features/auth/presentation/widgets/auth_page_layout.dart:45-46 | Auth layout hero |
| A-04 | `A friendly photo helps people nearby say hello.` | app/lib/features/onboarding/presentation/profile_photo_step_screen.dart:159 | Onboarding |
| A-05 | `Location` (profile free-text field label) | app/lib/features/profile/presentation/edit_profile_screen.dart:313, :355 | User-typed profile location (also profile_header.dart:434). NOT the Location feature: no area catalogue, no consent. |
| A-06 | `Pick a date` / `Pick a time` / `Open spots` | plan_form_fields.dart:176, 183, 402 | Not location; listed only because they sit in the same file |


## 2. Data map

### 2.1 What is stored, where

| # | Store (collection, field) | Fields and values | Written by (file:line) | Deleted or changed by | TTL |
|---|---|---|---|---|---|
| D-1 | `users/{uid}/locationArea/current` (document id `current`) | `areaId`, `purposes` (`["plans_nearby"]`), `consentCopyVersion`, `adultConfirmedAt`, `consentedAt`, `updatedAt` | SetArea grant: B:internal/location/repo_firestore.go:251-259. Area change under current consent: updates `areaId` and `updatedAt` only (:261-267) | ClearArea deletes it (:285); erasure deletes it (B:internal/location/purge.go:33-38) | None. B:internal/location/model.go:18 ("No TTL"); proto/dzeroth/location/v1/location.proto:7-8 |
| D-2 | `users/{uid}/locationConsents/{snowflake}` (append-only) | `purpose` (`plans_nearby`), `action` (`granted` or `withdrawn`), `copyVersion`, `adultConfirmed`, `at` (server time) | Grant: repo_firestore.go:256-258. Withdrawal: :285-287 | Never edited. Erasure pages it out (purge.go:41-61, 400 per batch) | None. location.proto:7-8; B:internal/apiserver/lifecycle_collections_guard_test.go:203-204 |
| D-3 | `idempotency/{sha256(uid|rpc|key)}` (shared module, not location-specific) | `uid`, `rpc` (`SetArea` or `ClearArea`), `requestHash` (hash of a string that includes the area id, B:internal/location/service.go:170-172), `result.op`, `expireAt` | repo_firestore.go:213-215; B:pkg/platform/idempotency/idempotency.go:25-39 | Not deleted by the location step. No explicit uid-keyed erasure was found for this collection (not verified in identity lifecycle) | 24 h (idempotency.go:27-28); the TTL policy is in the module default map (infra/terraform/modules/firestore/variables.tf, `idempotency_expire_at`). Whether it is applied in each project: not verified |
| D-4 | `beacons/{beaconId}` plan area fields `areaId`, `cityId`, `nearAreaIds` (the area and its curated neighbours) | Organiser-chosen catalogue area of the meeting point. Not a person's location (B:internal/beacons/area.go:1-4) | Create/update of a plan (beacons/repo_firestore.go:65-69, 91-95; area.go:52-60) | Plan deleted by organiser erasure (B:internal/beacons/purge.go header lines 1-5). `opsctl beacon clear-area` removes the three fields (B:cmd/opsctl/beacon.go:182-186; B:internal/beacons/repo_moderation.go:190) | `beacons_expire_at`: expireAt = startAt + 30 days (infra/terraform/modules/firestore/variables.tf:70-74). The file comment says "Edited only, not applied". Whether applied in dev or prod: not verified |
| D-5 | Plan area in the owner's export | `areaId` on organised plans | B:internal/beacons/export.go:39-40, 88 | n/a | n/a |
| D-6 | Area catalogue (embedded in the binary) | 101 entries: 10 `CITY`, 91 `AREA`; ids like `in.blr`, `in.blr.indiranagar`. Shipped to every client via ListAreas | B:internal/location/areas/areas.json; catalog.go:33-34 | n/a (not personal data) | n/a |
| D-7 | Server request logs | Fixed fields `location_op`, `outcome`, `has_area` (bool). Area ids are redacted from errors | B:internal/location/service.go:201-212; :319-375 (redactAreas) | Platform log retention (privacy.html:~ "Server logs: kept for about 30 days") | Not in the location module |
| D-8 | In-memory only | Per-uid rate limits for the location RPCs (proto/dzeroth/location/v1/location.proto:26-28); per-IP budget in the Connect interceptor keyed on the client IP (B:pkg/platform/ratelimit/interceptor.go:81-95) | n/a | Lost on restart | None |
| D-9 | App memory (client) | `LocationRepository` memoises the settings for the session and drops them on epoch change (A:features/location/data/location_repository.dart:19, :44-47, :55-59). No on-disk storage of the area was found in `app/lib/core/storage/` or `app/lib/core/telemetry/` (grep, empty) | n/a | Session end | n/a |

### 2.2 Consent record contents

- Area doc (D-1): the copy version the user agreed to (`consentCopyVersion`), the time they agreed (`consentedAt`), the 18+ confirmation time (`adultConfirmedAt`, set to the grant time at repo_firestore.go:252-253), the purpose list, the time of the last area change (`updatedAt`). It does not hold the text of the notice.
- Consent log (D-2): one record per grant and per withdrawal. Fields: `purpose`, `action`, `copyVersion`, `adultConfirmed` (the 18+ tick, which the server requires to be true, B:internal/location/service.go:157), and `at`. It holds no area id (B:internal/location/model.go:28-29; lifecycle_collections_guard_test.go:204).
- The "copy version" is a number (1). The text it refers to is not stored anywhere in the data. The only copy is in the app source (location_copy.dart:1-4).
- Changing area under an existing consent appends no record (proto/dzeroth/location/v1/location.proto:44-47; repo_firestore.go:261-267). So there is no area-change history.
- The 10-per-IST-day cap counts consent records (repo_firestore.go:244-249; location.proto:24-25).

### 2.3 Retention and TTL

- D-1 and D-2: no TTL. D-1 lives until ClearArea or account erasure (model.go:18; location.proto:7-9). D-2 lives until account erasure (location.proto:7-9). The default TTL map in infra/terraform/modules/firestore/variables.tf (lines 17-82) has no `locationArea` or `locationConsents` entry.
- D-3: 24 h TTL by design (idempotency.go:27-28).
- D-4: 30 days after the plan starts, if the TTL policy is applied (variables.tf:70-74). Unverified in each project.
- Backups: weekly, kept 14 days (privacy.html:795 and :916-918). Backups are not reached by the erasure step. This is stated in the privacy page, not in the consent copy.

### 2.4 Who can read it

- Clients: Firestore rules deny all reads and writes (firebase/firestore.rules:8-10). The backend uses the Admin SDK (firestore.rules:3-5).
- The user: GetLocationSettings returns the caller's own area and consent state (location.proto:36-37; the header at lines 3-4 says no user's area is returned to anyone but that user). Export section `location` includes the full area and the full consent log (B:internal/location/export.go:85-140).
- Other users: no path found that returns a user's stored area to another user. ListNearbyBeacons returns the caller's own area in its response (B:internal/beacons/convert.go:206; location.proto:3-4 context). The plan area is visible to anyone who can view that plan: B:internal/beacons/convert.go:106-130, app area_label.dart:23-24, beacon_row.dart:71, 264-266.
- Operators: `opsctl beacon clear-area` changes plan areas and prints only a hash (B:cmd/opsctl/beacon.go:182-186, 222). No opsctl command reads a user's stored area was found in backend/cmd (grep for "location" and "area" in backend/cmd/opsctl).
- Project IAM and Firestore console holders: who has them is not in the repo (not verified).
- Google Cloud, as processor: the privacy page lists Cloud Firestore as a processor (privacy.html, "Who we share it with", approximately line 697-712).

### 2.5 Coordinates, IP, device location

- Coordinates: none. No message in `proto/dzeroth/location/v1/location.proto` or `proto/dzeroth/beacons/v1/beacons.proto` has a latitude or longitude field. A grep for `latitude|longitude` in proto, backend/internal and app/lib returned nothing.
- Device location: none. AndroidManifest.xml declares only POST_NOTIFICATIONS and removes the ad-ID permissions (app/android/app/src/main/AndroidManifest.xml:3-9). No location permission or NSLocation* usage key was found in app/android, app/ios, app/macos or app/web (grep). app/pubspec.yaml has no geolocation package (grep for geolocator, location, permission_handler returned nothing).
- The "tonight" count uses the device clock and time zone (A:features/beacons/domain/tonight_plans.dart:10-21). That is time, not location.
- IP addresses: the location module does not write them. The platform logger deliberately logs counts, not IPs (B:pkg/platform/logger/logger.go:125-131). The Connect interceptor resolves the client IP for an in-memory budget (B:pkg/platform/ratelimit/interceptor.go:81-95). Google Cloud logs may include IPs (privacy.html, "Server logs" paragraph, approximately lines 297-303).

### 2.6 Erasure and export

Account deletion:
1. The `location` eraser step runs BeforeIdentity, after daily_stats, the last step (B:internal/apiserver/lifecycle_location.go:16-19, 32-36; the step name is persisted in deletionJob.step, :3-4).
2. Phase 0 deletes the area doc (B:internal/location/purge.go:83-89; DeleteArea at :33-38). A missing doc is success.
3. Phase 1 deletes the consent log in id order, 400 per batch, with a checkpoint (purge.go:18-19, 41-61, 63-71, 94-98). It is idempotent on re-run (purge.go:4).
4. Not flag-gated: documents outlive the flag (purge.go:4; lifecycle_location.go:3-4).
5. Export: the `location` section is written during the export (export.go:1-2, 85-140). The area name and city are resolved from the catalogue.

Plan areas on erasure:
- Organised plans are deleted with their participant docs and areaId, cityId, nearAreaIds (B:internal/beacons/purge.go header lines 1-5; purge.go:33-40 comment). Other users' membership rows pointing at a deleted plan are left to dangle (B:internal/beacons/purge.go:37-40).
- The location step does not touch plan areas on other people's plans.

ClearArea (Settings > Location > Clear my area): deletes D-1 and appends a withdrawn record to D-2 (repo_firestore.go:273-288). It does not change any plan area the user organised. It is not limited by the daily cap (service.go:262-264 comment; location.proto:24-25).

Leftovers after erasure, as the code reads:
- D-3 idempotency docs holding the uid: 24 h TTL, not explicitly removed by the location step (not verified).
- Backups: up to 14 days (privacy.html:916-918).
- Server logs: platform retention, uid hashed (logger.HashUID in purge.go:35, :48 etc.).
- Export files the user requested: 7 days (privacy.html:820-822).
- In-memory caches: cleared on restart.

## 3. Mismatches: copy versus behaviour

Each entry: copy says X (file:line) / code does Y (file:line). Type in brackets.

- **M-01 [omission]**. Copy says "What is stored: the one area you pick ..., the time you agreed and the version of this text." (location_copy.dart:22-25). Code also stores the 18+ confirmation and its time (repo_firestore.go:251-258; D-1 `adultConfirmedAt`; D-2 `adultConfirmed`), a purpose tag (repo_firestore.go:252, 257), and a log of every grant and withdrawal until erasure (repo_firestore.go:256-258, 285-287; location.proto:7-8).
- **M-02 [over-claim / ambiguous]**. Copy says "Dzeroth stores only the area you choose." (location_copy.dart:8-9). The same store also holds the consent log (D-2), uid-keyed idempotency docs for 24 h (D-3), and the plan areas on plans the user organises (D-4). The sentence is accurate only if read as about the user's own area. Counsel should decide whether that reading is clear.
- **M-03 [omission]**. Copy says "Clear my area removes it at once." (location_copy.dart:31-33). ClearArea deletes D-1 but appends a withdrawn record to D-2, which is kept until erasure (repo_firestore.go:285-287). The copy does not say the withdrawal is recorded.
- **M-04 [over-claim, depends on reading]**. Copy says "Who sees it: only you." (location_copy.dart:28-30). Client access is denied (firestore.rules:8-10) and the user's own API reads return only their data (location.proto:3-4). But the same data is in weekly backups kept 14 days (privacy.html:916-918), is readable by the service and by project administrators (not in repo; see section 5), and is processed by Google Cloud (privacy.html, "Who we share it with"). The copy does not mention any of these.
- **M-05 [over-claim]**. Copy says "A plan shows the area its organiser chose for the plan, never where you live." (location_copy.dart:29-30). The server validates only that the plan's area is a non-retired catalogue id (proto/dzeroth/beacons/v1/beacons.proto:415-418; B:internal/beacons/area.go:63-74). Nothing prevents an organiser from choosing the area they live in. The form only advises "not where you live" (plan_form_fields.dart:509-510). "Never" is a guarantee the code does not enforce.
- **M-06 [inconsistency between surfaces]**. Plan form says "People who choose this area see the plan in Nearby." (plan_form_fields.dart:509-510). Only public plans are listed in Nearby; community-audience plans are never listed, even when they have an area (beacons.proto:205 and :415-417 "Allowed for either audience; only public plans are listed by ListNearbyBeacons").
- **M-07 [over-claim, minor]**. Explore empty state says "Plans anyone can join show up here." (explore_nearby_section.dart:124). Nearby lists OPEN and FULL public plans (beacons.proto:200-201), and FULL plans cannot be joined (beacons.proto:62-63, reason "full").
- **M-08 [inconsistency between surfaces]**. The desktop hero says "14 plans tonight." (happening_nearby_card.dart:127-134). It counts on the device from the first page of up to 20 Nearby rows, with a device-clock cutoff at 04:00 (happening_nearby_session.dart:82-90; tonight_plans.dart:10-21, 51-68; "N+" when the page is full, :66-67). The Explore header count is the server's count, with K-anonymity (explore_nearby_section.dart:36-44; beacons.proto:212-213). The two numbers for the same area can differ.
- **M-09 [omission]**. The 18+ tick is labelled "I am 18 or older" (location_copy.dart:34) and is required to continue (location_rationale_screen.dart:324-341). The copy does not say the answer is recorded (repo_firestore.go:251-258), nor that the server treats it as a self-declared gate (location.proto:111-113, "C4 interim self-declared gate"). The privacy page says the app does not check age (privacy.html, "Age requirement", approximately lines 975-981).
- **M-10 [omission]**. The consent copy says nothing about the plan area. A plan's area is stored on the plan (D-4; beacons.proto:6-9), is shown to everyone who can view the plan (beacon_row.dart:71, 264-266; area_label.dart:23-24), appears in public Nearby (beacons.proto:200-205), and lives until the plan is deleted or its TTL runs (variables.tf:70-74). The plan form hint (plan_form_fields.dart:509-510) does not mention visibility to viewers or retention.
- **M-11 [omission]**. The daily cap is not mentioned. A user who changes their choice too often sees "You've changed your location choice too many times today. Try again tomorrow." (location_error_messages.dart:22-23; location.proto:24-25: 10 records per IST day). The copy says "Withdraw any time" (location_copy.dart:31) but a grant can be refused by this cap. Withdrawal is never limited (location.proto:24-25).
- **M-12 [ambiguity]**. "Clear my area removes it at once" (location_copy.dart:31-33) does not say that plan areas the user organised are not changed by clearing them (repo_firestore.go:285; beacons.proto:447-451 changes a plan's area only through UpdateBeacon). A user may think "it" covers all location data.
- **M-13 [omission on the privacy page]**. The privacy page has no Location section. Its data list (privacy.html ~190-215), retention list (~772-800), export list (~806-812) and deletion list (~818-835) do not mention the area, the consent log or the plan area, although erasure and export do (purge.go; export.go; lifecycle_location.go:21-28). See section 4.
- **M-14 [inconsistency between surfaces]**. Settings row subtitle and Explore settings show the area label (settings_screen.dart:1081; explore_settings_screen.dart:46), but the Explore gear tooltip is just "Settings" (explore_screen.dart:154), and that gear opens Explore settings (explore_screen.dart:155-157), while the Settings screen's own Location row is elsewhere. Label ambiguity; not a data point.

Consistent (checked, no mismatch found):
- "It never reads your phone's location" (location_copy.dart:8-9): no location permission in Android or iOS (AndroidManifest.xml:3-9; Info.plist has no location key; pubspec has no geolocation package). Privacy page says the same (privacy.html ~line 206, "the app doesn't use your device's location").
- "No coordinates" (location_copy.dart:24-25): no coordinate field in either proto.
- "Notice version" and the copy-version rule: the server minimum and current copy version are both 1 (location.proto:118-119, 131-132; config/location.go:12-16); the app sends the server's current version (location_settings_cubit.dart:286-296).
- "Settings > Location > Clear my area removes it at once" (location_copy.dart:31-33): one tap, no confirmation (location_settings_screen.dart:25-26; cubit clear() at location_settings_cubit.dart:320-341).
- "Why: so plans in or near your area can be shown to you" (location_copy.dart:26-27): Nearby uses the stored area with neighbours in AREA scope (beacons.proto:202, 302-310).
- "Who sees it: only you" for the server's responses: ListNearby returns the caller's area only to the caller (location.proto:3-4; convert.go:206).
- "Search runs on the device" (location.proto:89): the picker filters the catalogue locally (A:features/location/domain/area_search.dart).
- Logs contain no area id (service.go:201-212; redactAreas at :319-375).
- The privacy page's "Duplicate-request records ... 24 hours" matches D-3.
- "You agreed on <date>" (location_settings_screen.dart:234) uses area-doc `consentedAt` (settings() at service.go:177-195), which is not changed by an area change (repo_firestore.go:261-267).

## 4. Privacy page

File: app/web/privacy.html (served at `/privacy.html`, app/lib/core/widgets/privacy_policy_link.dart:10, :16-19). Draft marker in the head comment, "last updated 2026-11-01" (privacy.html:2, 168). The maintainer note says: "Deploy this policy before any real user is allowlisted on any flag" (privacy.html:24), and item 11 says TTL policies that a retention sentence relies on must be applied before a feature leaves off in prod (privacy.html:36-38).

Location coverage:
- **Location section: none.** Grep for "location" returns only the user-typed profile location (privacy.html:205-206) and photo EXIF location (:247). Grep for "area", "Nearby", "neighbourhood", "consent", "chosen" returns nothing relevant.
- **Plans / beacons section: none.** Grep for "plan", "beacon", "meeting" returns nothing. The plan area and plan data are not described at all.

What a Location section would need to cover, given the data map (facts, not advice):
- What is stored: the chosen area (D-1), the consent log with 18+ flag and timestamps (D-2), idempotency docs (D-3), the plan area on plans (D-4).
- Where: Firestore (Mumbai for the database, privacy.html ~754-770); backups (14 days).
- Retention: no TTL for D-1 and D-2; D-4 TTL if applied; D-3 24 h; backups 14 days.
- Who sees it: the user, through the app and export; not other users, except the plan area on plans they can view and the public Nearby listing of plans.
- Purpose: see public plans in your area (location.proto:70-71).
- Rights: withdrawal (ClearArea, location.proto:49-51), export (export.go), erasure (purge.go).
- Current omissions in the existing text: area and consent-log retention and export are not in "Your rights" (privacy.html:799-830); the deletion list (~818-835) omits the location area and consent log; the export list (~806-812) omits the location section; the retention list (~772-800) has no area line.

## 5. Open questions for counsel

1. Should the 18+ tick be disclosed as stored (D-1 `adultConfirmedAt`, D-2 `adultConfirmed`) and as a self-declaration? The privacy page says the app does not check age (privacy.html ~975-981).
2. Should the consent log (every grant and withdrawal, no TTL, kept until erasure) be described in the consent copy and in the privacy page? Is no-TTL retention acceptable for it?
3. Is "Who sees it: only you" to be qualified for processors (Google Cloud), people with project administrator access, and 14-day backups?
4. Should the consent copy describe the plan area (visible to all viewers of the plan, listed in public Nearby, retained with the plan and its TTL) since it is a second disclosure of place data by a different actor?
5. The server does not stop an organiser from choosing their home area as a plan area (M-05). Is the "never where you live" line acceptable as written, or should it be reworded?
6. Is the copy version (a number) enough evidence of the text shown, given the text is not stored with the record? Should the text be archived per version?
7. Should the privacy policy have a Location section (and a plans section) before the location flag is enabled for any real user, per the maintainer note (privacy.html:24)? Which flag state applies to production is not in the repo.
8. Does the export (location section, export.go:85-140) meet the expected content for an access request, including the catalogue name and city?
9. Should backups (14 days) be described next to erasure, since erasure does not reach them (privacy.html:916-918)?
10. The lifecycle guard says "ADR pending" for locationArea (B:internal/apiserver/lifecycle_collections_guard_test.go:207). Which governing record (ADR or design note "location design 2026-11-15", referenced in B:internal/location/*.go comments) is the reference, and is it accepted? Neither file is in the repo.
11. Happening nearby (desktop) reads the stored area on Home, Drafts, Plans and My Plans without a tap (happening_nearby_session.dart:79-96; happening_nearby_card.dart:55-63, 24-32). Is that within the single purpose in the consent (`plans_nearby`, location.proto:70-71)?
12. The area catalogue covers 10 cities and 91 neighbourhoods, all with `in.` ids (areas.json). Does the copy need to state the geographic scope?

## 6. Could not verify

- Whether the TTL policies for idempotency (D-3) and beacons (D-4) are applied in dev or prod. variables.tf says "Edited only, not applied" for beacons (:70-77). The environment files were not read for ttl overrides (the envs pass no ttl_fields).
- Whether DeleteAccount removes uid-keyed idempotency docs (D-3). Not traced.
- Who holds Firestore or project IAM in dev or prod.
- The live strings: this review reads source only. Strings built by the server (rateLimitedMessage in shared/format, and any server text) were not reviewed.
- The location design note "2026-11-15" and any location ADR: referenced in comments (B:internal/location/*.go, lifecycle_collections_guard_test.go:202), not in the repo.
- Prod feature flag state and the allowlist. Not in the repo.
- Store listings (Play data-safety, App Store privacy labels): not in the repo.
- The working tree: at session start `git status` showed two modified Terraform files (infra/terraform/envs/dev/main.tf, prod/main.tf); at the time of reading the tree was clean and HEAD had moved to cf2f99aa. Line numbers reflect the tree as read.
