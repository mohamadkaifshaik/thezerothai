/// Name of the account-lifecycle flag (delete account + data export) as
/// exposed through `GetMeResponse.enabled_features`. A missing name means
/// off. Never hardcode `'account_lifecycle'` anywhere else.
const kFeatureAccountLifecycle = 'account_lifecycle';

/// Name of the flag that offers the data export as one ZIP archive
/// (`export_zip`). Off means the JSON object only.
const kFeatureExportZip = 'export_zip';
