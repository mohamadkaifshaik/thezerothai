/// Name of the media flag (`FEATURE_MEDIA`) as exposed through
/// `GetMeResponse.enabled_features`; a missing name means off. It gates every
/// image entry point (the composer's attach button and the avatar editor),
/// mirroring the server, which gates MediaService, CreatePost `media_ids` and
/// UpdateProfile `avatar_media_id` with the same switch (P4 plan D3). Never
/// hardcode `'media'` anywhere else.
const kFeatureMedia = 'media';

/// Most images one post may carry (proto: 1-4 items per CreateUpload).
const kMaxPostImages = 4;

/// Longest alt text the server accepts per image (characters).
const kMaxAltTextLength = 1000;
