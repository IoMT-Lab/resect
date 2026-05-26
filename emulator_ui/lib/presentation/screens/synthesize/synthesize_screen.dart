import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/placeholder_screen.dart';

/// SYNTHESIZE tab — emulator configuration, synthesis console, trace feed.
///
/// To be populated by commit 5: emulator config panel, synthesis console
/// (replacing the central graph here), trace activity sidebar, Start /
/// Pause / Reset controls, hook database dialog launcher.
class SynthesizeScreen extends ConsumerWidget {
  const SynthesizeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlaceholderScreen(
      title: 'Synthesize',
      subtitle: 'Iterative hook synthesizer and emulation controls — coming soon.',
    );
  }
}
