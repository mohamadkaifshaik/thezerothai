/// Name of the protected-accounts flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0025, `FEATURE_PRIVATE_ACCOUNTS`). A
/// missing name means off.
///
/// It gates only TURNING PROTECTION ON (the Settings "Protect your posts"
/// switch for a public account). Turning it off is never flag-gated (the undo
/// rule): the switch shows whenever the caller's profile is private. Never
/// hardcode `'private_accounts'` anywhere else.
const kFeaturePrivateAccounts = 'private_accounts';

/// The server's `metadata["quota"]` of the QUOTA_EXCEEDED answer to a fifth
/// protection change in one IST day (4 per day, both directions).
const kPrivacyTogglesQuotaName = 'privacy_toggles';

/// The server's `metadata["limit"]` of the LIMIT_REACHED answer to turning
/// protection on when the platform's cap on protected accounts is full.
const kPrivateAccountsLimitName = 'private_accounts';
