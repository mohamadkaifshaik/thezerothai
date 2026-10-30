/// The location of the results screen (`/search?q=`, W4-15) for a search box
/// text. [canonical] is `SearchQuery.canonical` (`@bob`, `#go`, `go`);
/// optional [tab] is `top|latest|people|media`. Kept here so the field (W4-14)
/// and the screen (W4-15) agree on the path without importing each other.
String searchResultsLocation(String canonical, {String? tab}) {
  final params = <String, String>{'q': canonical, 'tab': ?tab};
  return Uri(path: '/search', queryParameters: params).toString();
}
