# Runbook: manual account deletion and data export

**Why this exists:** in-app `DeleteAccount` / `RequestAccountExport` ship in Phase 1. Until then, requests to
**privacy@dzeroth.com** are handled by hand, within **30 days**, as the privacy policy promises. This closes security
audit finding M5 for the web launch. App Store and Play submissions still need the in-app flow.

Run it from Git Bash with the founder's gcloud login. Examples use prod; use `dzeroth-dev` for dev accounts.
```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"; P=dzeroth-prod
TOKEN=$("$G" auth print-access-token)
H=(-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $P" -H "Content-Type: application/json")
```

## 1. Verify the requester
Act only on a request that comes **from the account's own email address**. Otherwise, reply to the account's address
and ask them to confirm. Never act on a request from a different address.

## 2. Find the user
```bash
curl -s "${H[@]}" -X POST "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:lookup" \
  -d '{"email":["user@example.com"]}'           # -> users[0].localId is the uid
UID_=<localId from above>
curl -s "${H[@]}" "https://firestore.googleapis.com/v1/projects/$P/databases/(default)/documents/users/$UID_"
# -> fields.handleLower is the handle document id
```

## 3a. Export (a right-to-access / portability request)
Send the user their data as JSON: the `users/<uid>` document from step 2, plus the Auth record (email, provider,
created and last-login times) from `accounts:lookup`. Phase 1 will add posts, follows and likes here as those modules
ship. Don't include internal fields such as `status`.

## 3b. Delete
```bash
npx -y firebase-tools@15 firestore:delete "users/$UID_" --recursive --project $P --force   # profile + subcollections
npx -y firebase-tools@15 firestore:delete "handles/<handleLower>" --project $P --force     # frees the handle
npx -y firebase-tools@15 firestore:delete "graph/$UID_" --project $P --force               # follow-graph doc
curl -s "${H[@]}" -X POST "https://identitytoolkit.googleapis.com/v1/projects/$P/accounts:delete" \
  -d "{\"localId\":\"$UID_\"}"                                                               # Firebase Auth user
```
- **Media:** Phase 0 has no avatars or posts, so there's nothing to delete. When media ships, also delete
  `gs://$P-media/m/<mediaId>*` for the user's media, and extend this list (and ADR-0003's delete path) as each
  Phase 1 module lands.
- **Backups:** prod weekly Firestore backups keep data for up to **14 days**, and deleted data ages out with them.
  Say so in the reply. Logs hold only a hashed uid.

## 4. Confirm and record
Reply to the user that the deletion or export is done (mention the 14-day backup expiry for deletions). Record the
date, request type and a **hashed** uid in the founder's private tracker, not in this repo.
