import 'package:flutter/material.dart';

class AppPalette {
  static const Color background = Color(0xFF060B1A);
  static const Color panel = Color(0xCC101A3A);
  static const Color panelStrong = Color(0xFF16244D);
  static const Color primary = Color(0xFF4A7BFF);
  static const Color accent = Color(0xFF27D5FF);
  static const Color success = Color(0xFF35D39A);
  static const Color warning = Color(0xFFFFC543);
  static const Color danger = Color(0xFFFF5E7E);
  static const Color textPrimary = Color(0xFFF3F6FF);
  static const Color textMuted = Color(0xFF9AA8D3);
  static const Color border = Color(0x33FFFFFF);
}

class AppTheme {
  static ThemeData get theme {
    final ThemeData base = ThemeData.dark(useMaterial3: true);

    final TextTheme textTheme = base.textTheme.apply(
      bodyColor: AppPalette.textPrimary,
      displayColor: AppPalette.textPrimary,
      fontFamily: 'Avenir Next',
    );

    return base.copyWith(
      colorScheme: const ColorScheme.dark(
        primary: AppPalette.primary,
        secondary: AppPalette.accent,
        surface: AppPalette.panel,
        error: AppPalette.danger,
      ),
      scaffoldBackgroundColor: AppPalette.background,
      textTheme: textTheme,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x33263F8C),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: textTheme.bodyMedium?.copyWith(color: AppPalette.textMuted),
        labelStyle: textTheme.bodyMedium?.copyWith(color: AppPalette.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppPalette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppPalette.accent, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppPalette.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle:
              textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppPalette.textPrimary,
          side: const BorderSide(color: AppPalette.border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle:
              textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: const BorderSide(color: AppPalette.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle:
            textTheme.labelMedium?.copyWith(color: AppPalette.textPrimary),
      ),
    );
  }
}
