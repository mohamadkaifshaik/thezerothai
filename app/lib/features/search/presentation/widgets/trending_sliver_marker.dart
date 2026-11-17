import 'package:material_ui/material_ui.dart';

/// A zero-height sliver that reports where it starts in the scroll view's
/// offset terms (the extent of every sliver before it). The Trending tab puts
/// one at the end of its header to know where the lists begin.
class TrendingSliverMarker extends StatelessWidget {
  const TrendingSliverMarker({super.key, required this.onOffset});

  final ValueChanged<double> onOffset;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      onOffset(constraints.precedingScrollExtent);
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    },
  );
}
