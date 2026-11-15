/// The tabs of Explore. Trending is always there; Nearby shows with `location`
/// and `beacons`, Plans and People while the flag of the RPC behind each is on.
enum ExploreTab {
  trending('Trending'),
  nearby('Nearby'),
  plans('Plans'),
  people('People');

  const ExploreTab(this.label);

  final String label;
}

/// The tabs Explore shows, in order. Trending is always the first (with
/// `trends` off it holds only what its flags allow, as before). One tab means
/// no tab bar ([showsExploreTabBar] false): Explore's page as it was.
List<ExploreTab> exploreTabsFor({
  required bool plans,
  required bool people,
  bool nearby = false,
}) =>
    [
      ExploreTab.trending,
      if (nearby) ExploreTab.nearby,
      if (plans) ExploreTab.plans,
      if (people) ExploreTab.people,
    ];

/// Whether the tab bar shows: more than Trending is on.
bool showsExploreTabBar(List<ExploreTab> tabs) => tabs.length > 1;

/// [selected] when it is still offered, else Trending (a flag turned off
/// while its tab was open).
ExploreTab resolveExploreTab(ExploreTab selected, List<ExploreTab> tabs) =>
    tabs.contains(selected) ? selected : ExploreTab.trending;
