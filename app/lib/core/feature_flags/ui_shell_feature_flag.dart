/// Name of the app-shell flag as exposed through
/// `GetMeResponse.enabled_features` (`FEATURE_UI_SHELL`, decision D3 of
/// W0 plan). Client-only: no RPC is gated by it. On
/// means the new shell (bottom bar with an avatar drawer, account chip, X-style
/// rail); a missing name means off, the legacy four-item navigation. Never
/// hardcode `'ui_shell'` anywhere else.
const kFeatureUiShell = 'ui_shell';

/// Name of the tablet-layout flag in `GetMeResponse.enabled_features`
/// (`FEATURE_UI_TABLET`, tablet plan section 2.3). Client-only: no RPC is
/// gated by it. It takes effect only together with [kFeatureUiShell]: both on
/// gives the 600-1199 dp tablet shell (the pinned `AppNavRail`, per-pane safe
/// areas); either off keeps today's 600-1199 dp layout. Phones (< 600 dp) and
/// desktop (>= 1200 dp) never change with it. Never hardcode `'ui_tablet'`
/// anywhere else.
const kFeatureUiTablet = 'ui_tablet';
