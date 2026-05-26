import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/placeholder_screen.dart';

/// PUBLISH tab — exports and final validation.
///
/// To be populated in the next commit: cards for emulator-bundle .zip,
/// Renode .resc, Vagrant test bundle, and the Run-Vagrant-Test launcher.
class PublishScreen extends ConsumerWidget {
  const PublishScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlaceholderScreen(
      title: 'Publish',
      subtitle: 'Export emulator bundles and run validation — coming in the next commit.',
    );
  }
}
