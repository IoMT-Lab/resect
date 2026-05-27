/// Application-wide constants.
class AppConstants {
  // Server configuration
  static const defaultServerUrl = 'http://localhost:12356';
  static const connectionTimeout = 5; // seconds

  // UI dimensions
  static const sidebarExpandedWidth = 250.0;
  static const sidebarCollapsedWidth = 48.0;
  static const menuBarHeight = 32.0;
  static const statusBarHeight = 24.0;

  // Graph visualization
  static const nodeWidth = 150.0;
  static const nodeHeight = 60.0;
  static const nodeSpacing = 50.0;

  // App info
  static const appName = 'Resect';
  static const appVersion = '0.1.0';
  static const appDescription = 'ARM Firmware Emulator Creation & Analysis Tool';

  // Emulator management
  static const emulatorFileExtension = '.emu';
  static const defaultEmulatorName = 'Untitled Emulator';
  static const maxRecentEmulators = 10;
  static const projectsDirName = 'projects';
}
