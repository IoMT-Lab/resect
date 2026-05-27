import 'package:flutter/material.dart';

/// Resect's visual theme — Lightroom-inspired, modernized.
///
/// Three background layers (chrome / canvas / panel), a single accent for
/// active state (replacing Lightroom's faux-glow), and three text weights.
/// Tab labels are all-caps, letter-spaced, with a thin accent underline on
/// the active tab.
///
/// The legacy `primaryBlue`, `darkBackground`, `sidebarBackground`,
/// `borderColor`, `textPrimary`, `textSecondary` constants remain as
/// aliases of the new palette so existing widgets keep compiling. Prefer
/// the named tokens below for new code.
class AppTheme {
  // ---------------------------------------------------------------------------
  // Palette
  // ---------------------------------------------------------------------------

  /// App shell (top bar, status bar, outermost surface).
  static const bgChrome = Color(0xFF1E1E1E);

  /// Tab content background — the canvas where each screen draws.
  static const bgCanvas = Color(0xFF252525);

  /// Sidebars, dialogs, raised panels.
  static const bgPanel = Color(0xFF2C2C2C);

  /// Hairline separators between regions.
  static const border = Color(0xFF3A3A3A);

  /// Single accent — used for the active-tab underline and focused borders.
  static const accent = Color(0xFF5CABFF);

  /// Primary body text.
  static const textPrimary = Color(0xFFE8E8E8);

  /// Secondary / muted text (subtitles, helper copy, inactive tab labels).
  static const textMuted = Color(0xFF8A8A8A);

  /// Disabled / "not ready" state (e.g. a tab whose prerequisites aren't met).
  static const textDisabled = Color(0xFF5A5A5A);

  // ---------------------------------------------------------------------------
  // Tab-strip tokens
  // ---------------------------------------------------------------------------

  /// Active-tab accent underline thickness.
  static const tabUnderlineThickness = 2.0;

  /// Letter-spacing applied to all-caps tab labels.
  static const tabLabelLetterSpacing = 1.6;

  /// Horizontal gutter between adjacent tab labels.
  static const tabGutter = 24.0;

  /// Tab label font size.
  static const tabLabelFontSize = 12.0;

  // ---------------------------------------------------------------------------
  // Legacy aliases (preserve existing references; eventually replaceable)
  // ---------------------------------------------------------------------------

  static const primaryBlue = accent;
  static const darkBackground = bgChrome;
  static const sidebarBackground = bgPanel;
  static const borderColor = border;
  static const textSecondary = textMuted;

  // ---------------------------------------------------------------------------
  // ThemeData
  // ---------------------------------------------------------------------------

  static ThemeData get darkTheme => ThemeData(
      brightness: Brightness.dark,
      primaryColor: accent,
      scaffoldBackgroundColor: bgChrome,
      canvasColor: bgCanvas,

      appBarTheme: const AppBarTheme(
        backgroundColor: bgChrome,
        elevation: 0,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.normal,
        ),
      ),

      cardTheme: CardThemeData(
        color: bgPanel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: border, width: 1),
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),

      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary, fontSize: 13),
        bodyMedium: TextStyle(color: textPrimary, fontSize: 13),
        bodySmall: TextStyle(color: textMuted, fontSize: 11),
        titleMedium: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
        labelSmall: TextStyle(color: textMuted, fontSize: 11),
      ),

      iconTheme: const IconThemeData(
        color: textPrimary,
        size: 18,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),

      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textPrimary,
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
    );

  // ---------------------------------------------------------------------------
  // Tab-label text styles
  // ---------------------------------------------------------------------------

  /// All-caps, letter-spaced label for tabs in the top strip.
  ///
  /// Pass `active: true` for the highlighted tab; `ready: false` dims the
  /// label to indicate the tab's prerequisites aren't met yet.
  static TextStyle tabLabel({required bool active, bool ready = true}) {
    final color = !ready
        ? textDisabled
        : (active ? textPrimary : textMuted);
    return TextStyle(
      color: color,
      fontSize: tabLabelFontSize,
      fontWeight: active ? FontWeight.w500 : FontWeight.w400,
      letterSpacing: tabLabelLetterSpacing,
    );
  }
}
