/// Client-side switch for every quote CREATION entry point (the repost
/// sheet's "Quote" row and the `/compose?quote=<id>` composer). Founder
/// decision 2026-10-18: quote UI is later, not MVP. The server derives the
/// `quotes` sub-feature from FEATURE_ENGAGEMENT, so ramping engagement would
/// otherwise expose it; this keeps it hidden regardless.
///
/// Rendering existing QUOTE posts and embeds is NOT gated: only creation is.
/// Flip with `--dart-define=QUOTE_UI=true` (or change the default) when the
/// quote UI ships. Widgets take a `quoteUiEnabled` parameter defaulting to
/// this so tests can inject either value.
const bool kQuoteUiEnabled = bool.fromEnvironment(
  'QUOTE_UI',
  defaultValue: false,
);
