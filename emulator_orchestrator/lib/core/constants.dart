/// Application-wide constants.
class AppConstants {
  // Server configuration
  static const String defaultServerUrl = 'http://localhost:12356';
  static const int connectionTimeout = 5; // seconds

  // UI dimensions
  static const double sidebarExpandedWidth = 250.0;
  static const double sidebarCollapsedWidth = 48.0;
  static const double menuBarHeight = 32.0;
  static const double statusBarHeight = 24.0;

  // Graph visualization
  static const double nodeWidth = 150.0;
  static const double nodeHeight = 60.0;
  static const double nodeSpacing = 50.0;

  // App info
  static const String appName = 'Resect';
  static const String appVersion = '0.1.0';
  static const String appDescription = 'ARM Firmware Emulator Creation & Analysis Tool';

  // Emulator management
  static const String emulatorFileExtension = '.emu';
  static const String defaultEmulatorName = 'Untitled Emulator';
  static const int maxRecentEmulators = 10;
  static const String projectsDirName = 'projects';
}
