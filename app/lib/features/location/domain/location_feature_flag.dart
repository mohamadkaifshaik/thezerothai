/// Server flag (`GetMe.enabled_features`) for the chosen-area feature
/// (Location P1). Per caller: with it off the picker and the consent screen
/// are gone, but a stored area can still be seen and cleared (a user can
/// always withdraw), through the settings read and the clear call that bypass
/// the service gate.
const kFeatureLocation = 'location';
