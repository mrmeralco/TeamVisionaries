// Design tokens from the Figma "MOBILE" frames (HTML export: Sinag_HTML/styles.css, 393 × 852).
// Font: DM Sans, bundled in assets/fonts/ (the demo runs offline).
import 'package:flutter/material.dart';

/// Figma palette.
class C {
  static const orange = Color(0xFFF47721);
  static const orangeDeep = Color(0xFFD45A05);
  static const yellow = Color(0xFFFFC857);
  static const cream = Color(0xFFFFF3E5);
  static const ink = Color(0xFF292929);
  static const muted = Color(0xFF818181);
  static const navOff = Color(0xFFFED47D);
  static const tileBorder = Color(0x63BE5D1B); // rgba(190,93,27,.39)
  static const tileLabel = Color(0x63BE5D1B);
  static const unit = Color(0x94F47721); // rgba(244,119,33,.58)
  static const label55 = Color(0x8C292929); // rgba(41,41,41,.55)
  static const card = Colors.white;
  static const green = Color(0xFF299D65);
  static const red = Color(0xFFD93B30);
  static const amber = Color(0xFFE59A00);
}

/// Semantic colours (kept from the scaffold so other code can keep using them).
class AppColors {
  static const sun = C.orange;
  static const solar = C.orange;
  static const battery = C.green;
  static const grid = Color(0xFF5B7CFA);
  static const home = C.orangeDeep;
  static const brownout = C.orangeDeep;
  static const fault = C.red;
}

/// DM Sans is a variable font: set the `wght` axis as well as fontWeight so every platform renders it.
TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color color = C.ink, double? height, double? spacing}) =>
    TextStyle(
      fontFamily: 'DMSans',
      fontSize: size,
      fontWeight: w,
      fontVariations: [FontVariation('wght', w.value.toDouble())],
      color: color,
      height: height,
      letterSpacing: spacing,
    );

const gradientOrange = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [C.orange, C.yellow],
  stops: [0.25, 0.98],
);

class AppTheme {
  /// The design is light-only, so there is no dark variant.
  static ThemeData light() => ThemeData(
        useMaterial3: true,
        fontFamily: 'DMSans',
        scaffoldBackgroundColor: C.cream,
        colorScheme: ColorScheme.fromSeed(seedColor: C.orange, primary: C.orange, surface: C.cream),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.tileBorder)),
          enabledBorder:
              OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.tileBorder)),
          isDense: true,
        ),
      );
}
