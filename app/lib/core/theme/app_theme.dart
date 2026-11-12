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

/// One spacing scale for every margin, gap and padding. [gutter] is the page's left and right edge,
/// the same on every screen, so cards, headings and banners all line up.
class S {
  static const x1 = 4.0, x2 = 8.0, x3 = 12.0, x4 = 16.0, x6 = 24.0, x8 = 32.0;
  static const gutter = 20.0;
}

/// One radius family: cards and hero panels [lg], tiles inside a card [md], controls, icon tiles and
/// buttons [sm], chips and status pills [pill].
class R {
  static const lg = 16.0, md = 12.0, sm = 8.0, pill = 999.0;
  static final card = BorderRadius.circular(lg);
  static final tile = BorderRadius.circular(md);
  static final control = BorderRadius.circular(sm);
}

/// Motion: one UI ease-out for every step, a softer one for the entrance, and short durations.
/// Everything rests at once when the system asks for reduced motion ([reduceMotion]).
class M {
  static const ease = Cubic(0.2, 0.8, 0.2, 1);
  static const easeEnter = Cubic(0.22, 1, 0.36, 1);
  static const press = Duration(milliseconds: 90);
  static const release = Duration(milliseconds: 120);
  static const step = Duration(milliseconds: 150);
  static const slide = Duration(milliseconds: 240);
  static const enter = Duration(milliseconds: 600);
}

bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Figma palette, adjusted where the original failed contrast.
///
/// Night (6 PM to 6 AM, Manila, or Settings > Appearance): the whole app goes dark to match the night
/// house: navy page, dark cards, light text. Tokens that change are getters reading [night]; the app
/// sets it and rebuilds every widget when it flips. Brand fills (orange, buttons) stay the same.
class C {
  static bool night = false;
  static Color _n(Color day, Color dark) => night ? dark : day;

  // Brand
  static const orange = Color(0xFFF47721); // fills, lines, icons. As text only ≥ 24 px bold (2.8:1)
  static Color get orangeDeep => _n(const Color(0xFFD45A05), const Color(0xFFFF9A52)); // big numbers (4.0:1 / 7:1)
  static Color get orangeText => _n(const Color(0xFFA94306), const Color(0xFFFFB27A)); // small orange text (6.0:1 / 8:1)
  static const brandDark = Color(0xFFC2500A); // buttons and white-text surfaces (4.7:1 with white)
  static const yellow = Color(0xFFFFC857); // accent; as a card behind text use [yellowSurface]
  static Color get yellowSurface => _n(yellow, const Color(0xFF2A3354));
  static Color get cream => _n(const Color(0xFFFFF3E5), const Color(0xFF0F1729)); // the page
  static Color get backdrop => _n(const Color(0xFFF6E4CF), const Color(0xFF080D19)); // outside the centred app

  // Text
  static Color get ink => _n(const Color(0xFF292929), const Color(0xFFF1F3F9));
  static const inkFixed = Color(0xFF292929); // dark text on light brand fills (yellow, orange), day and night
  static Color get muted => _n(const Color(0xFF666666), const Color(0xFFA9B2C6)); // 5.3:1 / 6.9:1
  static Color get label => _n(const Color(0xFF5C5C5C), const Color(0xFFBAC2D3)); // small labels (6.1:1+)
  static Color get labelOnYellow => _n(const Color(0xFF4A4A4A), const Color(0xFFC9CFDC)); // on [yellowSurface]

  // Navigation
  static Color get navOff => _n(const Color(0xFFFED47D), const Color(0xFF56628A)); // inactive icons (decorative)
  static Color get navOffText => _n(const Color(0xFF8F6410), const Color(0xFFA9B2C6)); // inactive labels (5.3:1)
  static const navActive = Color(0x45F47721); // rgba(244,119,33,.27) active tab block

  // Surfaces and lines
  static Color get card => _n(Colors.white, const Color(0xFF1A2440));
  static Color get snack => _n(const Color(0xFF292929), const Color(0xFF2B3760)); // white text on it
  static Color get tileBorder => _n(const Color(0x63BE5D1B), const Color(0x52FFB27A)); // hairlines (not text)
  static Color get orangeLine => _n(const Color(0xFFFF7415), const Color(0x99FF7415)); // 0.5 px card outlines
  static Color get peach => _n(const Color(0xFFFFC59D), const Color(0xFF3A2C3A)); // Self-Sufficiency card
  static Color get yellowCard => _n(const Color(0xD1FFC857), const Color(0x2EFFC857)); // Energy stat cards
  static Color get pill => _n(const Color(0x70FFBE81), const Color(0x40FFBE81)); // chart value pill
  static Color get tipBg => _n(const Color(0x47FF9D42), const Color(0x33FF9D42)); // Bill tip card
  static Color get inputBg => _n(const Color(0x6BFFC857), const Color(0x26FFC857)); // Ask Mira input
  static const inputBorder = Color(0x85F47721);
  static Color get miraBubble => _n(const Color(0x70FFD580), const Color(0x33FFD580)); // Mira's bubbles
  static Color get chartGrid => _n(const Color(0x40292929), const Color(0x40FFFFFF));
  static Color get divider => _n(const Color(0x1F292929), const Color(0x24FFFFFF)); // between rows
  static Color get shadow => _n(const Color(0x40000000), const Color(0x66000000));

  // Frosted glass cards (SCard, PressCard): a translucent fill, lighter at the top-left, with a
  // sheen and a lit rim, over the plain [cream] page. Mostly solid: a hint of glass, not a window.
  // [muted] text on a card: 5.5:1+ (night 6:1+).
  static Color get glassTop => _n(const Color(0xEBFFFFFF), const Color(0xEB2A3558)); // .92
  static Color get glassBottom => _n(const Color(0xD1FFFFFF), const Color(0xE01A2440)); // .82 / .88
  static Color get glassSheen => _n(const Color(0x40FFFFFF), const Color(0x14FFFFFF)); // top light
  static Color get glassEdge => _n(Colors.white, const Color(0x59FFFFFF)); // lit rim (not text)
  static Color get glassEdgeFar => _n(const Color(0x66FF7415), const Color(0x4DFF7415)); // far rim, orange

  // Status
  static Color get green => _n(const Color(0xFF299D65), const Color(0xFF4FCB8D));
  static Color get red => _n(const Color(0xFFD93B30), const Color(0xFFFF7A70));
  static const redFill = Color(0xFFD93B30); // behind white text, day and night
  static Color get amber => _n(const Color(0xFF8F6410), const Color(0xFFF2C46B));

  // Chart series (Energy): solar vs. home vs. grid.
  static const seriesSolar = orange;
  static Color get seriesHome => _n(const Color(0xFF6E6E6E), const Color(0xFF9AA3B5));
  static Color get seriesGrid => _n(const Color(0xFF4F6FE8), const Color(0xFF7C95F5));

  // Home hero card backgrounds per live state (day; at night the sky is [nightSky]).
  static const heroSunny = [Color(0xFFFED47D), Color(0xFFFFC142)];
  static const heroBrownout = [Color(0xFFFFB37A), Color(0xFFF47721)];
  static const heroFault = [Color(0xFFFFA48F), Color(0xFFE5533D)];
  static const heroOffline = [Color(0xFFE7E1D8), Color(0xFFCFC6BA)];

  // Home at night: navy sky, moonlit house, lit windows.
  static const nightSky = [Color(0xFF0B1026), Color(0xFF1B2347), Color(0xFF2A3358)];
  static const nightLawn = Color(0xFF152238); // the bottom of house-hero-night.svg
  static const onNight = Colors.white; // 15:1 on the navy sky
  static const onNightMuted = Color(0xCCFFFFFF); // labels and the status sentence (10:1+)
  static const onNightAccent = Color(0xFFFFB37A); // Charging / Exporting (9:1)
  static const onNightAlert = Color(0xFFFF8A80); // Brownout (7:1)
}

/// Semantic colours (kept from the scaffold so other code can keep using them).
class AppColors {
  static const sun = C.orange;
  static const solar = C.orange;
  static Color get battery => C.green;
  static Color get grid => C.seriesGrid;
  static Color get home => C.orangeDeep;
  static Color get brownout => C.orangeDeep;
  static Color get fault => C.red;
}

/// DM Sans is a variable font: set the `wght` axis as well as fontWeight so every platform renders it.
TextStyle ts(double size, {FontWeight w = FontWeight.w400, Color? color, double? height, double? spacing}) =>
    TextStyle(
      fontFamily: 'DMSans',
      fontSize: size,
      fontWeight: w,
      fontVariations: [FontVariation('wght', w.value.toDouble())],
      color: color ?? C.ink,
      height: height,
      letterSpacing: spacing,
    );

/// Orange → yellow, for surfaces with dark text (Energy period switch).
const gradientOrange = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [C.orange, C.yellow],
  stops: [0.25, 0.98],
  // Text on it is [C.inkFixed]: dark at night too.
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
  /// One button pair for the whole app: a solid brand fill and an outline, same height, shape and
  /// type; text buttons share the type. Sentence case everywhere.
  static final _buttonShape = RoundedRectangleBorder(borderRadius: R.control);
  static final _buttonText = ts(13, w: FontWeight.w700);
  static const _buttonSize = Size(kMinTap, kMinTap);
  static const _buttonPad = EdgeInsets.symmetric(horizontal: S.x4);

  /// The theme for the current [C.night]: built again whenever it flips.
  static ThemeData current() => ThemeData(
        useMaterial3: true,
        fontFamily: 'DMSans',
        brightness: C.night ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: C.cream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: C.orange,
          brightness: C.night ? Brightness.dark : Brightness.light,
          primary: C.brandDark, // white button text on it is 4.7:1 (on #F47721 it was 2.8:1)
          onPrimary: Colors.white,
          surface: C.cream,
          onSurface: C.ink,
        ),
        textSelectionTheme: TextSelectionThemeData(cursorColor: C.orangeText),
        progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.orange),
        dividerColor: C.divider,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: C.brandDark,
            foregroundColor: Colors.white,
            minimumSize: _buttonSize,
            padding: _buttonPad,
            shape: _buttonShape,
            textStyle: _buttonText,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: C.night ? C.orangeText : C.brandDark,
            backgroundColor: C.card,
            minimumSize: _buttonSize,
            padding: _buttonPad,
            shape: _buttonShape,
            side: BorderSide(color: C.night ? C.orangeText : C.brandDark),
            textStyle: _buttonText,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: C.orangeText,
            minimumSize: _buttonSize,
            padding: const EdgeInsets.symmetric(horizontal: S.x3),
            shape: _buttonShape,
            textStyle: _buttonText,
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: C.card,
          selectedColor: C.night ? const Color(0xFF5A3A24) : null,
          side: BorderSide(color: C.orangeLine, width: 0.5),
          shape: const StadiumBorder(),
          labelStyle: ts(12, w: FontWeight.w700),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: C.snack,
          contentTextStyle: ts(13, color: Colors.white, height: 1.35),
          shape: RoundedRectangleBorder(borderRadius: R.tile),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: C.card,
          hintStyle: ts(14, color: C.muted),
          border: OutlineInputBorder(borderRadius: R.control, borderSide: BorderSide(color: C.tileBorder)),
          enabledBorder: OutlineInputBorder(borderRadius: R.control, borderSide: BorderSide(color: C.tileBorder)),
          focusedBorder: OutlineInputBorder(borderRadius: R.control, borderSide: BorderSide(color: C.orangeText, width: 1.5)),
          isDense: true,
        ),
        switchTheme: SwitchThemeData(
          trackOutlineColor: WidgetStatePropertyAll(C.night ? C.muted : null),
        ),
      ).copyWith(
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: C.card,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(R.lg))),
        ),
      );

  /// Kept for tests that pump a single widget: the theme for the current [C.night].
  static ThemeData light() => current();
}
