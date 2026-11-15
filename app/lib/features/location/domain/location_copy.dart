/// The version of the rationale text below. Sent with the consent; the server
/// refuses a grant older than its minimum (`required_copy_version`). Bump it
/// together with the text.
const kLocationConsentCopyVersion = 1;

const kLocationSettingsTitle = 'Location';
const kLocationExplainer =
    "Dzeroth stores only the area you choose. It never reads your phone's "
    'location.';
const kLocationChooseArea = 'Choose your area';
const kLocationChangeArea = 'Change area';
const kLocationClearArea = 'Clear my area';
const kLocationCleared = 'Location cleared';
const kLocationNotSet = 'Not set';
const kLocationOffTitle = 'Location is not available';
const kLocationOffBody = 'There is no area stored for your account.';
const kLocationOffStoredNote =
    'Location is switched off for now. Your stored area stays private to '
    'you, and you can clear it here.';

const kLocationRationaleTitle = 'Before you choose an area';
const kLocationRationaleStored =
    'What is stored: the one area you pick (a neighbourhood or a city), the '
    'time you agreed and the version of this text. No coordinates, no device '
    'location.';
const kLocationRationaleWhy =
    'Why: so plans in or near your area can be shown to you.';
const kLocationRationaleWho =
    'Who sees it: only you. A plan shows the area its organiser chose for '
    'the plan, never where you live.';
const kLocationRationaleWithdraw =
    'Withdraw any time: Settings > Location > Clear my area removes it at '
    'once.';
const kLocationAdultTick = 'I am 18 or older';
const kLocationContinue = 'Continue';

const kLocationPickerTitle = 'Choose your area';
const kLocationSearchHint = 'Search areas and cities';
const kLocationPickerEmptyTitle = 'No areas match';
const kLocationPickerEmptyBody = 'Try another spelling or a nearby city.';

const kExploreSettingsTitle = 'Explore settings';
const kExploreSettingsNearbyGroup = 'Nearby';
const kExploreSettingsAreaRow = 'Your area';

/// "All of [city]" row of the picker.
String locationAllOf(String city) => 'All of $city';
