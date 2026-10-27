# Runbook: profile fields and the pinned post (identity)

Owner module: `backend/internal/identity` (ADR-0024 D1-D3, D9, D11; ticket W3-6). Data: `users/{uid}` fields `bannerUrl`,
`bannerThumbUrl`, `location`, `website`, `pinnedPostId` (all absent = none, no backfill, index-exempt, not in the author
snapshot). Set only by `UpdateProfile`; `pinnedPostId` is also cleared by the `post_delete` job, and an operator can clear the
website, location, banner, avatar and bio of one account with `opsctl clear-profile-fields` (`docs/runbooks/abuse-spike.md`
section 5b). Gate: `FEATURE_PROFILE_EXTRAS` (`profile_extras`), on setting a value, never on clearing one.
Account deletion and export are `docs/runbooks/account-deletion.md`; the banner upload is
`docs/runbooks/media.md` ("Banners"); the posts side of the pin check is `docs/runbooks/posts.md` section 13.

Git Bash on Windows; queries are for **Logs Explorer**
(`resource.type="cloud_run_revision" AND resource.labels.service_name="api"`). Env changes on prod use the pinned-traffic procedure in
`docs/runbooks/cost-spike.md`.

## 1. What a client sees from `UpdateProfile`, and what to check

Setting `banner_media_id`, `location`, `website` or `pinned_post_id` needs `profile_extras` on for the caller. The exact empty
string `""` (a clear) never does: it is accepted from any authenticated caller whatever the flag, a globally off flag included,
at the same 1 read and 1 write as a bio edit (ADR-0024 Amendment 1 A2; a DPDP or GDPR rectification or erasure request must
not wait for a flag). A value that is not exactly `""` is a set, whitespace-only included, so `"   "` is gated even though it
would normalise to a clear; a request from outside the cohort that mixes a clear with a set is refused whole.
`DEGRADED_MODE=readonly` still refuses every write, clears included. The name, bio and avatar path is not gated.

| Client sees | Meaning | Check |
|---|---|---|
| FAILED_PRECONDITION `FEATURE_DISABLED`, metadata `feature=profile_extras` | The caller is outside the flag's cohort (or the flag is off) and the request sets at least one of the four fields (a clear next to a set counts). 0 reads and 0 writes; the check runs before any validation. A request that only clears is never refused for this. | `GetMe.enabled_features` for that uid; the `FEATURE_PROFILE_EXTRAS*` env vars of the serving revision. Request line has `feature_disabled=true`. |
| FAILED_PRECONDITION `MEDIA_NOT_READY` | The banner id is not a READY (or READY_UNSCREENED) BANNER owned by the caller, or `FEATURE_MEDIA` is off for the caller. One answer for every cause. | The `media/{id}` doc: `ownerId`, `purpose=BANNER`, `status`. A REJECTED banner is a Vision decision (`docs/runbooks/media.md`). |
| INVALID_ARGUMENT `VALIDATION` `field=location` | More than 30 code points after trim and NFC, invalid UTF-8, a control character (a newline included), a line or paragraph separator (U+2028, U+2029) or a bidi formatting control (U+202A-U+202E, U+2066-U+2069). | Nothing to fix server side; the client counts code points, not UTF-16 units. The rules are the vectors in `testdata/profile_text/location.json`. |
| INVALID_ARGUMENT `VALIDATION` `field=website` | Anything the client could not show and open (W3-22 L-2b, L-3): not an absolute `http`/`https` URL, over 100 code points, whitespace (U+FEFF included), a control, or U+061C, U+200E, U+200F or a bidi formatting control anywhere; userinfo (`@`) or an IPv6 literal (`[`) in the authority; a port that is not 1-65535 in ASCII digits; a host label that is empty, over 63 bytes (non-ASCII labels counted as punycode) or outside `[a-z0-9_-]` (so `%` and `\` in the host); and the host class: fewer than two labels, a last label that is not TLD-shaped (`[a-z]{2,63}` or `xn--...`, which also refuses every IPv4 form), `localhost`, `local`, `internal`, `home.arpa` or a subdomain of one. | As above. The rules are `testdata/profile_text/website.json` (README.md there lists them). The server never fetches the URL. A website saved before W3-22 is returned as stored; it is checked again only when the user submits it. |
| INVALID_ARGUMENT `VALIDATION` `field=display_name` or `field=bio` | Invalid UTF-8; display name outside 1-50 or bio over 160 code points after trim and NFC; a control character (a bio keeps `\n`, so a CR is refused), a line or paragraph separator, or a bidi formatting control (W3-22 L-2c). The message still says "must be 1-50 characters" / "at most 160 characters" whatever the cause. | Applies to new writes only: a stored name or bio is never re-validated on read, and the bio is stored in NFC. `testdata/profile_text/{display_name,bio}.json`. |
| INVALID_ARGUMENT `VALIDATION` `field=pinned_post_id` | The post is not the caller's own, visible POST, QUOTE or REPLY. The same message for a malformed id, an unknown or deleted post, another user's post, a hidden post and a REPOST, so it is no existence oracle. | The request line says `pin_check=rejected` and never the cause. To diagnose one report, read `posts/{id}` by hand: `authorId`, `kind`, `moderation`. |
| 500 (INTERNAL) on a pin | The pin checker failed to read the post (a Firestore error), which is not a verdict. | The error line says `pin check` (uids are redacted); Firestore status in Cloud Monitoring. |
| RESOURCE_EXHAUSTED `RATE_LIMITED`, metadata `limit=profile_update_daily` | The account made `PROFILE_UPDATES_PER_DAY` (default 100) `UpdateProfile` calls on this instance since IST midnight (W3-22 L-4); every call counts, including one that changes nothing. `retry_after` is the time to IST midnight. A person editing a profile never gets near it. | Logs Explorer: `jsonPayload.limit_name="profile_update_daily"`. One uid is a script or a client save loop; many uids means a client bug that saves on every change. The cap is per instance, so the account-wide ceiling is 100 x running instances (300 at max-instances 3). Raise it only with a cost note: each unit is at most 1 write and 4 reads. |

Request log lines of `UpdateProfile` carry `profile_fields_changed` (field names only, for example `banner,location,pinned_post`; a
value that did not change is not listed) and, for a non-empty `pinned_post_id`, `pin_check=ok|rejected`. They never carry a value.

Cost: `UpdateProfile` is 1 read and 1 write for the transaction (0 writes when the request changes nothing: the same values again, an empty request, or clearing a field that is already empty; `updatedAt` is then left alone and the request line has no `profile_fields_changed`), +1 read for a banner (the media doc), +1 for a pin (the post;
0 when warm), +1 for the interceptor when its profile cache is cold. Worst 3 reads / 1 write in the service (4 / 1 cold).
`fs_reads` above that on this RPC is a regression. `fs_writes` above 1 is too. Before W3-22 L-4 the document was rewritten on every call and there was only the 60/min bucket, so one script could cost about 6,000 writes and 6,000 reads a day (about INR 24 a month per account); `profile_update_daily` now stops it at 100 calls a day per instance. None of the new fields bumps `snapshotVersion`, spends `snapshotEdits` or
enqueues a snapshot job; if `profile_snapshot` job volume rises with banner or pin edits, that is a bug.

## 2. Kill switch: hide every website and pin

`FEATURE_PROFILE_EXTRAS=off` (mode off, not allowlist or percent 0) and deploy. From the next revision `Profile.website` and
`Profile.pinned_post_id` are empty in every response (GetMe, GetProfile, UpdateProfile, ChangeHandle, CreateProfile), the
owner's own view included, so a phishing link stops rendering and opening and clients stop their `GetPost` call for the
pinned row (ADR-0024 Amendment 1 A1). Banner and location keep showing: the banner is screened by SafeSearch and handled per
account, and the location is plain text with no link, the same class as the bio. Nothing stored is erased (the document, the
instance cache and the data export still hold the website and the pin): turning the flag back on (any mode other than off)
shows both again with no write. The profile cache holds the stored value, so the change is immediate on each revision. An
allowlist or percent rollout is not the kill switch: the pin and website of an allowlisted user stay visible to everyone.

While the switch is pulled the owner does not see their own website or pin either, so the app cannot offer Remove for them;
it offers Remove for the banner and location, which still show. Anyone can still clear all four through `UpdateProfile` with
an empty value (for example from an older client or by hand), and the operator can clear a field for one account with
`opsctl clear-profile-fields` on request (`docs/runbooks/abuse-spike.md` section 5b). The switch is an emergency state
measured in hours or days, which is why there is no owner-view exception.

## 3. A deleted post is still pinned

`DeletePost` publishes one `post_delete` message; the job has three handlers on it (media, engagement, identity pin step). The
identity step (`PinJobs`) reads the post fresh (a message for a live post is `refused`), then clears `users/{uid}.pinnedPostId`
in a transaction only when it equals that post, so a newer pin is never touched and a purged `users` document is never
recreated. It is never flag-gated, so it runs while `profile_extras` is off. A takedown does not clear the pin (a restore brings
it back); the client hides a pin whose `GetPost` answers NOT_FOUND.

- If the `post_delete` publish itself failed (`post_delete_job_publish_failed` in Error Reporting), re-publish the message by hand as
  in `docs/runbooks/engagement.md`; the same message re-runs all three steps, the pin step included.
- Another instance's profile cache can keep showing the pin for at most `CACHE_TTL` (60 s) after the job ran; the instance that
  ran it forgets the uid at once.
- The pin is still there after minutes: look for the delivery line `jsonPayload.account_job="post_delete"` and its `outcome`:
  `pin_cleared` appears in the outcome when the pin was cleared; `refused` repeated by every step means the post still existed when
  the job ran (the message was acknowledged, not retried). A `post_delete` message stuck in the DLQ is handled as in
  `docs/runbooks/account-deletion.md`.
- Manual fix, one account: in the Firestore console set `users/{uid}.pinnedPostId` to an empty string (or delete the field) and change
  nothing else. A stale pin to a gone post is harmless to others: clients hide it when `GetPost` answers NOT_FOUND.
- Cost: 2 reads per deleted post (the existence check and the transaction) and 1 write only when the pin is cleared, on the system
  budget, not charged to the user.

## 4. Export and deletion

The export's `profile` section carries `bannerUrl`, `location`, `website` and `pinnedPostId` when set (never the thumbnail, which
is derived data). Deletion needs no step of its own: `users/{uid}` goes last, and the banner's media doc and objects go with the
`media` step like every other image.
