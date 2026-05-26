import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/placeholder_screen.dart';

/// LIBRARY tab — project/emulator file management.
///
/// To be populated in a follow-up commit: recent emulators list, currently-
/// loaded emulator card, New/Open/Save/Close actions migrated from the menu.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlaceholderScreen(
      title: 'Library',
      subtitle: 'Project and emulator file management — coming in the next commit.',
    );
  }
}
