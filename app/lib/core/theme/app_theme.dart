// Design tokens from the Figma "MOBILE" frames (HTML export: Solaris_HTML/styles.css, 393 × 852).
// Font: DM Sans, bundled in assets/fonts/ (the demo runs offline).
//
// Readability rules (UI review, Nov 2026): body text ≥ 11, labels ≥ 10, tap targets ≥ 44 px, and every
// text colour ≥ 4.5:1 on its background (large bold numbers ≥ 3:1). Contrast ratios are noted per token.
// Keep colours here: screens should not write Color(0x…) inline.
import 'package:flutter/material.dart';

/// Minimum tap target (WCAG 2.5.5 / Material guidance).
const kMinTap = 44.0;

/// Widest the app lays out; on tablets and laptops it is centred at this width.
const kMaxAppWidth = 480.0;

/// Figma palette, adjusted where the original failed contrast.
class C {
  // Brand
  static const orange = Color(0xFFF47721); // fills, lines, icons. As text only ≥ 24 px bold (2.8:1)
  static const orangeDeep = Color(0xFFD45A05); // big numbers on white (4.0:1, passes for large text)
  static const orangeText = Color(0xFFA94306); // small orange text, links, units (6.0:1 on white)
  static const brandDark = Color(0xFFC2500A); // buttons and white-text surfaces (4.7:1 with white)
  static const yellow = Color(0xFFFFC857);
  static const cream = Color(0xFFFFF3E5);
  static const backdrop = Color(0xFFF6E4CF); // outside the centred app on wide screens

  // Text
  static const ink = Color(0xFF292929);
  static const muted = Color(0xFF666666); // was #818181 (3.6:1 on cream); now 5.3:1
  static const label = Color(0xFF5C5C5C); // small labels; replaces the 39–55 % opacity labels (6.1:1+)
  static const labelOnYellow = Color(0xFF4A4A4A); // labels and units on the yellow cards (6.1:1)

  // Navigation
  static const navOff = Color(0xFFFED47D); // inactive nav icons (decorative: each has a text label)
  static const navOffText = Color(0xFF8F6410); // inactive nav labels (5.3:1; Figma #FED47D was 1.4:1)
  static const navActive = Color(0x45F47721); // rgba(244,119,33,.27) active tab block

  // Surfaces and lines
  static const card = Colors.white;
  static const tileBorder = Color(0x63BE5D1B); // rgba(190,93,27,.39) hairline borders (not text)
  static const orangeLine = Color(0xFFFF7415); // 0.5 px card outlines
  static const peach = Color(0xFFFFC59D); // Self-Sufficiency card
  static const yellowCard = Color(0xD1FFC857); // rgba(255,200,87,.82) Energy stat cards
  static const pill = Color(0x70FFBE81); // rgba(255,190,129,.44) chart value pill
  static const tipBg = Color(0x47FF9D42); // Bill tip card
  static const inputBg = Color(0x6BFFC857); // Ask Mira input
  static const inputBorder = Color(0x85F47721);
  static const miraBubble = Color(0x70FFD580); // Figma "Ask Mira" greeting bubble (#FFD580 @ 44 %)
  static const chartGrid = Color(0x40292929);
  static const divider = Color(0x1F292929); // between alerts in a group card
  static const shadow = Color(0x40000000);

  // Status
  static const green = Color(0xFF299D65);
  static const red = Color(0xFFD93B30);
  static const amber = Color(0xFF8F6410); // was #E59A00 (2.3:1); used for text too, so 5.3:1

  // Chart series (Energy): solar vs. home vs. grid.
  static const seriesSolar = orange;
  static const seriesHome = Color(0xFF6E6E6E); // Figma "Home" grey
  static const seriesGrid = Color(0xFF4F6FE8);

  // Home hero card backgrounds per live state.
  static const heroSunny = [Color(0xFFFED47D), Color(0xFFFFC142)];
  static const heroBrownout = [Color(0xFFFFB37A), Color(0xFFF47721)];
  static const heroFault = [Color(0xFFFFA48F), Color(0xFFE5533D)];
  static const heroOffline = [Color(0xFFE7E1D8), Color(0xFFCFC6BA)];
}

/// Semantic colours (kept from the scaffold so other code can keep using them).
class AppColors {
  static const sun = C.orange;
  static const solar = C.orange;
  static const battery = C.green;
  static const grid = C.seriesGrid;
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

/// Orange → yellow, for surfaces with dark text (Energy period switch).
const gradientOrange = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [C.orange, C.yellow],
  stops: [0.25, 0.98],
);

/// Deep orange, for cards with white text (Bill forecast, active brownout): 4.7:1 to 6.0:1 with white.
/// The Figma orange → yellow ended at 1.5:1 behind "Last Month's Bill".
const gradientDeep = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [C.brandDark, Color(0xFFA94306)],
);

/// Green, for "grid is on" on the Brownout Advisor (5.3:1+ with white; the old light end was 2.2:1).
const gradientGreen = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF1E7A4E), Color(0xFF186640)],
);

class AppTheme {
  /// The design is light-only, so there is no dark variant.
  static ThemeData light() => ThemeData(
        useMaterial3: true,
        fontFamily: 'DMSans',
        scaffoldBackgroundColor: C.cream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: C.orange,
          primary: C.brandDark, // white button text on it is 4.7:1 (on #F47721 it was 2.8:1)
          surface: C.cream,
        ),
        materialTapTargetSize: MaterialTapTargetSize.padded,
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
