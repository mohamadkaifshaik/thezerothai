/// `GetMe.enabled_features` name of the server flag that makes every user id
/// on the wire an opaque public id (`u` + 26 lowercase base32 characters)
/// instead of the Firebase Auth uid. The app never branches its behaviour on
/// the value of an id; it only watches this flag flip, to drop caches that
/// hold ids of the other kind (`PublicIdTransition`).
const kFeaturePublicIds = 'public_ids';
