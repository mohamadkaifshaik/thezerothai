# Section 6: dev traffic repair follow-ups (soak and `removed_ids` retest)
Status 2026-10-19: **soak evidence recorded (below); `removed_ids` retest NOT yet run.** Section 6 is complete only when both are verified.

## Fixed facts to record before any test (read-only, 2026-10-19)
| Item | Value |
|---|---|
| Serving revision (status.traffic, not the template) | `api-00144-xt7` 100% (traffic tag `cand`); `api-00089-wuw` 0% (tag `p8-t1`) |
| Serving image | `sha256:1f661cec...` built from `b6f853d` |
| Newest revision | `api-00145-rqh` (image `528f17d3...`, from the #166 merge deploy at 05:47Z): Ready, scaled to zero, **0% traffic, not serving** (Terraform pins traffic, so every Deploy dev run creates an unserved revision; the known gap Option C fixes) |
| API URL | `https://api-7sf5r44tbq-el.a.run.app` (Hosting `/api/**` rewrites to it) |
| Web client | `https://dzeroth-dev.web.app`, built by Deploy dev run 39206196004 at `a3c0400`; `git diff b6f853d a3c0400 -- app backend proto firebase` is empty, so client and backend code equal the `b6f853d` build the serving revision runs |
| `FEATURE_REMOVED_IDS` on the serving revision | `allowlist`, 1 entry (count only; uid not recorded here), percent 0 |

## Soak (8 minutes): evidence
Run 2026-10-19 05:45:43Z to 05:53:47Z by read-only probe of `GET /health` every 30 s: **16/16 returned 200**. In the 25 minutes of
Cloud Logging covering it: **0** responses with status 500-504, **0** entries with severity ERROR, 35 responses with status 200.
Serving revision unchanged afterwards. Caveats: it ran about 1 day after the 10-18 traffic switch (not immediately after it); a
Deploy dev run created the unserved `api-00145-rqh` during the window (no traffic effect); dev traffic is low, so this shows "no
errors under probe load", not behaviour under real load. The authenticated paths were not exercised.

## `removed_ids` retest: protocol (needs the founder's signed-in dev client)
**Timing caveat (runbook `moderation.md` 3b):** until the cutover date 2026-10-25 (`defaultRemovalAuthorScopedFrom`,
`backend/internal/posts/removals.go`), a refresh whose log window reaches before it **resets the feed instead of querying the
log**. A run before 2026-10-25 can only show the reset, which is by design and is NOT a pass for `removed_ids` delivery.
Recommended: run on or after 2026-10-25.

Mutations on dev (need explicit founder approval before they run): one `takedown-post` and one `restore-post` against a dev test post.
1. Record the serving revision again (`gcloud run services describe api ... status.traffic`). It must still be `api-00144-xt7`.
2. Founder, signed in on `https://dzeroth-dev.web.app`, opens Home, notes a post P by an account the viewer follows, pulls to refresh
   once (this stores a `since_token`).
3. Operator: `go run ./cmd/opsctl takedown-post --project dzeroth-dev --post <P>` (founder's ADC; dry-run does not exist for this
   command). Expect `postRemovals/<P>` state REMOVED.
4. Wait 60-120 s (instance cache lag), then the founder pulls to refresh again without reloading the page.
5. **Pass:** P disappears from Home on that refresh without a full feed reset, and the request's log line shows the serving revision
   `api-00144-xt7`, `removed_ids` non-empty (count only), no ERROR. **Reset instead:** record it, do not call it a pass.
6. Cleanup: `restore-post --post <P>`, confirm state RESTORED and P is visible again. The log entries expire by TTL (32 days).
Evidence to capture (no credentials, tokens, uids or post text): UTC times of each step, the revision name, the number of
`postRemovals` documents (1), request status codes and the `removal_log_reads` counter, and one redacted client screenshot.
Stop and report if anything but `api-00144-xt7` serves, if any 5xx appears, or if the post is not restored.
