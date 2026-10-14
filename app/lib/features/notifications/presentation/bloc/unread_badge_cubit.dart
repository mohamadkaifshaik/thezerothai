import 'package:flutter_bloc/flutter_bloc.dart';

/// The server caps the unread count at 100 (ADR-0017); show "99+" from there.
const kUnreadBadgeCap = 99;

/// Text of the badge for [count] ("3", "99+"); empty for none.
String unreadBadgeLabel(int count) {
  if (count <= 0) return '';
  return count > kUnreadBadgeCap ? '$kUnreadBadgeCap+' : '$count';
}

/// App-wide unread notification count behind the navigation badge.
///
/// - Seeded from `GetMe.unread_notification_count` (0 extra reads): the
///   caller feeds [seed] from the onboarding flow on every fresh GetMe.
/// - Moves locally afterwards: [increment] for a foreground push, [clear]
///   once the list marked everything seen. It never calls the API itself
///   (no GetMe or ListNotifications just for a badge).
/// - Provided by `AppWidget`; reset on sign-out.
class UnreadBadgeCubit extends Cubit<int> {
  UnreadBadgeCubit([super.initial = 0]);

  void seed(int count) {
    if (isClosed) return;
    emit(count < 0 ? 0 : count);
  }

  void increment() {
    if (isClosed) return;
    emit(state + 1);
  }

  void clear() {
    if (isClosed || state == 0) return;
    emit(0);
  }
}
