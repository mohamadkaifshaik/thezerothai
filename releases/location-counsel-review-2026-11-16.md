# Location: reviewer's answers to the 12 counsel questions (2026-11-16)

**Status: a reasoned review by an AI assistant, NOT legal advice.** It is written so a lawyer can confirm or overturn each
point quickly. The product is India-facing (IST day boundaries, Mumbai database, `in.*` area ids, `privacy@dzeroth.com`),
so the main lens is India's Digital Personal Data Protection Act 2023 and its Rules. I could not check the current
text of the Rules from here, so every DPDP reference below needs verification before reliance. Facts come from
`docs/location-consent-review-2026-11-16.md` (the data map) and the draft on branch `docs/location-consent-copy`.

## Answers

| # | Question | Recommendation | Why |
|---|---|---|---|
| 1 | Disclose the 18+ tick as stored, and as a self-declaration? | **Yes, disclose (done).** Keep calling it a confirmation, not verification. | It is personal data we hold. The privacy page already says the app does not check age. See "Needs a lawyer" A. |
| 2 | Consent log (every grant and withdrawal), no TTL, kept until erasure? | **Keep, disclose (done).** It is the evidence of consent. Do not add a TTL now. | A fiduciary has to be able to show consent was given. It holds no area id. Counsel should confirm whether erasure on account deletion is right, or a minimal proof must outlive the account for a limitation period. |
| 3 | Qualify "only you" for processors, admins, backups? | **Yes (done).** The new text says "no other user" and names the processor and 14-day backups. | "Only you" was literally false. Admin access (project IAM) is still not mentioned; see "Open facts". |
| 4 | Describe the plan area in the consent copy? | **Yes (done).** | A different actor's disclosure of place data; viewers and Nearby see it. |
| 5 | Is "never where you live" acceptable though the server does not enforce it? | **Acceptable as advice, with one tweak: the catalogue is the safeguard.** The picker only offers 10 cities and 91 neighbourhoods, so a plan cannot carry a street address. Say "neighbourhood" in the form hint if counsel wants a stronger line. | Coarse by construction; the leak risk is a neighbourhood, not a home. Do not claim "never" as a guarantee. The draft keeps it as an instruction ("Pick where the plan meets"). |
| 6 | Is a version number enough evidence of the text? | **No, archive the text.** Done: `location_notice_archive_test.dart` stores v1 and v2 word for word and fails if wording changes without a bump. | The server stores only the number. |
| 7 | Privacy page before the flag is on for real users? | **Yes, hard requirement.** The page's own maintainer note says so. Deploy the page before any real user is allowlisted. | Consent without the policy it points to is weak. The consent screen now links to the policy. |
| 8 | Does the export meet an access request? | **Looks sufficient:** area (with catalogue name and city), consent log, plan areas are all exported. | Counsel to confirm completeness against the data map (idempotency hashes aside). |
| 9 | Describe backups next to erasure? | **Yes (done)** in the consent text and the retention list. | Erasure does not reach the 14-day backups. |
| 10 | "ADR pending", design note missing | **Write the ADR** (owner). Accept it before launch. | The code comments cite a design note that is not in the repo, which weakens the audit trail. |
| 11 | Does desktop "Happening nearby" fit the single purpose? | **Yes.** It shows plans near the stored area, which is the stated purpose (`plans_nearby`). Disclosed in the privacy text. | It reads the area without a tap, so the privacy text says where it is used. |
| 12 | Must the copy state the geographic scope? | **No.** The picker shows what is available. | Not a data-handling fact. |

## Changes this review made to the draft (also on the branch)
- Button label **Continue -> "Agree and continue"**. Before, the only explicit act was an 18+ tick plus "Continue"; consent
  should be an unambiguous affirmative action for the stated purpose.
- **Privacy policy link on the consent screen**, so the notice points to the full policy.
- **Notice archive test** (answers Q6).

## Needs a lawyer (cannot be settled from the repo)
- **A. Age.** The app confirms 18+ by a tick and no check. Whether that is enough under the DPDP rules for a service that
  may attract minors (verifiable parental consent for under-18s) is a legal call. The mitigation today is that location
  is optional, coarse and not collected from the device.
- **B. DPDP notice content.** Check the notice and policy against the Act's notice requirements (itemised data,
  purpose, how to withdraw, grievance contact, language availability) and the Rules' log-retention rules (I recall a
  one-year minimum for some logs; verify). The privacy page has a grievance mailbox, but confirm it meets the
  designated-contact rule.
- **C. Erasure vs consent evidence** (Q2).
- **D. Withdrawal.** "Clear my area" is one tap with no confirmation, which is as easy as giving consent. Good. Note it does
  not change a plan area the user organised; the notice now says so.

## Open facts (nobody has checked)
Whether the idempotency (24 h) and beacons TTL policies are applied in dev and prod; who holds project/Firestore admin
access in each project; whether account deletion removes uid-keyed idempotency docs; the prod flag state; the Play
data-safety and App Store privacy labels for Location. The privacy page makes **no claim** about the plan-area TTL
because of this.

## Before launch (owner)
1. Set `LOCATION_CONSENT_COPY_VERSION=2` and `LOCATION_CONSENT_MIN_COPY_VERSION=2` (now the default). Old apps get
   "update required".
2. Ship the app and `privacy.html` together; privacy page first for any allowlisted user.
3. Founder approves the privacy text (the file's own header requires it).
4. Check the store privacy labels.
