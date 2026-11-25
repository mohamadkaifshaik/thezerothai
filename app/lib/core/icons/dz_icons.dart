import 'dart:ui';

import 'dz_icon_data.dart';

/// The design canvas's icons, copied from the artboards' inline `<svg
/// viewBox="0 0 24 24">` elements (path data, circles and rects unchanged).
/// Stroke width, cap and join are the artboard's own. Draw one with `DzIcon`.
abstract final class DzIcons {
  // ---- Post actions (DzHome, DzPost, DzThread, ZPhotoViewer) ----

  static const reply = DzIconData([
    DzPathShape('M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z'),
  ], strokeWidth: 1.9);

  static const repost = DzIconData(
    [
      DzPathShape(
        'M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3',
      ),
    ],
    strokeWidth: 1.9,
    cap: StrokeCap.round,
  );

  static const like = DzIconData([
    DzPathShape(
      'M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z',
    ),
  ], strokeWidth: 1.9);

  /// Bookmark.
  static const save = DzIconData([
    DzPathShape('M6 3h12v18l-6-4-6 4z'),
  ], strokeWidth: 1.9);

  static const share = DzIconData(
    [
      DzPathShape(
        'M12 3v12M7 8l5-5 5 5M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5',
      ),
    ],
    strokeWidth: 1.9,
    cap: StrokeCap.round,
  );

  // ---- Bottom bar ----

  static const home = DzIconData([
    DzPathShape('M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z'),
  ], strokeWidth: 1.8);

  static const search = DzIconData([
    DzCircleShape(11, 11, 7),
    DzPathShape('M20 20l-3.5-3.5'),
  ], cap: StrokeCap.round);

  /// The Plans target: two rings and a filled dot.
  static const plans = DzIconData([
    DzCircleShape(12, 12, 9),
    DzCircleShape(12, 12, 4.5),
    DzCircleShape(12, 12, 1, filled: true),
  ]);

  static const bell = DzIconData([
    DzPathShape(
      'M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0',
    ),
  ], cap: StrokeCap.round);

  static const bellOff = DzIconData([
    DzPathShape(
      'M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0M3 3l18 18',
    ),
  ], cap: StrokeCap.round);

  static const mail = DzIconData([
    DzRectShape(3, 5, 18, 14, rx: 2),
    DzPathShape('M3 7l9 6 9-6'),
  ]);

  // ---- Navigation and controls ----

  /// Back chevron.
  static const back = DzIconData([
    DzPathShape('M15 6l-6 6 6 6'),
  ], cap: StrokeCap.round);

  static const chevronRight = DzIconData([
    DzPathShape('M9 6l6 6-6 6'),
  ], cap: StrokeCap.round);

  static const chevronDown = DzIconData([
    DzPathShape('M6 9l6 6 6-6'),
  ], cap: StrokeCap.round);

  static const chevronUp = DzIconData([
    DzPathShape('M6 15l6-6 6 6'),
  ], cap: StrokeCap.round);

  static const arrowRight = DzIconData([
    DzPathShape('M5 12h14M13 6l6 6-6 6'),
  ], cap: StrokeCap.round);

  /// Three filled dots (post and row menus).
  static const more = DzIconData([
    DzCircleShape(5, 12, 1.8, filled: true, stroked: false),
    DzCircleShape(12, 12, 1.8, filled: true, stroked: false),
    DzCircleShape(19, 12, 1.8, filled: true, stroked: false),
  ]);

  /// Three dots drawn as zero-length round strokes.
  static const moreStroke = DzIconData(
    [DzPathShape('M5 12h.01M12 12h.01M19 12h.01')],
    strokeWidth: 3.6,
    cap: StrokeCap.round,
  );

  static const close = DzIconData([
    DzPathShape('M6 6l12 12M18 6L6 18'),
  ], cap: StrokeCap.round);

  static const plus = DzIconData([
    DzPathShape('M12 5v14M5 12h14'),
  ], cap: StrokeCap.round);

  static const check = DzIconData(
    [DzPathShape('M5 12l5 5 9-10')],
    strokeWidth: 2.2,
    cap: StrokeCap.round,
  );

  /// Compose (pencil), on the FAB.
  static const compose = DzIconData(
    [DzPathShape('M4 20h4L19 9l-4-4L4 16z'), DzPathShape('M13 7l4 4')],
    strokeWidth: 2.2,
    cap: StrokeCap.round,
  );

  /// "For you" four-point mark in the Home bar.
  static const forYou = DzIconData([
    DzPathShape('M12 3v5M12 16v5M3 12h5M16 12h5'),
  ], cap: StrokeCap.round);

  static const gear = DzIconData([
    DzCircleShape(12, 12, 3),
    DzPathShape(
      'M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
    ),
  ]);

  // ---- Objects ----

  static const calendar = DzIconData([
    DzRectShape(3, 5, 18, 16, rx: 2),
    DzPathShape('M3 10h18M8 3v4M16 3v4'),
  ]);

  static const calendarCheck = DzIconData([
    DzRectShape(3, 5, 18, 16, rx: 2),
    DzPathShape('M3 10h18M8 3v4M16 3v4M9 15l2 2 4-4'),
  ]);

  static const clock = DzIconData([
    DzCircleShape(12, 12, 9),
    DzPathShape('M12 7v5l3 2'),
  ], cap: StrokeCap.round);

  /// Map pin (place).
  static const mapPin = DzIconData([
    DzPathShape('M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12z'),
    DzCircleShape(12, 9, 2.5),
  ]);

  /// Push pin (pinned post).
  static const pin = DzIconData([
    DzPathShape('M9 3h6l-1 6 4 3v2H6v-2l4-3zM12 14v7'),
  ], cap: StrokeCap.round);

  static const link = DzIconData([
    DzPathShape(
      'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    ),
  ], cap: StrokeCap.round);

  static const lock = DzIconData([
    DzPathShape('M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4'),
  ], cap: StrokeCap.round);

  static const camera = DzIconData([
    DzPathShape('M4 8h3l2-3h6l2 3h3v11H4z'),
    DzCircleShape(12, 13, 3.5),
  ]);

  static const image = DzIconData([
    DzRectShape(3, 4, 18, 16, rx: 3),
    DzCircleShape(9, 10, 1.8),
    DzPathShape('M21 16l-5-5-9 9'),
  ], cap: StrokeCap.round);

  static const person = DzIconData([
    DzCircleShape(12, 8, 4),
    DzPathShape('M4 21a8 8 0 0 1 16 0'),
  ]);

  static const personAdd = DzIconData([
    DzCircleShape(9, 8, 3.5),
    DzPathShape('M2 20a7 7 0 0 1 14 0M18 8v6M15 11h6'),
  ], cap: StrokeCap.round);

  static const trash = DzIconData([
    DzPathShape('M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3'),
  ], cap: StrokeCap.round);

  static const sliders = DzIconData([
    DzPathShape('M4 7h10M18 7h2M4 17h4M12 17h8'),
    DzCircleShape(16, 7, 2),
    DzCircleShape(10, 17, 2),
  ], cap: StrokeCap.round);

  static const download = DzIconData([
    DzPathShape('M12 3v12M7 10l5 5 5-5M5 21h14'),
  ], cap: StrokeCap.round);

  static const eye = DzIconData([
    DzPathShape('M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z'),
    DzCircleShape(12, 12, 3),
  ]);

  static const shield = DzIconData([
    DzPathShape('M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z'),
  ]);

  static const warning = DzIconData([
    DzPathShape(
      'M12 9v4M12 17h.01M10.3 3.9L2 18a2 2 0 0 0 1.7 3h16.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
    ),
  ], cap: StrokeCap.round);

  static const info = DzIconData([
    DzCircleShape(12, 12, 9),
    DzPathShape('M12 11v5M12 8h.01'),
  ], cap: StrokeCap.round);

  static const mute = DzIconData([
    DzPathShape('M11 5L6 9H3v6h3l5 4zM22 9l-6 6M16 9l6 6'),
  ], cap: StrokeCap.round);

  static const at = DzIconData([
    DzCircleShape(12, 12, 4),
    DzPathShape('M16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1'),
  ], cap: StrokeCap.round);

  static const hash = DzIconData([
    DzPathShape('M5 9h15M4 15h15M10 3L8 21M16 3l-2 18'),
  ], cap: StrokeCap.round);

  static const list = DzIconData([
    DzPathShape('M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01'),
  ], cap: StrokeCap.round);

  static const document = DzIconData([
    DzPathShape('M5 3h10l4 4v14H5zM15 3v4h4'),
  ]);

  static const video = DzIconData([
    DzRectShape(3, 6, 13, 12, rx: 2),
    DzPathShape('M16 10l5-3v10l-5-3z'),
  ]);

  static const play = DzIconData([DzPathShape('M8 5l11 7-11 7z')]);

  static const pause = DzIconData([
    DzRectShape(6, 5, 4, 14, rx: 1),
    DzRectShape(14, 5, 4, 14, rx: 1),
  ]);

  /// Six dots (drag handle).
  static const grip = DzIconData([
    DzCircleShape(9, 6, 1.6),
    DzCircleShape(15, 6, 1.6),
    DzCircleShape(9, 12, 1.6),
    DzCircleShape(15, 12, 1.6),
    DzCircleShape(9, 18, 1.6),
    DzCircleShape(15, 18, 1.6),
  ]);

  /// Every icon, by name (used by the catalogue test).
  static const Map<String, DzIconData> all = {
    'reply': reply,
    'repost': repost,
    'like': like,
    'save': save,
    'share': share,
    'home': home,
    'search': search,
    'plans': plans,
    'bell': bell,
    'bellOff': bellOff,
    'mail': mail,
    'back': back,
    'chevronRight': chevronRight,
    'chevronDown': chevronDown,
    'chevronUp': chevronUp,
    'arrowRight': arrowRight,
    'more': more,
    'moreStroke': moreStroke,
    'close': close,
    'plus': plus,
    'check': check,
    'compose': compose,
    'forYou': forYou,
    'gear': gear,
    'calendar': calendar,
    'calendarCheck': calendarCheck,
    'clock': clock,
    'mapPin': mapPin,
    'pin': pin,
    'link': link,
    'lock': lock,
    'camera': camera,
    'image': image,
    'person': person,
    'personAdd': personAdd,
    'trash': trash,
    'sliders': sliders,
    'download': download,
    'eye': eye,
    'shield': shield,
    'warning': warning,
    'info': info,
    'mute': mute,
    'at': at,
    'hash': hash,
    'list': list,
    'document': document,
    'video': video,
    'play': play,
    'pause': pause,
    'grip': grip,
  };
}
