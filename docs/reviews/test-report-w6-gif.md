# Test report: UI wave W6, GIF backend (W6-18)

Plan: `docs/plans/ui-w6-composer-extras.md` (W6-18; W6-9 and W6-10 acceptance criteria). Design: ADR-0029 D10, D11, D12, F10, F11.
Runbook: `docs/runbooks/media.md`, section "GIFs".

## W6-18: backend tests for the GIF path (2026-10-31)

Tester: tester agent. Branch `test/ui-w6-18-gif-tests` on `main@bccffed4` (W6-9 #496 and W6-10 #505 merged).

**VERDICT: PASS for W6-18 as specified**, with one Medium defect filed (D-1, section 5) as a test that pins today's behaviour and, with
`W618_RUN_DEFECTS=1`, asserts the expected one. Every acceptance criterion of W6-9 and W6-10 has a named test (section 3). The W6-9 and W6-10
developers had already covered most of the matrix; the audit found these gaps and added tests for them: explicit-frame position matrix and
the delay model, end-to-end memory of bombs and of the accepted worst case, slot release and photo independence, the Vision cap boundary
(one unit left), a Vision failure, purge and post_delete and export of GIF objects, the publish swap (documented residual), the
whole-request chain for FinalizeUpload of a GIF, the sweep of a GIF draft, the percent mode and the flag-off cost. No production code was edited.

---

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| Media package, unit, with the new tests | `GOWORK=off go test ./internal/media` | **green** |
| Media package, unit + integration | `go test -tags=integration ./internal/media` against the emulators | **green** (one run hit `context deadline exceeded` in the existing `TestW320Banner_RacyRuleAndUnitsOnTheRealRepo` while two suites shared the machine; the rerun was green; not a GIF test) |
| Posts, GIF tests | `go test -tags=integration ./internal/posts -run GIF` | green (`TestGIF_Integration_CreatePostGates`, `TestScheduled_Integration_GIFRefused`, new `TestSweepIT_GIFDraftIsUnavailableNotPublished`) |
| Apiserver chain, GIF tests | `go test -tags=integration -timeout 40m ./internal/apiserver -run GIF` | green (three chain tests, one existing, two new) |
| Defect reproduction | `W618_RUN_DEFECTS=1 go test ./internal/media -run KnownGap` | **fails as intended** (D-1) |
| gofmt, `go vet -tags integration`, `golangci-lint run --build-tags integration` | on `./internal/media/...`, `./internal/posts/...`, `./internal/apiserver/...` | gofmt and vet clean. golangci-lint reports 0 issues in the new files (two findings in my first draft were fixed); it still reports 10 findings in other, existing files of the three packages (`poll_integration_test.go`, `has_media_integration_test.go`, `removals*_integration_test.go`, `search_chain_integration_test.go`), none from this PR |
| Coverage of the GIF files (media unit tests only) | `go test -cover` on `gifscan.go`, `gifscreen.go` | `scanGIF` 90.3 %, `sampleGIF` 97.6 %, `sampleIndices` 100 %, `gifSheet` 100 %, `screenGIF` 100 %, `acquireGif` 87.5 %, `drawPaletted` 68.4 % (an unreachable-by-fixture branch of the palette copy) |

Environment notes:
- **`-race` was not run**: CGO is off on this Windows machine. The Makefile turns `-race` on where CGO is available (`RACE_FLAG`), so the Linux CI
  job that runs `make test-int` / `make ci` covers it. The new memory assertions use `TotalAlloc` (race detector overhead is shadow memory,
  not counted) with generous bounds; the new tests share no mutable state across goroutines except through the existing locked fakes
  (`gateObjects`, the fake object store's mutex, atomics). The fixtures' wall time under `-race` is the one thing to watch in CI: see observation 3.
- Emulators ran from an untracked scratch config on ports 58xxx (Pub/Sub moved twice because the port was taken) behind
  `scripts/with-private-tmp.sh`, started with `emulators:exec`. The config is outside the repo.
- Nothing was run against dev or prod.

### 2. What was added

| File | Tests | Covers |
|---|---|---|
| `backend/internal/media/gif_w618_test.go` | `TestW618_ExplicitFrameVerdictMatrix` (14 cases), `TestW618_KnownGap_BrowserDelayClampIsNotModelled` (D-1), `TestW618_BombsFinalizeAllocatesLittle` (5 bombs), `TestW618_AcceptedWorstCaseStaysInsideTheMemoryBudget` (2), `TestW618_SlotIsReleasedAfterARefusalAndDoesNotBlockPhotos`, `TestW618_VisionCapBoundary` (2), `TestW618_VisionFailureSpendsNothingAndKeepsTheGIFRetryable`, `TestW618_PurgeAndPostDeleteRemoveGIFObjects` (3), `TestW618_KnownResidual_PublishSwapAfterScreening`, `TestW618_RequestHashGolden`, `TestW618_PercentModeIsPerUserAndTheSameForMediaAndPosts`, `TestW618_CreateUploadFlagOffIsRefusedBeforeAnyRead`, `TestW618_FinalizeIgnoresTheGifFlag`, `TestW618_ExportCoversAGIF` | section 3 |
| `backend/internal/posts/gif_sweep_integration_test.go` | `TestSweepIT_GIFDraftIsUnavailableNotPublished` | `repo_publish_scheduled.go:231`: a draft that holds a GIF ends FAILED MEDIA_UNAVAILABLE, no post, nothing attached, no quota charge; the photo draft beside it publishes |
| `backend/internal/apiserver/gif_finalize_chain_integration_test.go` | `TestGIFChain_FinalizePostScheduleAndDelete`, `TestGIFChain_CreateUploadGatesOverTheWire` (flag off, 7 shape refusals, nomedia) | `apiserver.Build` + the Storage emulator: FinalizeUpload of a real GIF, published bytes and types, Vision units, cost against a photo, CreatePost, GIF + photo, SchedulePost, DeletePost + post_delete |

Reused (not rewritten): `encodeTestGIF`, `rawGIF`, `redIsExplicit`, `gateObjects`, `env`, `fakeObjects` (media package); `newLifecycleEnvCfg`,
`costOf`, `wireError`, `pull`, `deliver`, `mediaOn` (apiserver chain); `newSweepIT` (posts).

#### Why the chain test does not start at CreateUpload

A V4 signed PUT URL cannot be minted against the emulators (no signing credentials; `objstore.SignedPutURL` needs IAM `signBlob`). The chain
test therefore makes the PENDING document with a `media.Service` over the same Firestore and a stub signer, writes the client's two PUTs into the
emulator's upload bucket with the Storage client, and drives everything after that through the wired chain (`FinalizeUpload`, `CreatePost`,
`SchedulePost`, `DeletePost`, the `post_delete` delivery). The wired `CreateUpload` is tested for every refusal that happens before signing
(flag, shape, nomedia). The signing path stays covered by the objstore unit test and the dev smoke. Local `Build` uses `media.AllowAll` as the
Moderator, so verdict cases (explicit later frame) are in the media unit tests and the chain asserts the Vision counter.

### 3. Traceability

Paths: `media/` = `backend/internal/media/`, `posts/` = `backend/internal/posts/`, `api/` = `backend/internal/apiserver/`. "new" marks a test
added by W6-18; the others are the developers' (W6-9 `gif_test.go`, W6-10 `gifscreen_test.go`). "chain" means through `apiserver.Build`.

#### W6-9: accept `image/gif` for post media

| Criterion | Test(s) |
|---|---|
| A 1.5 MiB GIF with a JPEG thumbnail is READY with `url` ending `.gif` | `media/gif_test.go:TestGIF_FinalizeHappyPath` (jpg and webp thumbnail), `TestGIF_FinalizeAccepts87a`; chain: `api/gif_finalize_chain_integration_test.go:TestGIFChain_FinalizePostScheduleAndDelete` (new, real Storage emulator, bytes unchanged, content types `image/gif` and `image/jpeg`, private pair deleted) |
| A GIF declared but PNG bytes is REJECTED | `media/gif_test.go:TestGIF_FinalizeRejections` (png bytes, stored type jpeg, thumbnail typed gif, thumbnail bytes gif, oversize) |
| A 2.1 MiB GIF is VALIDATION at CreateUpload | `media/gif_test.go:TestGIF_CreateUploadMatrix/oversize_gif`, `oversize_gif_thumbnail` |
| An avatar GIF is VALIDATION | `TestGIF_CreateUploadMatrix/avatar_gif`, `banner_gif`; `TestGIF_ServerFlagModes` (avatar after the flag); chain: `TestGIFChain_CreateUploadGatesOverTheWire/flag_on:_shape_rules/avatar_gif` and `banner_gif` (new) |
| A GIF plus a photo in one post is VALIDATION | upload side: `TestGIF_CreateUploadMatrix/gif_plus_a_photo`, `photo_plus_a_gif`, `two_gifs`, chain `.../gif_and_photo`, `.../two_gifs` (new); post side: `posts/gif_gate_test.go:TestCreate_GifSentinelsMapToTheDocumentedErrors`, `posts/gif_integration_test.go:TestGIF_Integration_CreatePostGates/gif_next_to_a_photo` (VALIDATION `media_ids`, 0 writes), chain `TestGIFChain_FinalizePostScheduleAndDelete` (new: VALIDATION `media_ids`, 0 writes) |
| `gif` off gives FEATURE_DISABLED with 0 reads | CreateUpload: `media/gif_test.go:TestGIF_ServerFlagModes` (off, allowlist, percent 0/100, on, and the checker that does not know gif), new `TestW618_CreateUploadFlagOffIsRefusedBeforeAnyRead` (a GIF and a GIF + photo: nothing read, signed or written), new `TestW618_PercentModeIsPerUserAndTheSameForMediaAndPosts` (50 %, 40 uids, both sides populated), chain `TestGIFChain_CreateUploadGatesOverTheWire/flag_off` (new: **0 reads, 0 writes** on the wire). CreatePost: `posts/gif_integration_test.go:TestGIF_Integration_CreatePostGates/gif_off` (FEATURE_DISABLED `feature=gif`, 0 writes), chain `api/gif_chain_integration_test.go:TestGIFChain_CreatePostGateWireAndDelete`. **Wording note: at CreatePost the refusal comes after the media read** (the content type is only known from the claim), so it is "0 writes", not "0 reads". The criterion's "0 reads" holds at CreateUpload only. This is what the runbook and `posts/api.go:349` say; the ticket text is the looser one |
| `DEGRADED_MODE=nomedia` is refused as today | chain: `api/media_chain_integration_test.go` (CreateUpload, FinalizeUpload), new `TestGIFChain_CreateUploadGatesOverTheWire/nomedia_blocks_a_GIF_CreateUpload`. `CreatePost` of an already READY GIF is not blocked by nomedia, the same as a photo (the mode blocks the two media procedures only, `media_wiring.go:mediaProcedures`) |
| The sniffer table, the content-type matrix | `media/gif_test.go:TestGIF_SniffTable` (GIF87a, GIF89a, 6 bytes, 5 bytes, lower case, GIF88a, png, jpeg, webp, empty), `TestGIF_CreateUploadMatrix` (20 cases) |
| Publish copies the full object as `image/gif` and the thumbnail with its own type | `TestGIF_FinalizeHappyPath`; chain (new) reads both public objects' content types from the Storage emulator |
| posts: CreatePost refuses a GIF while `gif` is off; a GIF must be alone; SchedulePost refuses a GIF (F10) | `posts/gif_gate_test.go` (4 tests), `posts/gif_integration_test.go`, `posts/scheduled_integration_test.go:TestScheduled_Integration_GIFRefused` (2 + 1 reads, 0 writes, no schedule charged), chain `TestGIFChain_FinalizePostScheduleAndDelete` (new: SchedulePost with the GIF is VALIDATION `media_ids`), new `posts/gif_sweep_integration_test.go:TestSweepIT_GIFDraftIsUnavailableNotPublished` (the sweep side of F10) |
| The purge and export of media cover the `gif` extension | new `TestW618_PurgeAndPostDeleteRemoveGIFObjects` (published, pending and rejected GIFs with a jpeg and a webp thumbnail, an unrecorded suffixed public name, Bob's GIF kept, never a `_t.gif` delete; post_delete on a GIF), `TestGIF_CleanupNamesUseTheThumbnailsOwnExtension`; export: new `TestW618_ExportCoversAGIF`; chain (new) `post_delete` removes both public objects and the document |
| Observability: media lines gain `content_type` | not asserted by W6-18 (log field; `docs/runbooks/media.md` "Logs"); `gif_screen` fields are asserted indirectly by the developers' log tests |
| Budget: Firestore unchanged (CreateUpload 2 / 1, FinalizeUpload 5 / 1.7) | chain (new): the GIF FinalizeUpload wrote the **same number of documents as a photo's** and read no more (`[1 3]` against the photo's `[2 3]`; the photo ran first and loaded the Vision counter into the instance cache), CreatePost with a GIF 5 writes and reads <= 5 (the photo budget) |
| The request hash is unchanged for photos | `media/gif_test.go:TestGIF_RequestHashUnchangedForPhotos`; new `TestW618_RequestHashGolden` (a literal pre-W6 string, an equal thumb type hashes like none, a GIF never hashes like a photo) |
| Cleanup names (`_t.jpg`, never `_t.gif`) | `TestGIF_CleanupNamesUseTheThumbnailsOwnExtension`, new purge/post_delete test above (asserts on every recorded delete) |

#### W6-10: frame-sampled SafeSearch for GIFs

| Criterion | Test(s) |
|---|---|
| The 3rd of 4 sampled frames is explicit and the first harmless: REJECTED | `media/gifscreen_test.go:TestGIFScreen_ThirdSampledFrameExplicitIsRejected` (sheet cell 3 is the red one); new `TestW618_ExplicitFrameVerdictMatrix`: explicit as the 1st, 2nd, 3rd and 4th sample, as the 2nd of 2, 3rd of 3 and 4th of 4 frames, and one long explicit frame at the end, all REJECTED with reason `policy`, 2 units spent, no objects left |
| An explicit frame between the samples: the accepted F11 residual | `TestGIFScreen_FrameBetweenTheSamplesIsNotScreened`; new matrix cases `RESIDUAL F11` (frames 1, 3, 5 and the last frame of 8, and a short explicit tail behind a long harmless first frame), pinned as READY |
| A header claiming 10,000 frames or a 65,535 x 65,535 screen is REJECTED before any decode, memory under 20 MB | `media/gifscreen_test.go:TestGIFScreen_BombsAreRefusedBeforeAnyDecode` (pre-scan allocation < 20 MB, 0 Vision calls, 0 units, objects deleted; 10,000 frames, 65,535 screen, area sum), `TestScanGIF_Refusals` (17 shapes), `FuzzScanGIF`; new `TestW618_BombsFinalizeAllocatesLittle`: the **whole finalize** of 10,000 frames, 65,535 x 65,535, 1,281 x 1,281, 40 full screens (area) and 301 frames allocates < 16 MiB, 0 Vision calls, REJECTED "too large" |
| Two GIFs finalized at once on one instance run one after another and both finish | `TestGIFScreen_TwoGIFsRunOneAfterAnotherAndBothFinish` (max concurrency 1); `TestGIFScreen_BusySlotAnswersMediaNotReadyWithoutSpend` (retryable MEDIA_NOT_READY, 0 Vision, claim released, the reservation returned, the retry succeeds); new `TestW618_SlotIsReleasedAfterARefusalAndDoesNotBlockPhotos` (a refusal inside the slot frees it; a photo finalize completes while a GIF holds the slot) |
| At the Vision cap the policy applies | the ticket text says "exactly as for photos"; **ADR-0029 F11 point 4 and the runbook say REJECTED for every account**, and the code does that. `media/gif_test.go:TestGIF_AtTheVisionCapIsRejectedForEveryAccount` (established and new accounts, both policies, a photo at the cap stays READY_UNSCREENED); new `TestW618_VisionCapBoundary` (9 of 10 used: a GIF is REJECTED `capacity`, the counter stays 9, no partial reservation, the account's photo still takes the last unit; 8 of 10: READY and the counter lands on 10) |
| A READY GIF counted 2 units | `TestGIF_FinalizeHappyPath` (1 sheet by bytes, 1 thumbnail by URI, never the full object by URI), chain (new: the emulator's counter rose by exactly 2 against a photo's 1) |
| Worse verdict of the sheet and the thumbnail wins | `TestGIF_BlockedVerdictRejects` (sheet; thumbnail) |
| A refusal deletes the objects; a Vision failure is retryable | bomb tests (objects left: none); new `TestW618_VisionFailureSpendsNothingAndKeepsTheGIFRetryable` (UNAVAILABLE, 0 units, PENDING with the claim released, the retry is READY) |
| The 2 s deadline, a decoder panic, a changed object | `TestSampleGIF_DeadlineIsRefusedAsTooLong`, `TestGIFScreen_SamplerPanicIsRejectedAndReported`, `TestGIFScreen_ObjectChangedAfterVerifyIsRejected`, `TestGIFScreen_CorruptFrameDataIsRejectedAsInvalid` |
| Configured limits (`GIF_MAX_FRAMES`, area, edge) | `TestGIFScreen_ConfiguredLimitsApply`, `TestGIF_GifMaxEdgeIsConfigurable` |
| The accepted worst case stays in budget | new `TestW618_AcceptedWorstCaseStaysInsideTheMemoryBudget`: 300 frames of 400 x 400 (48 M of the 50 M area) on a 1,280 x 1,280 screen finalizes READY and allocates **55.1 MiB in total** (bound 80 MiB), file 183 KB, `decode_ms` about 500 on this machine; one 1,280 x 1,280 frame allocates 9.9 MiB |
| Memory assertions "pass under `-race`" | not run locally (no CGO); see section 1 and observation 3. The assertions use `TotalAlloc`, which the race detector does not inflate |
| Fixture GIFs under `testdata/media/` | not used: the developers build fixtures in the test (`encodeTestGIF`, `rawGIF`) so frame colours and delays sit next to the assertion; this audit kept that |
| Budget: Firestore unchanged; +1 Class B; Vision 2 units; CPU <= 0.5 s | chain (Firestore, Vision); CPU: see observation 3 (the at-limit fixture took about 500 ms of sampling on this machine) |

#### Named in the W6-18 description

| Item | Test(s) |
|---|---|
| The sniffer and content-type matrix | W6-9 section |
| Size and edge caps | `TestGIF_CreateUploadMatrix` (1,281 wide/tall, the 1,280 limit), `TestGIFScreen_ConfiguredLimitsApply` |
| Bomb fixtures (frame count, logical screen, frames x area) | W6-10 section |
| The sampled-frame verdict through the fake Moderator | `TestW618_ExplicitFrameVerdictMatrix` |
| Vision units (2) and the cap policy | W6-10 section |
| The flag on CreateUpload, CreatePost and SchedulePost | W6-9 section |
| The avatar refusal | W6-9 section |
| Purge of `.gif` objects; `nomedia` | W6-9 section |

---

### 4. Cases attacked from the developers' reports

| Attack | Result |
|---|---|
| Harmless first frame, explicit later frame | REJECTED when the explicit frame is a sample point (all four positions, and in GIFs of 2 to 4 frames); READY when strictly between samples (the F11 residual, pinned) |
| Explicit tail with delay 1 cs | **READY although it is 73 % of what a browser plays: defect D-1** |
| Decompression bombs | all refused before any decode: 0 Vision calls, the finalize allocates < 16 MiB |
| One-GIF slot | busy slot answers MEDIA_NOT_READY, spends no units, releases the claim; the slot is freed after a refusal; a photo is never blocked |
| Cap rejects GIFs for every account | confirmed, plus the one-unit boundary |
| GIF + another item in CreatePost, SchedulePost with a GIF, flag off | confirmed on the repo, the service and the wire |
| Cleanup names, hash stability | confirmed; the hash now has a literal golden |
| Publish swap | documented residual (section 6, R-1) |

### 5. Defects

**D-1 (Medium): the sampler does not model the browser's minimum frame delay, so explicit frames can dominate the playback time and still
escape every sample.**
`backend/internal/media/gifscan.go:182-214` (`sampleIndices`, also stated in ADR-0029 D11 point 4: "a 0 delay counted as 10 ms") counts a delay of
0 cs as 1 cs (and keeps 1 cs as 1 cs). Browsers, and so the Flutter image codec behind the client, play a GIF frame whose delay is 0 or 1 cs
(<= 10 ms) as 10 cs (100 ms). A GIF can therefore use delay 1 on its explicit frames: the sampler sees them as 10 ms each while the user sees
them for 100 ms each.

Repro (`backend/internal/media/gif_w618_test.go:TestW618_KnownGap_BrowserDelayClampIsNotModelled`): 21 harmless frames with delay 3 cs, then 17 explicit
frames with delay 1 cs. The sampler's display time is 63 + 17 = 80 cs, so its four sample points (0, 20, 40, 60 cs) all land in the harmless part;
the explicit run begins at 63 cs and is never sampled. A browser plays 63 cs of harmless frames and 170 cs of explicit ones: **73 % of the
playback**. `go test ./internal/media -run KnownGap` passes (it pins READY); `W618_RUN_DEFECTS=1 go test ./internal/media -run KnownGap` fails with
`D-1: result = {... Status:READY ...}, want REJECTED`.

Expected: the explicit run that dominates what the user sees is screened. Actual: READY, 2 units spent, published.
Why it matters: the accepted F11 residual is "a frame between two samples" (an explicit moment of at most about a quarter of the playback, in
the sampler's own clock). With the clamp mismatch the unscreened share of the *real* playback grows from about 25 % to about 75 %, which is a
different risk from the one the founder accepted. Mitigations that already exist: `FEATURE_GIF` is off and stays behind a 3-uid allowlist at Stage
0, and report-driven review (ADR-0016) is the backstop. Severity Medium: it widens an accepted, documented residual, needs a deliberately crafted
file, and the fix is two lines. Not a Blocker for merging W6-18 (tests only); it should be fixed before `FEATURE_GIF` leaves the allowlist.
Suggested fix (owner: backend-developer, with architect for the ADR line): in `sampleIndices` treat `delayCS < 2` as 10 cs (what Chrome, Firefox and
Safari do), update ADR-0029 D11 point 4 and the `docs/runbooks/media.md` sentence, then flip the test (it names the flip in its failure message).
Residual after the fix: a delay of 2 cs or more is played as written, so the usual F11 bound applies.

### 6. Known residuals pinned (not defects of this ticket)

**R-1 (for W6-20 security): the publish swap.** `TestW618_KnownResidual_PublishSwapAfterScreening`. FinalizeUpload samples the GIF from one read of the
private object (checked against the declared MD5) and publishes with `Objects.Publish`, a server-side copy of whatever object is stored at that
moment. The signed PUT URL pins no object generation, so a client holding the URL can overwrite the object between the sample and the copy; the
test replaces the object with an all-explicit GIF inside the `Publish` hook and the finalize returns READY with the swapped bytes published
(2 units spent on the harmless ones). The thumbnail has the same window (Vision reads it by URI, and `Publish` copies it later); photos have it
too. Fix options for W6-20: copy with a generation precondition read at screening time (`ifGenerationMatch`), or re-check the MD5 of the
published object before the Firestore resolve. If either lands, the test fails and must flip to REJECTED.

### 7. Observations (not defects)

1. **The ticket text for the cap is stale.** W6-10 says the cap and exhaustion policy "apply as for photos (READY_UNSCREENED or REJECTED)";
   ADR-0029 F11 point 4 (accepted) and the runbook say GIFs are always REJECTED at the cap. The code and the tests follow the ADR. The plan text can be
   corrected when the ticket is closed.
2. **"0 reads" for a disabled GIF is true at CreateUpload only.** At CreatePost the media document is read first (1 read per id) because the
   content type rides on the claim. The cost is bounded and the write count is 0. The W6-9 acceptance criterion should say "0 writes" for CreatePost.
3. **CPU and the 2 s decode deadline.** The at-limit fixture (300 frames, 48 M pixels, 1,280 x 1,280 screen) took about 500 ms in `decodeOneFrame`
   and the sampler on this machine, at the edge of the ticket's "CPU <= 0.5 s" (the runbook says about 0.7 s on a laptop-class core). The
   production deadline is 2 s; the new test raises it to 20 s so a slow CI runner cannot flake it. Under `-race` on a shared Linux runner the same
   file may approach the 2 s deadline and be REJECTED "too large": if that is ever seen in production logs it is `refused_reason=deadline`, which the
   runbook already covers. No test asserts the production deadline against the at-limit fixture on purpose (it would be machine-speed dependent).
4. **Memory is 55 MiB allocated in total for the worst case, against the runbook's "about 26 MiB live".** `TotalAlloc` counts garbage; the live figure
   is not measured by this test. The two numbers do not conflict, but nobody has measured peak live heap; if the instance (512 MiB) ever shows OOMs on
   GIFs, `GODEBUG=gctrace` on the at-limit fixture is the first step.
5. **`nomedia` does not stop posting an already READY GIF** (nor a photo). That is the documented scope of the mode.
6. **A valid GIF `CreateUpload` over the wire reaches the signer** and cannot be completed against the emulators. The dev smoke (W6-9 notes) is the
   only coverage of the signed PUT and the real `Content-Range` header.

### 8. Not run

- `-race` (no CGO on this machine; covered by the CI Linux job).
- The whole-module `make test-int`: only the packages touched (`internal/media` in full, `internal/posts` and `internal/apiserver` filtered to GIF tests)
  were run, because no production code changed. The apiserver package's full suite (about 30 minutes) was not repeated.
- The Flutter side (W6-19).
- Dev or prod smoke; real Cloud Vision on a GIF sheet (the Moderator is faked; the sheet's shape and the call arguments are asserted).
- Load: the one-GIF slot under concurrent traffic with real timings (W6-21/sre-performance); only the ordering and the 5 s wait are tested, with a 20-30 ms wait.

VERDICT: PASS (W6-18 as specified; one Medium defect D-1 filed as a pinned test, reproduced with `W618_RUN_DEFECTS=1`; one residual R-1 pinned for W6-20)
