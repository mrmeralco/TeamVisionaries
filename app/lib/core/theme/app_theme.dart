// Placeholder theme. Replace the tokens with Shane's Figma styles (colors, type scale, radii).
// Fonts: bundle them under assets/fonts/ (the demo runs offline, so no runtime font downloads).
import 'package:flutter/material.dart';

class AppColors {
  static const sun = Color(0xFFF5A524); // seed until the Figma palette lands
  static const solar = Color(0xFFF5A524);
  static const battery = Color(0xFF2EB67D);
  static const grid = Color(0xFF5B7CFA);
  static const home = Color(0xFF8E59FF);
  static const brownout = Color(0xFF3D3D3D);
  static const fault = Color(0xFFE5484D);
}

class AppTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: AppColors.sun, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
    );
  }
}
