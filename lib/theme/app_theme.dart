import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.tealPrimary,
        primary: AppColors.tealPrimary,
        secondary: AppColors.navyDark,
        error: AppColors.redAlert,
        surface: AppColors.cardWhite,
      ),
      scaffoldBackgroundColor: AppColors.bgLight,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: const TextStyle(
            fontWeight: FontWeight.w800, fontSize: 30, color: AppColors.navyDark),
        headlineMedium: const TextStyle(
            fontWeight: FontWeight.w700, fontSize: 24, color: AppColors.navyDark),
        titleLarge: const TextStyle(
            fontWeight: FontWeight.w700, fontSize: 20, color: AppColors.navyDark),
        titleMedium: const TextStyle(
            fontWeight: FontWeight.w600, fontSize: 16, color: AppColors.navyDark),
        bodyLarge: const TextStyle(
            fontWeight: FontWeight.w400, fontSize: 16, color: AppColors.navyDark),
        bodyMedium: const TextStyle(
            fontWeight: FontWeight.w400, fontSize: 14, color: AppColors.textMuted),
        labelLarge: const TextStyle(
            fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.navyDark),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.cardWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.tealPrimary, width: 1.4),
        ),
        labelStyle: const TextStyle(color: AppColors.navyDark, fontWeight: FontWeight.w600),
        hintStyle: const TextStyle(color: AppColors.textMuted),
      ),
      cardTheme: CardThemeData(
        color: AppColors.cardWhite,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.tealPrimary
              : AppColors.divider,
        ),
      ),
    );
  }
}
