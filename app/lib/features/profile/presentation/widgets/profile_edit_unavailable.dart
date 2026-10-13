import 'package:flutter/material.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/widgets/app_error_view.dart';

/// Edit profile / Change handle opened without a signed-in profile (the
/// router's redirects normally prevent it): a friendly message rather than a
/// blank page.
class ProfileEditUnavailable extends StatelessWidget {
  const ProfileEditUnavailable({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const AppErrorView(
        error: UnknownApiException("Your profile isn't available right now."),
      ),
    );
  }
}
