import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../providers/app_providers.dart';
import '../../widgets/graph_viewer_widget.dart';
import 'widgets/callgraph_empty_state.dart';
import 'widgets/callgraph_toolbar.dart';
import 'widgets/metadata_panel.dart';
import 'widgets/symbols_panel.dart';

/// CALL GRAPH tab — visualize and inspect the firmware's call graph and
/// edit per-function hook overrides.
///
/// Layout: a thin toolbar (ELF path + Open ELF button) over a three-column
/// body — Symbols rail (left), the interactive graph (center), Metadata
/// rail (right). Falls back to an empty state when no ELF is selected.
class CallGraphScreen extends ConsumerWidget {
  const CallGraphScreen({super.key});

  static const double _railWidth = 260;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elfPath = ref.watch(selectedElfPathProvider);

    if (elfPath == null || elfPath.isEmpty) {
      return const CallGraphEmptyState();
    }

    return Container(
      color: AppTheme.bgCanvas,
      child: const Column(
        children: [
          CallGraphToolbar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: _railWidth, child: SymbolsPanel()),
                Expanded(child: GraphViewerWidget()),
                SizedBox(width: _railWidth, child: MetadataPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
