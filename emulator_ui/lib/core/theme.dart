import 'package:flutter/material.dart';

/// Application theme configuration.
/// 
/// Defines colors, text styles, and other visual properties
/// to give the app a consistent, professional look.
class AppTheme {
  // VSCode-inspired dark color palette
  static const primaryBlue = Color(0xFF007ACC);
  static const darkBackground = Color(0xFF1E1E1E);
  static const sidebarBackground = Color(0xFF252526);
  static const borderColor = Color(0xFF3E3E42);
  static const textPrimary = Color(0xFFCCCCCC);
  static const textSecondary = Color(0xFF858585);
  
  /// Dark theme (primary theme for the app)
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: primaryBlue,
      scaffoldBackgroundColor: darkBackground,
      
      // AppBar styling
      appBarTheme: const AppBarTheme(
        backgroundColor: sidebarBackground,
        elevation: 0,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.normal,
        ),
      ),
      
      // Card styling (for graph nodes, etc.)
      cardTheme: CardThemeData(
        color: sidebarBackground,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: borderColor, width: 1),
        ),
      ),
      
      // Divider styling
      dividerTheme: const DividerThemeData(
        color: borderColor,
        thickness: 1,
        space: 1,
      ),
      
      // Text theme
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary, fontSize: 13),
        bodyMedium: TextStyle(color: textPrimary, fontSize: 12),
        bodySmall: TextStyle(color: textSecondary, fontSize: 11),
        titleMedium: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      
      // Icon theme
      iconTheme: const IconThemeData(
        color: textPrimary,
        size: 18,
      ),
      
      // Button styling
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      
      // List tile styling
      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textPrimary,
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
    );
  }
}
