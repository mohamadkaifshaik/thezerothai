/// "5 days", "1 day", "3 hours", "20 minutes": a coarse, human wait for
/// cooldown and quota messages. Always rounds up (computed from whole minutes,
/// so 1 day 59 minutes reads "2 days"), so the user is never told a shorter
/// wait than the real one, and never "0 minutes".
String coarseWait(Duration wait) {
  final minutes = wait.inMinutes;
  if (minutes >= 1440) {
    final days = (minutes / 1440).ceil();
    return days == 1 ? '1 day' : '$days days';
  }
  if (minutes >= 60) {
    final hours = (minutes / 60).ceil();
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  final shown = minutes < 1 ? 1 : minutes;
  return shown == 1 ? '1 minute' : '$shown minutes';
}
