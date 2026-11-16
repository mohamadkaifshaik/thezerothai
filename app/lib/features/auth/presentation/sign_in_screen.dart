import 'package:material_ui/material_ui.dart';

import 'auth_screen.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context) => const AuthScreen(signUp: false);
}
