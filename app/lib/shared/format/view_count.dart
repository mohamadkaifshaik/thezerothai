import 'package:intl/intl.dart';

/// The compact count used beside every action ("1.2K"), as likes and replies.
String formatCompactCount(int count) => NumberFormat.compact().format(count);

/// What a screen reader says for a view count: "1.2K views", "1 view".
String viewsSemanticsLabel(int count) =>
    '${formatCompactCount(count)} ${count == 1 ? 'view' : 'views'}';
