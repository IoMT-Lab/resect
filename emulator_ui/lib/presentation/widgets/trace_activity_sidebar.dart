import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';

/// Right sidebar showing trace activity.
///
/// Displays a live feed of:
/// - First function calls (filtered trace)
/// - Lifecycle events (pause, resume, reset)
class TraceActivitySidebar extends ConsumerWidget {
  const TraceActivitySidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpanded = ref.watch(traceActivitySidebarExpandedProvider);
    final traceEvents = ref.watch(traceActivityEventsProvider);

    return Container(
      color: Theme.of(context).appBarTheme.backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with title and toggle button
          _buildHeader(context, ref, isExpanded),

          const Divider(height: 1),

          // Content (only show if expanded)
          if (isExpanded) ...[
            Expanded(
              child: traceEvents.isEmpty
                  ? _buildEmptyState(context)
                  : _buildTraceList(context, ref, traceEvents),
            ),

            // Clear button at bottom
            if (traceEvents.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ref.read(traceActivityEventsProvider.notifier).state = [];
                    },
                    icon: const Icon(Icons.clear_all, size: 16),
                    label: const Text('Clear'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ),
            ],
          ] else ...[
            // Rotated label when collapsed
            Expanded(
              child: GestureDetector(
                onTap: () {
                  ref.read(traceActivitySidebarExpandedProvider.notifier).state = true;
                },
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      'TRACE ACTIVITY',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build the header with title and toggle button
  Widget _buildHeader(BuildContext context, WidgetRef ref, bool isExpanded) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              isExpanded ? Icons.chevron_right : Icons.chevron_left,
              size: 18,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              ref.read(traceActivitySidebarExpandedProvider.notifier).state = !isExpanded;
            },
            tooltip: isExpanded ? 'Collapse Trace Activity' : 'Expand Trace Activity',
          ),
          if (isExpanded) ...[
            const SizedBox(width: 4),
            Text(
              'TRACE ACTIVITY',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ],
      ),
    );

  /// Build the empty state when no trace events yet
  Widget _buildEmptyState(BuildContext context) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          'No trace activity yet.\nClick RUN to start emulation.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    );

  /// Build the list of trace events
  Widget _buildTraceList(
    BuildContext context,
    WidgetRef ref,
    List<TraceActivityEvent> events,
  ) => ListView.builder(
      reverse: true, // Show newest at bottom
      padding: const EdgeInsets.all(8),
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[events.length - 1 - index];
        return _buildTraceEventItem(context, ref, event, index);
      },
    );

  /// Build a single trace event item
  Widget _buildTraceEventItem(
    BuildContext context,
    WidgetRef ref,
    TraceActivityEvent event,
    int displayIndex,
  ) {
    // Get styling based on event type
    final styling = _getEventStyling(event);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: event.symbol != null
            ? () {
                // Navigate to the function in the graph (only for function calls and pauses with symbols)
                ref.read(selectedSymbolProvider.notifier).state = event.symbol;
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: styling.backgroundColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: styling.borderColor,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // Timestamp
              Text(
                event.timeString,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                  fontFamily: 'monospace',
                  fontSize: 9,
                ),
              ),
              const SizedBox(width: 8),

              // Icon
              Icon(
                styling.icon,
                size: 14,
                color: styling.iconColor,
              ),
              const SizedBox(width: 6),

              // Event description
              Expanded(
                child: Text(
                  event.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: styling.fontWeight,
                    color: styling.textColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Get styling configuration for each event type
  _EventStyling _getEventStyling(TraceActivityEvent event) {
    switch (event.type) {
      case TraceActivityEventType.functionCall:
        return _EventStyling(
          icon: Icons.play_arrow,
          iconColor: Colors.green,
          backgroundColor: Colors.green.withValues(alpha: 0.1),
          borderColor: Colors.green.withValues(alpha: 0.3),
          textColor: null,
          fontWeight: FontWeight.normal,
        );
      case TraceActivityEventType.paused:
        // Different colors for different pause reasons
        final isUnhandled = event.unhandledAccess == true;
        return _EventStyling(
          icon: Icons.pause,
          iconColor: isUnhandled ? Colors.red : Colors.orange,
          backgroundColor: isUnhandled
              ? Colors.red.withValues(alpha: 0.1)
              : Colors.orange.withValues(alpha: 0.1),
          borderColor: isUnhandled
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.orange.withValues(alpha: 0.3),
          textColor: isUnhandled ? Colors.red[300] : Colors.orange[300],
          fontWeight: FontWeight.bold,
        );
      case TraceActivityEventType.resumed:
        return _EventStyling(
          icon: Icons.play_circle_outline,
          iconColor: Colors.blue,
          backgroundColor: Colors.blue.withValues(alpha: 0.1),
          borderColor: Colors.blue.withValues(alpha: 0.3),
          textColor: Colors.blue[300],
          fontWeight: FontWeight.bold,
        );
      case TraceActivityEventType.reset:
        return _EventStyling(
          icon: Icons.refresh,
          iconColor: Colors.purple,
          backgroundColor: Colors.purple.withValues(alpha: 0.1),
          borderColor: Colors.purple.withValues(alpha: 0.3),
          textColor: Colors.purple[300],
          fontWeight: FontWeight.bold,
        );
    }
  }
}

/// Styling configuration for different event types
class _EventStyling {
  final IconData icon;
  final Color iconColor;
  final Color backgroundColor;
  final Color borderColor;
  final Color? textColor;
  final FontWeight fontWeight;

  _EventStyling({
    required this.icon,
    required this.iconColor,
    required this.backgroundColor,
    required this.borderColor,
    required this.fontWeight, this.textColor,
  });
}
