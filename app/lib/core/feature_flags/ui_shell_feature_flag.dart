/// Name of the app-shell flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_UI_SHELL`, decision D3 of
/// `docs/plans/ui-w0-foundations.md`). Client-only: no RPC is gated by it. On
/// means the new shell (bottom bar with an avatar drawer, account chip, X-style
/// rail); a missing name means off, the legacy four-item navigation. Never
/// hardcode `'ui_shell'` anywhere else.
const kFeatureUiShell = 'ui_shell';
