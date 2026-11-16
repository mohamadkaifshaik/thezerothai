import 'package:material_ui/material_ui.dart';

import 'auth_screen.dart';

class SignUpScreen extends StatelessWidget {
  const SignUpScreen({super.key});

  @override
  Widget build(BuildContext context) => const AuthScreen(signUp: true);
}
