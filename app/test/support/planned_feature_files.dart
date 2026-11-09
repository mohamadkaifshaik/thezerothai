import 'dart:io';

/// Files covered by the coming-soon features' no-network/no-auto-popup guards.
/// Include shared navigation and flag code as well as each feature's files.
List<File> plannedFeatureFiles() => [
  File('lib/core/router/shell_entries.dart'),
  File('lib/core/feature_flags/shells_feature_flag.dart'),
  for (final feature in ['advertise', 'calls', 'creator_studio', 'premium'])
    ...Directory('lib/features/$feature')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart')),
];
