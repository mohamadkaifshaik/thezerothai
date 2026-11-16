import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Tooltip;

/// `find.byTooltip` for tooltips built by `material_ui`.
///
/// flutter_test's `byTooltip` looks for the framework's own `Tooltip` class
/// when a tooltip has `excludeFromSemantics: true` (the app's nav rail, bottom
/// bar, action bar, post menu and the beacon pickers). `material_ui` ships its
/// own `Tooltip`, which that finder does not see, so these look it up directly.
extension UiTooltipFinder on CommonFinders {
  Finder byUiTooltip(Pattern message, {bool skipOffstage = true}) {
    return byWidgetPredicate(
      (widget) {
        if (widget is! Tooltip) return false;
        final text = widget.message ?? widget.richMessage?.toPlainText();
        if (text == null) return false;
        return message is RegExp ? message.hasMatch(text) : text == message;
      },
      skipOffstage: skipOffstage,
      description: 'tooltip $message',
    );
  }
}
