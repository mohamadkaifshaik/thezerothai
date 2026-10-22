# 0020. The UI colour system follows X's palette (dark and light); no brand gradient
Status: Proposed (the founder gave the decision on 2026-10-22; Accepted once the founder signs this ADR)
Date: 2026-10-22
Deciders: founder, architect

## Context
- 2026-10-21 (founder): an indigo seed colour (`#4263E8`, dark accent `#6A91FF`), a violet tertiary and a primary-to-tertiary gradient CTA
  (`AppGradientButton`), recorded in `app_theme.dart` and `app_theme_test.dart`.
- 2026-10-22 (founder): "don't keep indigo and gradient, match only X's colouring". A research pass on x.com (`docs/x_research/`,
  desktop and mobile, dark and light, measured from screenshots at a verified 1.25 display scale) produced the palette in
  `docs/x_research/10_light_dark_theme.md`.
- Only colours follow X. Logo, icons, copy, names, layout components and every asset stay our own; no Grok/Premium/ads surfaces are copied.

## Options
### A. Keep the indigo/gradient identity
Rejected by the founder.
### B. Adopt X's exact colours everywhere, including small accent text on white
`#1d9bf0` on white is 3.00:1: it fails WCAG 1.4.3 for small text (links, hashtags, "Show more").
### C. Adopt X's colours for fills, borders, icons and indicators; use a darker accent only for small text on light  *(chosen)*
- Dark: surface `#000000`, text `#e7e9ea`, secondary `#71767b`, hairline `#2f3336`, outline `#333639`, accent `#1d9bf0`.
- Light: surface `#ffffff`, text `#0f1419`, secondary `#536471`, hairline `#eff3f4`, outline `#cfd9de`, accent `#1d9bf0`; **accent text
  `#1478bd`** (4.72:1) for links, hashtags, mentions and text buttons.
- The strongest action is an inverse pill: `#eff3f4`/`#0f1419` in dark, `#0f1419`/`#ffffff` in light. State colours: like/live `#f91880`,
  repost `#00ba7c`, recommendation `#794bc4`.
- Raised dark steps `#080808 #141414 #1d1d1d #262626`; light `#fafafa #f7f9f9 #f2f2f2 #ebebeb`. Dark secondary text is below 4.5:1 on
  raised steps (4.37 down to 3.68), so text on a raised surface uses `secondaryOnRaised` (`#999999` dark).

## Cost impact
$0. Client-only change; no resource, package, asset or request is added.

## Decision
Option C. The palette lives only in `app/lib/core/theme/app_theme.dart` (`ColorScheme`, `AppColors` extension). `fromSeed`, the tertiary
slot and every gradient are removed; tests assert the exact hex values, the contrast pairs and that no gradient, seed or raw colour literal
exists in `lib/` outside the theme file. Disabled-pill and selected-row colours in the light theme were not observed on X and are
marked "to confirm" in the theme file.

## Consequences
- Positive: one coherent, familiar look; light and dark both specified and tested; no brand-colour maintenance.
- Negative: the brand identity of 2026-10-21 is gone; accent text on light is not X-exact (accessibility wins); X may change its colours.
- Existing widgets that used the primary-to-tertiary pair (`AppGradientButton`, the profile cover band) are replaced by a flat pill and
  a flat band.
- Follow-ups: confirm the light disabled/selected colours when captured; golden baselines on Linux CI; the accent-text choice (D1) may
  be revisited if the founder prefers X's exact blue.

## Handoff
frontend-developer (done in W0-1 of `docs/plans/ui-w0-foundations.md`) → tester (theme tests) → code-reviewer; founder to Accept.
