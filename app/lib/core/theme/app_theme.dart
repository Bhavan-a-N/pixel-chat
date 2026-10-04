import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // Primary: blush pink
  static const Color primary = Color(0xFFF4B8C8);
  static const Color onPrimary = Color(0xFF2B2D42);
  
  // Secondary: soft lavender
  static const Color secondary = Color(0xFFD6C8FF);
  static const Color onSecondary = Color(0xFF2B2D42);

  // Surface: white / very light
  static const Color surface = Color(0xFFFFFFFF);
  static const Color onSurface = Color(0xFF2B2D42);
  
  // Background: warm cream/off-white
  static const Color background = Color(0xFFFFF9F2);
  static const Color onBackground = Color(0xFF2B2D42);

  // Containers
  static const Color primaryContainer = Color(0xFFFFE3EE);
  static const Color onPrimaryContainer = Color(0xFF2B2D42);
  
  // Bubbles for others: lavender-tinted white
  static const Color surfaceVariant = Color(0xFFF4F0FF); 
  static const Color onSurfaceVariant = Color(0xFF2B2D42);

  static const Color outline = Color(0xFFB5ACB8);
  static const Color outlineVariant = Color(0xFFE2DCE4);

  static const Color error = Color(0xFFE5989B);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color errorContainer = Color(0xFFFFD6D6);
  static const Color onErrorContainer = Color(0xFF4A0000);

  static const Color success = Color(0xFFA3D9B1);
  static const Color onSuccess = Color(0xFF2B2D42);

  // Tertiary accents strictly for critters/rings as requested
  static const Color butterYellow = Color(0xFFFDE68A);
  static const Color mintGreen = Color(0xFFA7F3D0);
  static const Color skyBlue = Color(0xFFBAE6FD);
}

class AppSpacing {
  const AppSpacing._();
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 16.0;
  static const double lg = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;
}

class AppRadii {
  const AppRadii._();
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 24.0;
  static const double pill = 999.0;

  static const Radius radiusXs = Radius.circular(xs);
  static const Radius radiusSm = Radius.circular(sm);
  static const Radius radiusMd = Radius.circular(md);
  static const Radius radiusLg = Radius.circular(lg);
  static const Radius radiusPill = Radius.circular(pill);

  static const BorderRadius borderXs = BorderRadius.all(radiusXs);
  static const BorderRadius borderSm = BorderRadius.all(radiusSm);
  static const BorderRadius borderMd = BorderRadius.all(radiusMd);
  static const BorderRadius borderLg = BorderRadius.all(radiusLg);
  static const BorderRadius borderPill = BorderRadius.all(radiusPill);
}

class AppTypography {
  const AppTypography._();

  static const String _displayFont = 'Comic Sans MS';
  static const String _bodyFont = 'sans-serif';

  static const TextStyle headlineLarge = TextStyle(
    fontFamily: _displayFont,
    fontSize: 28.0,
    fontWeight: FontWeight.bold,
    color: AppColors.onBackground,
    letterSpacing: -0.5,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontFamily: _displayFont,
    fontSize: 22.0,
    fontWeight: FontWeight.w600,
    color: AppColors.onBackground,
  );

  static const TextStyle titleLarge = TextStyle(
    fontFamily: _displayFont,
    fontSize: 18.0,
    fontWeight: FontWeight.w600,
    color: AppColors.onBackground,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontFamily: _bodyFont,
    fontSize: 16.0,
    fontWeight: FontWeight.normal,
    color: AppColors.onBackground,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: _bodyFont,
    fontSize: 14.0,
    fontWeight: FontWeight.normal,
    color: AppColors.onSurfaceVariant,
  );

  static const TextStyle labelLarge = TextStyle(
    fontFamily: _displayFont,
    fontSize: 14.0,
    fontWeight: FontWeight.w600,
    color: AppColors.onPrimary,
  );

  static const TextStyle errorText = TextStyle(
    fontFamily: _bodyFont,
    fontSize: 13.0,
    fontWeight: FontWeight.w500,
    color: AppColors.error,
  );
}

class AppTheme {
  const AppTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        primaryContainer: AppColors.primaryContainer,
        onPrimaryContainer: AppColors.onPrimaryContainer,
        secondary: AppColors.secondary,
        onSecondary: AppColors.onSecondary,
        error: AppColors.error,
        onError: AppColors.onError,
        surface: AppColors.surface,
        onSurface: AppColors.onSurface,
      ),
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.onBackground,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: AppTypography.titleLarge,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: const OutlineInputBorder(
          borderRadius: AppRadii.borderPill,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadii.borderPill,
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadii.borderPill,
          borderSide: BorderSide(color: AppColors.primary, width: 2.0),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadii.borderPill,
          borderSide: BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: AppRadii.borderPill,
          borderSide: BorderSide(color: AppColors.error, width: 2.0),
        ),
        labelStyle: AppTypography.bodyMedium,
        errorStyle: AppTypography.errorText,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          minimumSize: const Size.fromHeight(48.0),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderPill),
          textStyle: AppTypography.labelLarge,
          elevation: 2,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.borderPill),
          textStyle: AppTypography.labelLarge.copyWith(
            color: AppColors.primary,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.borderPill),
        elevation: 4,
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 2,
        shadowColor: AppColors.outlineVariant,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.borderLg),
      ),
    );
  }
}
