# Authentication design port

The sign-in and sign-up routes render the approved design as Flutter widgets.
Visual authority: `.design-reference/dzeroth-auth/reference/`, its desktop
preview, and the mobile adapter and screenshot boards. No WebView, HTML screen,
preview toolbar, or phone frame is included in the application.

## Implementation

- `app/lib/features/auth/presentation/auth_screen.dart` shares the provider-first
  and expanded email states, existing BLoC events, errors, and route switches.
- `widgets/auth_experience_layout.dart` contains the 760px mobile breakpoint,
  equal desktop columns, tabs, header, help, appearance menu, and footer.
- `widgets/auth_brand_scene.dart` draws the orbital illustration, tilted plan
  cards, four manual captions, and seven-second motion. Device reduced-motion
  preferences stop the animation. The plan details are decorative example copy.
- `widgets/auth_design.dart` scopes the original light palette, documented dark
  extension, Manrope headings, and DM Sans controls to authentication.
- `widgets/email_password_form.dart` retains password confirmation, validation,
  autofill, keyboard submission, password visibility, and trimmed email handling.
- `widgets/password_reset_dialog.dart` and `bloc/password_reset_cubit.dart`
  request real Firebase password-reset emails through `AuthRepository`, prevent
  duplicate requests, and give neutral confirmation for unknown addresses.
- `app/assets/branding/auth-icon.png` matches the approved reference asset.
  `app/assets/fonts/` contains Google Fonts variable TTFs and their OFL licenses;
  they are bundled locally through `app/pubspec.yaml`, with no new dependency.

## Integration and accessibility choices

Google and Apple continue using the existing handlers. Apple remains hidden on
unsupported platforms and unconfigured web builds. Verification, onboarding,
route guards, sessions, provider linking, and backend contracts are unchanged.
Names are collected in existing profile onboarding. Signup retains its current
confirmation field and 18+ consent sentence; legal links use the existing real
Privacy Policy URL. There is no published Terms route in the app to connect, so
no placeholder Terms link is shipped. Help explains the available account flows.

Appearance uses the existing persisted Light / Dark / System controller. Theme
changes and returning from the email form preserve drafts. The email field gets
focus on reveal, and returning to providers focuses the Email button. Large text
can wrap and scroll; the mobile header moves controls below the brand when
needed. Provider buttons retain the reference's 53/54px minimum height. Tabs,
small help/appearance controls, and caption targets have larger hit areas than
the source. Legal and footer text are slightly larger. Decorative card text
keeps its illustration scale, while functional text honors device scaling.

## Verification on 2026-11-07

- Bundled fonts have valid TrueType headers; the auth icon matches the reference
  byte for byte. Edited Dart files are formatted; `dart analyze lib/features/auth`
  and `dart analyze test/features/auth` passed. `git diff --check` passed.
- Added a widget matrix for provider/email login/signup in both appearances at
  320, 360, 390, 760, 768, 1200, 1440, and 2560px. Additional tests cover auth
  events, keyboard actions, draft preservation, errors, busy controls, existing
  consent and validation, platform availability, routes, System preference,
  manual captions, reduced motion, and password reset.
- Screenshot capture is opt-in with `AUTH_SCREENSHOTS=true`; the widget matrix
  writes provider/email images at 390×844, 1200×750, and 1440×900 to
  `app/build/artifacts/auth/`. No implementation screenshots were produced in
  this session: Flutter cannot open its SDK cache lockfile, and escalated test
  launches failed with a tool setup error. Visual comparison and widget tests
  remain unverified, as do real-device keyboard/OAuth/reset-email delivery.
- `make ci` passed Go formatting and vet, then failed in backend identity guard
  tests (`TestAuthAdminConfinement` and `TestAuthAdminConfinement_ClosedHoles`):
  their package loader found zero packages. Backend source was not changed.
  Race testing was unavailable with local CGO disabled.
- Buf checks and the CSP hash script could not execute installed `buf` and `jq`
  because of local permission errors. Go lint also failed to load packages, with
  an access-denied diagnostic resolving the backend working directory. No tools
  or package dependencies were installed.

After repairing local tool access, run `flutter analyze --no-pub`,
`flutter test --no-pub`, and `make ci`. To capture the comparison images:

```sh
cd app
flutter test --no-pub --dart-define=AUTH_SCREENSHOTS=true \
  test/features/auth/presentation/auth_screens_layout_test.dart
```

## CI regression correction

The initial GitHub run passed Flutter analysis, the other Flutter shards, Go
checks, and emulator integration tests. Flutter shard 1 exposed the following
issues, corrected without relaxing the tests or the central palette policy:

- Approved color values now live in `AppAuthPalette` in `app_theme.dart`.
- Platform overrides are restored within each test before Flutter verifies its
  global invariants.
- The email form has a stable key, preserving controller state when the welcome
  badge and provider choices are inserted or removed.
- Forms use natural-height scrolling instead of intrinsic form sizing. The email
  divider and password/reset row can wrap at enlarged text scales.
- Empty-password validation checks the field's error state, distinguishing it
  from the identically worded placeholder.

Static analysis, formatting, whitespace checks, and the existing color-policy
scan pass for this correction. Local runtime tests remain blocked by SDK cache
access; the updated PR runs the full CI suite again.
