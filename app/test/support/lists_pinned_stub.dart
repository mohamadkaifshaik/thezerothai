import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockHomeTabs extends Mock implements HomeTabsRepository {}

/// A [HomeTabsRepository] with no Home tabs and no changes, for the pages
/// that only read the pinned Lists from it.
HomeTabsRepository noPinnedTabs() {
  final tabs = _MockHomeTabs();
  when(() => tabs.tabs).thenReturn(const []);
  when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
  return tabs;
}
