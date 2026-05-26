import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../widgets/trace_activity_sidebar.dart';
import 'widgets/synthesis_config_panel.dart';
import 'widgets/synthesis_console.dart';

/// SYNTHESIZE tab — configure, launch, and observe the hook synthesizer.
///
/// Three columns: config panel (left), synthesis console (center), and the
/// live trace activity feed (right). The console drives the synthesis via
/// SynthesisController, which writes the shared providers the Call Graph
/// viewer also reads — so node ripples animate there in real time.
class SynthesizeScreen extends ConsumerWidget {
  const SynthesizeScreen({super.key});

  static const double _configWidth = 300;
  static const double _traceWidth = 280;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppTheme.bgCanvas,
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: _configWidth, child: SynthesisConfigPanel()),
          Expanded(child: SynthesisConsole()),
          _TraceRail(),
        ],
      ),
    );
  }
}

/// Fixed-width wrapper so the (intrinsically unbounded) TraceActivitySidebar
/// can live directly in the Synthesize tab's Row, with a left border to
/// match the other rails.
class _TraceRail extends StatelessWidget {
  const _TraceRail();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: SynthesizeScreen._traceWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: AppTheme.border)),
        ),
        child: TraceActivitySidebar(),
      ),
    );
  }
}
