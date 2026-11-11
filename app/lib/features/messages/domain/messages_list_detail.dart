import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';

/// Messages list–detail on the tablet layout from 840dp (band B; tablet plan
/// section 3, the LD families table): which folder the list pane shows
/// beside a shell page, and which conversation a thread location opens.
/// Pure Dart; no widgets.

const _messages = '/messages';
const _requests = '/messages/requests';
const _new = '/messages/new';
const _draft = '/messages/new/draft';

String _path(String location) {
  var path = Uri.tryParse(location)?.path ?? location;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// The folder of the list pane beside the shell page at [location]:
/// [Folder.FOLDER_INBOX] on `/messages`, [Folder.FOLDER_REQUESTS] on
/// `/messages/requests`, null anywhere else (a query or a trailing slash is
/// ignored).
Folder? messagesShellMasterFolder(String location) {
  return switch (_path(location)) {
    _messages => Folder.FOLDER_INBOX,
    _requests => Folder.FOLDER_REQUESTS,
    _ => null,
  };
}

/// Whether [location] is one of the two root thread routes that render the
/// split page in band B: `/messages/<id>` or `/messages/new/draft`.
bool isMessagesThreadLocation(String location) {
  final path = _path(location);
  if (path == _draft) return true;
  return messagesThreadIdOf(path) != null;
}

/// The conversation id of a `/messages/<id>` location, or null for the
/// inbox, the Requests folder, the picker, the draft and anything else.
String? messagesThreadIdOf(String location) {
  final path = _path(location);
  if (!path.startsWith('$_messages/')) return null;
  final rest = path.substring(_messages.length + 1);
  if (rest.isEmpty || rest.contains('/')) return null;
  if ('/messages/$rest' == _requests || '/messages/$rest' == _new) {
    return null;
  }
  return rest;
}

/// The master folder a thread route was opened with: the Requests rows pass
/// [Folder.FOLDER_REQUESTS] as the route `extra` (tablet plan section 5.3,
/// step 2); every other way in (inbox, notification, picker, deep link,
/// reload: no extra) shows the inbox.
Folder messagesSplitFolderOf(Object? extra) => extra == Folder.FOLDER_REQUESTS
    ? Folder.FOLDER_REQUESTS
    : Folder.FOLDER_INBOX;
