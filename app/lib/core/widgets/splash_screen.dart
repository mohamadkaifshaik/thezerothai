import 'package:flutter/material.dart';

/// Shown for the brief moment before Firebase reports whether anyone is
/// signed in. Never a permanent screen — see `AppRouter`'s redirect.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
