import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'auth_design.dart';

/// Illustrative plans, drawn as native widgets rather than live location data.
class AuthBrandScene extends StatefulWidget {
  const AuthBrandScene({
    super.key,
    required this.viewportWidth,
    this.enlargedText = false,
  });
  final double viewportWidth;
  final bool enlargedText;

  @override
  State<AuthBrandScene> createState() => _AuthBrandSceneState();
}

class _AuthBrandSceneState extends State<AuthBrandScene>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );
  int _caption = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _motion.value = 0;
    } else {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.viewportWidth <= 1100;
    final large = widget.viewportWidth >= 1600;
    final width = math.min(widget.viewportWidth, 1800.0) / 2;
    final inset = width * (large ? .09 : (compact ? .07 : .073));
    final size = compact
        ? 43.0
        : (widget.viewportWidth * .0405).clamp(38.0, 66.0).toDouble();
    final captions = [
      ('Your plans\ndeserve ', 'company.'),
      ('Dzeroth.\n', '“What’s your plan?”'),
      ('Less scrolling.\n', 'More connecting.'),
      ('DZEROTH\n', '“Start something\nnearby.”'),
    ];
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(28)),
      child: ColoredBox(
        color: AuthDesign.navy,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 820),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              inset,
              compact ? 36 : 44,
              inset,
              compact ? 28 : 34,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AuthBrand(),
                SizedBox(height: large ? 90 : (compact ? 68 : 74)),
                Row(
                  children: [
                    const _Dot(),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'GOOD THINGS START WITH A PLAN',
                        style: AuthDesign.body(
                          compact ? 8 : 10,
                          weight: 500,
                          color: const Color(0xFFBEC8C7),
                        ).copyWith(letterSpacing: compact ? 1.3 : 1.8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 25),
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: compact ? 100 : 148),
                  child: Semantics(
                    header: true,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: captions[_caption].$1),
                          TextSpan(
                            text: captions[_caption].$2,
                            style: const TextStyle(color: AuthDesign.mint),
                          ),
                        ],
                      ),
                      style:
                          AuthDesign.heading(
                            size,
                            weight: 500,
                            color: Colors.white,
                          ).copyWith(
                            height: 1.12,
                            letterSpacing: compact ? -2 : -2.6,
                          ),
                    ),
                  ),
                ),
                const SizedBox(height: 21),
                Text(
                  'Find your people. Make a plan.\nTake it into the real world.',
                  style: AuthDesign.body(
                    14,
                    color: const Color(0xFFA4ACBA),
                  ).copyWith(height: 1.8),
                ),
                Expanded(
                  child: Center(
                    child: ExcludeSemantics(
                      child: SizedBox(
                        height: large ? 440 : 310,
                        width: double.infinity,
                        child: MediaQuery.withClampedTextScaling(
                          minScaleFactor: 1,
                          maxScaleFactor: 1,
                          child: AnimatedBuilder(
                            animation: _motion,
                            builder: (context, _) => _Universe(
                              compact: compact,
                              enlargedText: widget.enlargedText,
                              phase: _motion.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 4; i++)
                          Semantics(
                            selected: _caption == i,
                            child: TextButton(
                              onPressed: () => setState(() => _caption = i),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(32, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                              ),
                              child: Tooltip(
                                message: '${captions[i].$1}${captions[i].$2}'
                                    .replaceAll('\n', ' '),
                                child: Container(
                                  width: _caption == i ? 24 : 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: _caption == i
                                        ? AuthDesign.mint
                                        : const Color(0x4DFFFFFF),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      'Less scrolling. More connecting.  ↗',
                      style: AuthDesign.body(
                        compact ? 8 : 9,
                        color: const Color(0xFFA9B4BD),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Universe extends StatelessWidget {
  const _Universe({
    required this.compact,
    required this.enlargedText,
    required this.phase,
  });
  final bool compact;
  final bool enlargedText;
  final double phase;

  @override
  Widget build(BuildContext context) {
    final drift = (1 - math.cos(phase * 2 * math.pi)) / 2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(child: CustomPaint(painter: _OrbitPainter())),
        Align(
          child: Transform.rotate(
            angle: -8 * math.pi / 180,
            child: Container(
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(27),
                border: Border.all(color: const Color(0x33FFFFFF)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x80030814),
                    blurRadius: 60,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(AuthDesign.icon),
            ),
          ),
        ),
        const Positioned(
          right: 20,
          top: 40,
          child: Text(
            '✦',
            style: TextStyle(fontSize: 28, color: AuthDesign.mint),
          ),
        ),
        const Positioned(
          left: 15,
          bottom: 42,
          child: Text(
            '✧',
            style: TextStyle(fontSize: 25, color: AuthDesign.mint),
          ),
        ),
        Positioned(
          right: 0,
          top: 112,
          child: Transform.rotate(
            angle: 8 * math.pi / 180,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0x12FFFFFF)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'A small plan. A great story.',
                style: AuthDesign.body(9, color: const Color(0xFFA2AFAC)),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 43 - 7 * drift,
          child: Transform.rotate(
            angle: (-5 + 2 * drift) * math.pi / 180,
            child: _PlanCard(coffee: true, compact: compact),
          ),
        ),
        Positioned(
          right: compact ? -12 : -14,
          bottom: 77 + 7 * math.sin((phase + .43) * 2 * math.pi),
          child: Transform.rotate(
            angle: (5 - 2 * drift) * math.pi / 180,
            child: _PlanCard(coffee: false, compact: compact),
          ),
        ),
        Positioned(
          bottom: 12,
          left: compact ? 12 : 65,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Dot(),
              const SizedBox(width: 9),
              Text(
                'Your next “glad I went” is nearby.',
                style: AuthDesign.body(
                  compact ? 8 : 10,
                  color: const Color(0xFFA9B4BD),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.coffee, required this.compact});
  final bool coffee;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(compact ? 12 : 15),
    decoration: BoxDecoration(
      color: const Color(0xFF263042),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x12FFFFFF)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x30060B17),
          blurRadius: 30,
          offset: Offset(0, 14),
        ),
      ],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 33 : 41,
          height: compact ? 36 : 43,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: coffee ? const Color(0xFFFAF7EA) : const Color(0xFFDDF0DA),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            coffee ? '☕' : '🏸',
            style: TextStyle(fontSize: compact ? 20 : 23),
          ),
        ),
        SizedBox(width: compact ? 8 : 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              coffee ? 'Coffee & a good conversation' : 'One more for doubles?',
              style: AuthDesign.body(
                compact ? 9 : 11,
                weight: 550,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              coffee
                  ? 'Today, 5:30 PM · 0.8 km away'
                  : 'Today, 6:00 PM · 1.2 km away',
              style: AuthDesign.body(
                compact ? 8 : 9,
                color: const Color(0xFFAEB8C7),
              ),
            ),
          ],
        ),
        if (!compact) ...[
          const SizedBox(width: 12),
          if (coffee)
            SizedBox(
              width: 54,
              height: 23,
              child: Stack(
                children: [
                  for (var i = 0; i < 3; i++)
                    Positioned(
                      left: i * 15,
                      child: Container(
                        width: 23,
                        height: 23,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: [
                            const Color(0xFFC8AFA2),
                            const Color(0xFFC6D0B1),
                            const Color(0xFF465267),
                          ][i],
                          border: Border.all(
                            color: const Color(0xFF263042),
                            width: 2,
                          ),
                        ),
                        child: Text(
                          ['R', 'A', '+2'][i],
                          style: AuthDesign.body(
                            8,
                            weight: 600,
                            color: i == 2 ? Colors.white : AuthDesign.ink,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: AuthDesign.mint,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                "I'm in ↗",
                style: AuthDesign.body(9, weight: 600, color: AuthDesign.ink),
              ),
            ),
        ],
      ],
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: AuthDesign.mint,
    ),
  );
}

class _OrbitPainter extends CustomPainter {
  const _OrbitPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * .51);
    final ring = Paint()
      ..color = const Color(0x09FFFFFF)
      ..style = PaintingStyle.stroke;
    for (final diameter in [250.0, 380.0, 510.0]) {
      canvas.drawCircle(center, diameter / 2, ring);
    }
    final dot = Paint()..color = AuthDesign.mint.withValues(alpha: .4);
    canvas.drawCircle(Offset(size.width * .3, size.height * .25), 2.5, dot);
    canvas.drawCircle(Offset(size.width * .76, size.height * .74), 2.5, dot);
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => false;
}
