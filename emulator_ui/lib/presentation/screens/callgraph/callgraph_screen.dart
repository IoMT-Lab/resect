import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/placeholder_screen.dart';

/// CALL GRAPH tab — graph visualization + function-level hook overrides.
///
/// To be populated by commit 4: graph viewer, symbols sidebar, metadata
/// sidebar, right-click "Force hook…" inline editor.
class CallGraphScreen extends ConsumerWidget {
  const CallGraphScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlaceholderScreen(
      title: 'Call Graph',
      subtitle: 'Graph visualization and function override editor — coming soon.',
    );
  }
}
