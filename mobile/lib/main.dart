import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const SvoyakApp());
}

class SvoyakApp extends StatelessWidget {
  const SvoyakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Svoyak MVP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const HomeScreen(),
    );
  }
}
