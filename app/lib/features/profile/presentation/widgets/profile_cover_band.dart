import 'package:flutter/material.dart';

/// The band behind the avatar on the profile header and on Edit profile: a
/// flat theme surface (profiles carry no banner picture). It is decoration,
/// hidden from assistive technology, and sized by its parent.
class ProfileCoverBand extends StatelessWidget {
  const ProfileCoverBand({super.key});

  /// The band's shape on the profile and on Edit profile (width : height).
  static const double aspect = 3;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
    ),
  );
}
