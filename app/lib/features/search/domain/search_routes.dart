import 'search_query.dart';

/// The hashtag (no `#`, normalised) a link's `?tag=` names, or null when it
/// is missing or not one hashtag under the post grammar.
String? exploreTagOfLink(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return SearchQuery.parse('#$raw').tagBody;
}

/// The location of Explore's Trending tab filtered to [tag] (no `#`).
String exploreTagLocation(String tag) =>
    Uri(path: '/explore', queryParameters: {'tag': tag}).toString();

/// The location of the results screen (`/search?q=`) for a search box
/// text. [canonical] is `SearchQuery.canonical` (`@bob`, `#go`, `go`);
/// optional [tab] is `top|latest|people|media`. Kept here so the field
/// and the screen agree on the path without importing each other.
String searchResultsLocation(String canonical, {String? tab}) {
  final params = <String, String>{'q': canonical, 'tab': ?tab};
  return Uri(path: '/search', queryParameters: params).toString();
}
