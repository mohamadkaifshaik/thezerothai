/// The location of the results screen (`/search?q=`) for a search box
/// text. [canonical] is `SearchQuery.canonical` (`@bob`, `#go`, `go`);
/// optional [tab] is `top|latest|people|media`. Kept here so the field
/// and the screen agree on the path without importing each other.
String searchResultsLocation(String canonical, {String? tab}) {
  final params = <String, String>{'q': canonical, 'tab': ?tab};
  return Uri(path: '/search', queryParameters: params).toString();
}
