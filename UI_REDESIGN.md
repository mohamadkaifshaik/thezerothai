# Dzeroth mobile screen redesign and feature review

The 40 phone artboards in *Social Feed Screens (1).html* show the intended layout at 390 × 844. This pass applies the reference to the highest-traffic flows and records the remaining differences. The shared mobile back header uses the reference's chevron and title typography across pushed screens. The existing `ui_shell` flag controls where the floating navigation appears. The two example plans on Welcome are illustrations for signed-out visitors.

## Implementation order

1. Map the reference artboards to the current Flutter routes and check where the prototype and app implement different behavior.
2. Apply the mobile layouts to authentication, feed and post interactions, the composer, Plans, Notifications and Data usage. Reuse the current controls and responsive layouts.
3. Check the changed routes across phone, tablet and desktop widths. Prioritize any remaining visual work after resolving the feature decisions below.

## Screen coverage

| Reference | Current surface | Result or remaining difference |
| --- | --- | --- |
| 1. Home feed | Home | Four-line previews for text-only posts on phones. The header uses the drawer and Manage pinned. Home supports pinned communities and Lists. Keep explicit pinning unless the product should automatically add every joined community. |
| 2. Community tab and media | Community feed and shared post gallery | The gallery shows its position and up to five dots. Media follows the source aspect ratio. The sample link preview and online member count need service support. |
| 3. Post and replies | Post detail | Mobile engagement totals sit above the buttons, and replies from the root author carry an Author tag. View counts follow the existing feature flag. The existing reply composer enforces the account's post limit. |
| 4. Thread | The same post route for self-threads | Added an author-only Add to thread button that opens a reply to the last post in the chain once the replies are loaded. The existing rail and highlighted post remain part of the layout. |
| 5. Compose | New post | Visible mobile title and navy Post button. The app selects the audience through a picker and retains its attachment editor, polls, scheduling and other tools. The reference's 500-character limit and pre-publish multi-post composer require changes outside this restyle. |
| 6. Profile | Profile | Existing profile and tabs cover the main flow. The status chip and its editing and visibility rules need a product and API decision. |
| 7. Plans | Plans and shared plan-card rows | Date tile, activity and audience, time and venue, and live capacity on phones. Participants' identities stay on the permission-checked detail surface. The one-tap action follows server eligibility. |
| 8. Messages | Inbox | The visible mobile search pill opens the existing search behind its feature flag. Message requests, settings and encryption status use their existing controls. |
| 9. Settings | Settings | Existing groups and navigation cover the corresponding settings. The app exposes additional device and account controls. |
| 10. Welcome | Welcome | Navy mobile layout, plan illustrations and the reference headline. Apple continues to depend on platform and configuration. |
| 11. Sign in | Email sign-in | Compact mobile header, reference welcome copy and actions directly below the form. Existing recovery, provider and support links are available. |
| 12. Create profile | Onboarding and profile-photo step | The current flow collects profile details and photo on separate steps. Combining them would change onboarding sequence and completion rules. |
| 13. Choose area | Area picker and location settings | The app supports an optional manually selected area. The sample map and fixed three-step progress treatment remain visual differences. |
| 14. Plan detail | Plan detail | Mobile overview card, audience and activity pills, fact grid, and Details heading. Joining uses the existing request sheet and server state. |
| 15. New plan | Plan creation | The current form has activity, time, venue, spots, details and additional controls. Keep the server's capacity and field limits when restyling this form. |
| 16. My plans | My plans | The current view covers plans you organise, requests and accepted plans. The reference's dated rows and grouping are a separate presentation pass. |
| 17. Requests | Plan people | The current screen supports accepting and declining requests and displays participant state. A combined Decline and block action needs an explicit workflow for partial failures. |
| 18. Explore | Explore and Nearby | Nearby plans, trending and people exist behind their respective flags. Trend results lack the plan count per hashtag shown by the prototype. |
| 19. Search results | Search | Existing result types and query controls support the core flow. A geographic restriction on general search requires an API contract and a definition of the area boundary. |
| 20. Notifications | Notifications | Added New and Earlier headings from the app's existing unread snapshot on phones. Existing category filters and request actions remain available. |
| 21. Communities | Community directory | Existing discovery, joining and creation flows. The reference's per-community unread-post badges require a scoped unread count. |
| 22. Chat | Conversation | Existing encrypted conversations and plan shares cover the core flow. The prototype's single-device-style copy omits group and device-management states. |
| 23. Lists | Lists and Manage pinned | Existing Lists support pinning and reordering. Management lives in a dedicated screen and Following stays first. |
| 24. Saved | Bookmarks and History | The app provides saved posts and feature-gated opened-post history. Reference row treatment remains a visual difference. |
| 25. Article | Article reader | Existing reader, author and article actions provide the underlying flow. The reference cover and article text are sample content. |
| 26. Creator Studio | Creator Studio | Existing analytics provide the starting point. Check the metric definitions and API range before copying the reference deltas and refresh labels. |
| 27. Plus | Premium dialog | The live dialog uses store products and restore flow. Confirm any desired full-screen format and benefits before changing purchase presentation. The design export supplies placeholder prices and benefits. |
| 28. Edit profile | Edit profile | The existing form updates supported profile fields. A status field depends on the same decision as Profile. |
| 29. Change handle | Change handle | The existing flow validates updates and eligibility. Display the current server policy for handle changes in any future copy update. |
| 30. Follow requests | Follow requests | The app implements accept and decline. The reference's quick follow-back treatment is a separate interaction change for this screen. |
| 31. Download my data | Data export | Existing export states and download action are backed by the service. The reference's stepper is a presentation change for those states. |
| 32. Delete account | Delete account | Existing deletion and confirmation flow. Match the layout around the live confirmation and reauthentication requirements. |
| 33. Notification settings | Notification settings | Per-category controls exist. Quiet hours and plan-reminder exceptions need a delivery policy covering time zones and devices. |
| 34. Encrypted messages | Encryption settings | Device management exists with the app's current encryption and recovery copy. The sample device list and shortened text are illustrative. |
| 35. Data usage | Data usage | Separate Data saver and Image quality cards on phones. The app still supports connection-specific choices. Unsent-post deletion is available in Settings when applicable. A storage breakdown and clear-image-cache control need real measurements and cache integration. |
| 36. Drafts and scheduled | Unsent posts and Scheduled | The feature-gated app screens cover drafts and scheduled posts. Verify the action semantics for any future Post now control before adding it. |
| 37. Photo viewer | Full-screen post media | Existing viewer supports paging, zoom and alt text. The main feed and community gallery gained the reference position indicator. The viewer itself keeps its current controls. |
| 38. Members and mod log | Community members and moderation log | The app provides separate feature-gated pages. Confirm visibility rules and server-backed member search before reproducing the combined tabs. |
| 39. List detail | List detail and members | The app has a List feed, member view and management controls. Use live visibility and pin state in any further header restyle. |
| 40. Calls | Calls placeholder | The app marks calls as upcoming. A real launch alert needs notification enrollment and delivery. |

## Product decisions to resolve

- Keep the current post limits unless the product adopts 500 characters for free accounts. If approved, update server validation, clients and shared fixtures together. The current limits are 280 for free accounts and up to 15,000 with the applicable entitlement.
- Decide whether Home should pin joined communities automatically or continue to let users curate their tabs. Confirm whether the avatar should keep opening the drawer and what the reference's For you control should display.
- Specify profile status and link preview data before adding their UI. Define status visibility and moderation, and decide which link metadata the server provides.
- Define the behavior for combined decline and block, quiet hours, geographic search and call-launch notifications before introducing controls that imply those features are available.

## Verification

Flutter static analysis passed. The redesign test run passed 452 tests, and the broader regression run passed 4,169. These runs covered changed routes, feature flags, and phone, tablet and desktop layouts. Rendered previews were reviewed for Welcome, Plans, Plan detail and Thread. Device rendering and a complete visual comparison across all 40 artboards remain open.

## Code references

- [Flutter routes](app/lib/core/router/app_router.dart) and [navigation shell](app/lib/core/router/main_shell.dart)
- [Post text policy](app/lib/features/posts/domain/post_text_rules.dart), [server validation](backend/internal/posts/text/text.go) and [search API](proto/dzeroth/search/v1/search.proto)
- [Plan API](proto/dzeroth/beacons/v1/beacons.proto), [identity API](proto/dzeroth/identity/v1/identity.proto) and [premium route](app/lib/core/router/routes/premium_route.dart)
