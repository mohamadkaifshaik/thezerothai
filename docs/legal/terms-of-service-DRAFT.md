> **DRAFT - NOT REVIEWED BY COUNSEL - NOT APPROVED - DO NOT PUBLISH**
>
> Prepared for the founder's review only. Not linked from the app, not served from `app/web/`, not part of any release. Every `[FOUNDER DECISION]` and `[LEGAL REVIEW NEEDED]` marker must be resolved and reviewed by qualified counsel before this text is shown to anyone.

# Dzeroth Terms of Service

**Status:** Draft v0.2 · **Last updated:** [DATE - set on approval]
**Companion document:** [Privacy Policy](https://dzeroth.com/privacy.html). The Privacy Policy governs how we handle data (section 9).

---

## Cover: Open decisions for the founder

Check each item before this draft can move forward.

- [ ] **Legal entity and address.** Decide whether Dzeroth is run by you personally or through a registered entity, and supply the legal name, registered address and registration number. None are recorded in the repo, so none are written here.
- [ ] **Minimum age** (13, 16 or 18). See section 1.2.
- [ ] **Licence scope.** Confirm the content licence in section 3.3, including whether content may be used to train machine-learning models (this draft says no).
- [ ] **Response time and appeals.** Confirm the 48-hour response time (section 5.2) and decide whether to offer appeals (section 6.3).
- [ ] **Unscreened images.** Decide what happens to images when the automated check's monthly cap is reached. See section 7.3.
- [ ] **Copyright process and grievance officer.** See section 11.
- [ ] **Liability cap amount.** See section 12.4.
- [ ] **Change-notice period.** See section 15.1.
- [ ] **Governing law and venue.** See section 16.
- [ ] **Contact details.** Confirm a legal contact address (section 17). privacy@dzeroth.com is published in the Privacy Policy and is used here for privacy requests only.

**Known mismatches to fix before publication (from reading the product and docs):**

1. The in-app export copy (`app/lib/features/account/presentation/data_export_screen.dart`) says the export includes posts. The Privacy Policy's export list (profile, sign-in record, social graph) does not mention posts, and the ADR-0011 export has a posts section. Reconcile all three.
2. The Privacy Policy does not yet say how safety reports are kept. The reports plan (`docs/plans/reports.md`, D7) says reports you filed are kept with your identity removed, and reports about you are kept until 90 days after resolution. The plan lists the Privacy Policy update as a founder action before `FEATURE_REPORTS` is turned on. The Privacy Policy's maintainer note also requires an ADR-0011 amendment and a privacy.html update in the same PR for any new retained item.
3. The delete-account screen's "What remains" copy (mentions of you and backups within 14 days) is shorter than the Privacy Policy's list of retained data, and both are shorter than the reports residue in item 2.
4. The Privacy Policy says the app has no image uploads, moderation, notifications or in-app account deletion. Those are built behind feature flags that default to off. This draft describes them as "when available". Keep it that way until each flag is on in production, and update both documents together.
5. The Privacy Policy has no named Grievance Officer. Section 11.4 needs one.
6. The web deletion link that Google Play expects (for apps with in-app account creation) was not found in the repo. Verify it.

**App-store implications** (verify current store policies before submission):

Apple guideline 1.2 requires: a method for filtering objectionable material, a mechanism to report offensive content with timely responses, the ability to block abusive users, and published contact information. It also says removals are based on "your terms of service, or your community standards", which is why this document includes zero-tolerance wording (section 4). Guideline 5.1.1(v) requires in-app account deletion for apps that support account creation.

| Store expectation for user-generated content (UGC) | Where it stands in the repo | Status |
|---|---|---|
| Filter objectionable content | Image SafeSearch screening (`docs/plans/media-uploads.md`) behind `FEATURE_MEDIA` (default off). A search of backend, app and proto for blocklist or profanity terms found no text filter. | Image check built, off. No text filter. |
| Report objectionable content and accounts | `ReportContent` RPC and report sheet in the app (`docs/adr/0016-reports-and-moderation-actions.md`), behind `FEATURE_REPORTS` (default off) | Built, off in production |
| Block abusive users | Block and mute (`docs/adr/0008`), behind `FEATURE_GRAPH` (default off) | Built, off in production |
| Timely responses to reports; published response time | Founder-run `opsctl` procedure; 48-hour triage target (`docs/runbooks/moderation.md`) | Procedure exists. Response time not yet published to users. |
| Published contact | privacy@dzeroth.com in the Privacy Policy. No general or legal contact yet. | Partly done |
| In-app account deletion (guideline 5.1.1(v)) | `DeleteAccount` and export screens behind `FEATURE_ACCOUNT_LIFECYCLE` (default off); today deletion is by email (`docs/runbooks/account-deletion.md`) | Built, off in production. Google Play web deletion link not found. |
| Privacy Policy URL | `https://dzeroth.com/privacy.html`, linked from sign-up and settings | Done |
| Terms link and acceptance at sign-up | This document is not approved or published. Sign-up has no terms link or acceptance step. | Open. Not built. [LEGAL REVIEW NEEDED] |

---

## 1. Acceptance and eligibility

1.1 Dzeroth is a text-first social app for sharing short posts and following other people. It is run by [LEGAL ENTITY NAME - FOUNDER DECISION] from [REGISTERED ADDRESS - FOUNDER DECISION], and is available at dzeroth.com and in the Dzeroth app.

1.2 **Minimum age: [FOUNDER DECISION: 13, 16 or 18].** The Privacy Policy currently says 18 and over, and the app does not check age at sign-up. [LEGAL REVIEW NEEDED: under India's Digital Personal Data Protection Act, 2023, a child is anyone under 18. Processing a child's personal data requires verifiable parental consent, and the Act restricts tracking and targeted advertising directed at children. The DPDP Rules set out how consent must be obtained. Setting a minimum age below 18 means building that consent mechanism before launch. Choosing 18 avoids it, but still needs a way to act on reports that a user is under 18.]

1.3 You must be legally able to form a binding contract where you live. If you use Dzeroth for an organisation, you confirm you have authority to bind it.

1.4 Using Dzeroth means you accept these Terms. If you do not agree, do not use Dzeroth.

## 2. Accounts and security

2.1 You can sign up with an email address and password, or with Google or Apple. Email and password accounts must verify the email address before a profile can be created.

2.2 You must give accurate information, keep your sign-in details safe, and tell us as soon as you notice unauthorised use of your account. You are responsible for activity on your account.

2.3 [FOUNDER DECISION: confirm whether one account per person applies.]

2.4 We may ask you to verify your account, and we may limit or suspend access while we investigate suspected abuse, fraud or security problems.

## 3. Your content and licence

3.1 **"Content"** means anything you post, including text, images, alt text, handles, mentions and profile information.

3.2 You keep ownership of your Content. You are responsible for it, and you must have the rights needed to post it.

3.3 **Licence you give us.** You grant Dzeroth a worldwide, non-exclusive, royalty-free licence to host, store, copy, display, format, resize, compress and distribute your Content within the service, so that others can see it and the app works. The licence lasts while your Content exists on Dzeroth. It ends when you delete the Content or your account, except for copies that have already been made and cannot be recalled, such as those in backups (section 10.4) and those held by other people who saw the Content before deletion. [LEGAL REVIEW NEEDED: confirm the licence scope. This draft does not grant a right to train machine-learning models and does not sell Content. Any broader grant needs an express decision.]

3.4 We do not sell your Content or use it for third-party advertising. See section 9.

3.5 Other people's Content is theirs. Do not copy, reuse or republish it except as the app's features allow.

## 4. Acceptable use

4.1 Dzeroth has zero tolerance for the following. You must not use Dzeroth to:

- post sexual content involving anyone under 18, or any content that sexualises children. We will remove it, and we will report it as the law requires. [LEGAL REVIEW NEEDED: reporting duty and procedure under Indian law.]
- break the law, or post content that is illegal where it is posted or viewed;
- share non-consensual intimate images, or threaten, harass, bully or stalk anyone;
- share someone's private contact details or other private information without consent (doxxing);
- impersonate another person, an organisation or Dzeroth itself;
- promote violence or hate against people based on protected characteristics;
- send spam, run bots, scrape the service, or create accounts to get around a block, suspension or limit;
- try to access another person's account or data, probe or disrupt our systems, or distribute malware;
- infringe anyone's intellectual property (see section 11).

4.2 We may also act on content that is not listed above but breaks the spirit of these rules. We apply these rules as consistently as we can, but we cannot promise to catch everything.

## 5. Reporting

5.1 You can report any post or account from its menu. Reports are private: the person you report is never told who reported them.

5.2 We aim to acknowledge and review every report within **48 hours**. Clearly illegal content, such as child sexual abuse material, credible threats or doxxing of a private person, is removed as soon as we see it, ahead of the normal queue. [FOUNDER DECISION: confirm 48 hours is an acceptable published response time. Store rules expect a stated time.]

5.3 Reporting is available only once the reporting feature is switched on for you. Until then, email [LEGAL CONTACT EMAIL - FOUNDER DECISION].

## 6. Blocking, takedowns and suspensions

6.1 **Blocking.** When you block someone, they cannot view your profile or follow you, and any follow between you is removed in both directions. Blocking is enforced on notifications too: we do not send you notifications about a person you have blocked or muted.

6.2 **Muting.** Muting changes only what you see. The other person is not told.

6.3 **Appeals.** [FOUNDER DECISION: offer an appeal or not. If yes, describe the route. Today you can ask us to review a decision by emailing [LEGAL CONTACT EMAIL - FOUNDER DECISION]. We will try to respond within 30 days, and a decision on appeal may be final.]

6.4 **Not disclosed.** Blocks and mutes are not disclosed to the other person, and the app does not show anyone a list of who has blocked them. We cannot promise a blocked person will never work out that they have been blocked; for example, they may notice that a follow has disappeared.

6.5 **Takedowns and suspensions.** We may hide or remove content, restrict features, or suspend or end an account, for example when content breaks these Terms, when we receive a valid legal request, or when we need to protect people or the service. We may act before or without a report.

6.6 **Timing.** When we hide a post, it disappears from our servers and from feeds within about one minute, but copies that other people's devices already hold may stay visible until those devices refresh. We do not guarantee how quickly any content will be removed or reviewed beyond the response time in section 5.2.

6.7 **Limits.** We may limit how many follows, blocks, mutes, reports, posts or uploads you can make in a day to protect the service.

## 7. Image uploads and automated screening

7.1 When image uploads are available, you may attach up to four images to a post and use one as your avatar. Images are resized and re-encoded on your device, and location and other camera metadata are removed.

7.2 **Automated screening.** Before an uploaded image is shown to others, it is checked by an automated safety classifier (Google Cloud Vision SafeSearch). Images that fail are not published. Except as described in section 7.3, an image is not shown until it has passed this check. Automated checks make mistakes, so you can report any image, and we can remove an image at any time.

7.3 **Capacity limit.** The automated check has a monthly usage cap. [FOUNDER DECISION: choose one and state it here before launch. Option A, as currently built: when the cap is reached, new uploads from accounts less than 7 days old are refused until the cap resets, and older accounts may still publish images without an automated check. Option B: all new uploads are refused until the cap resets. Option A means some images are shown without the automated check; this must be disclosed if it is kept.]

7.4 Images are stored in a United States region of Google Cloud. See section 9.

7.5 Deleting a post also removes its images from our storage, as described in section 10.

## 8. Notifications and push messages

8.1 Dzeroth may send you in-app notifications, and push messages through Firebase Cloud Messaging on your device, when someone interacts with your content or account. Push is switched on only once the notifications feature is available to you.

8.2 You can turn off push notifications in your device settings. No in-app push control was found in the repo. [VERIFY before publication.] We do not guarantee that a notification will be delivered or delivered on time.

## 9. Privacy

9.1 Our [Privacy Policy](https://dzeroth.com/privacy.html) explains what information we collect, why, where it is stored, who processes it on our behalf, how long we keep it and your rights. It governs how we handle personal data. If anything in these Terms conflicts with the Privacy Policy on data handling, the Privacy Policy applies.

9.2 Questions about your data: privacy@dzeroth.com.

## 10. Account deletion and data export

10.1 **Deleting your account.** You can delete your account at any time. [VERIFY: once `FEATURE_ACCOUNT_LIFECYCLE` is on, describe the in-app steps here, including the password or re-authentication prompt and the typed confirmation. Until then, email privacy@dzeroth.com from the account's email address.]

10.2 **What happens.** Deletion is permanent and cannot be undone. It removes your profile, your handle (which then becomes available to others), your sign-in account, your posts and images, your follows and followers, your blocked and muted lists, and any exports you requested. You are removed from other people's follower and following lists, and their counts are corrected.

10.3 **Timing.** Your sign-in is disabled immediately. Most deletions complete within minutes. Large accounts may take longer. [VERIFY timing against the chosen deletion design in `docs/adr/0011-account-lifecycle.md`.]

10.4 **What may remain.** The Privacy Policy lists the limited data that can outlast deletion: short-lived duplicate-request records (up to 24 hours), backups (kept up to 14 days), internal deletion task messages (up to 7 days), server logs (about 30 days), other people's private block and mute lists (cleaned up when their owner next views them), and mentions of you in other people's posts. [LEGAL REVIEW NEEDED and FOUNDER DECISION: safety reports are not yet in the Privacy Policy. The reports plan keeps reports you filed with your identity removed, and reports about you until 90 days after resolution, when the reporting feature is on. Add this to the Privacy Policy before that feature is enabled.]

10.5 **Data export.** You can request a copy of your data. [VERIFY the export contents against the Privacy Policy: see mismatch 1 on the cover.] Where the in-app export is available, you may request one export per day and download it for 7 days. Until then, email privacy@dzeroth.com from your account's email address, and we will respond within 30 days.

10.6 An export never includes information about who has blocked you, because that is about other people.

## 11. Intellectual property and copyright complaints

11.1 Do not post content you do not have the right to share.

11.2 **Complaints.** If you believe content on Dzeroth infringes your copyright or other rights, send a notice to [COPYRIGHT COMPLAINTS CONTACT - FOUNDER DECISION] with: your name and contact details; the content and where it is; the right you believe is infringed and why; a statement that you believe the use is unauthorised; and a statement that the information is accurate and that you are the rights holder or authorised to act for them. [LEGAL REVIEW NEEDED: the process should follow India's Information Technology Act, 2000 and the Information Technology (Intermediary Guidelines and Digital Media Ethics Code) Rules, 2021. Counsel must confirm the current acknowledgement, resolution and takedown timelines, which have been amended since the Rules were first published, and which obligations apply to Dzeroth.]

11.3 **Repeat infringers.** [FOUNDER DECISION: state the policy for repeat infringers, for example suspending accounts after repeated valid notices.]

11.4 **Grievance officer.** [GRIEVANCE OFFICER NAME AND CONTACT - REQUIRED, FOUNDER DECISION. The Privacy Policy also needs this person named.]

## 12. Disclaimers and limitation of liability

12.1 Dzeroth is provided "as is" and "as available". We do not guarantee the service will be uninterrupted, error-free, secure or suitable for any purpose. This is an early-stage project and features may change or stop.

12.2 Content on Dzeroth belongs to the people who post it. We do not endorse it and are not responsible for it, though we may remove it under section 6.

12.3 To the extent the law allows, Dzeroth is not liable for indirect, incidental, special or consequential losses, or for loss of data, profits or goodwill.

12.4 [FOUNDER DECISION: total liability cap, for example the greater of INR [AMOUNT] or the amount you paid us in the last 12 months. Dzeroth currently has no paid features; confirm this.] [LEGAL REVIEW NEEDED: Indian consumer-protection and contract law may limit how far these exclusions apply, and nothing here limits liability that cannot lawfully be limited.]

## 13. Indemnity

13.1 You will defend and indemnify Dzeroth and its founder against claims that arise from your Content or from your breach of these Terms, to the extent allowed by law. [LEGAL REVIEW NEEDED: check enforceability under Indian law, and whether a consumer indemnity is appropriate.]

## 14. Termination

14.1 You may stop using Dzeroth and delete your account at any time (section 10).

14.2 We may suspend or end your access, with or without notice, if you breach these Terms or if we must do so to comply with the law or to protect people or the service. Sections 3.3, 9, 10.4, 10.6, 11, 12, 13, 14.2, 16 and 17 survive termination.

## 15. Changes to these Terms

15.1 We may update these Terms as Dzeroth changes. [FOUNDER DECISION: notice period, for example 14 days by in-app notice and email for material changes.] Minor changes take effect when posted. Continued use after a change takes effect means you accept it. If you do not accept a material change, you can delete your account (section 10).

15.2 We will update the "Last updated" date each time we change these Terms.

## 16. Governing law and disputes

16.1 **Governing law:** [FOUNDER DECISION: likely India; LEGAL REVIEW NEEDED].

16.2 **Venue:** [FOUNDER DECISION: courts of [CITY, STATE] or arbitration seated in [CITY]. LEGAL REVIEW NEEDED: check consumer-protection rules that give users a right to their home forum.]

16.3 Before starting a dispute, please contact us so we can try to resolve it.

## 17. Contact

- Privacy and data requests: privacy@dzeroth.com
- Legal, general, reporting-without-app and appeal requests: [LEGAL CONTACT EMAIL - FOUNDER DECISION]
- Grievance officer: [see section 11.4]
- Postal address: [REGISTERED ADDRESS - FOUNDER DECISION]

---

*This draft is not legal advice and has not been reviewed by counsel. It must not be published, linked from the app or used with any user until the founder has resolved every marker and qualified counsel has reviewed it.*
