import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';

/// Connection status indicator for the status bar.
/// 
/// Shows whether we're connected to the Python server with a colored dot
/// and reconnect functionality if disconnected.
class ConnectionStatusIndicator extends ConsumerWidget {
  const ConnectionStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(connectionStatusProvider);

    return connectionAsync.when(
      data: (isConnected) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status indicator dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isConnected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          
          // Status text
          Text(
            isConnected ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 11,
              color: isConnected ? Colors.green : Colors.red,
            ),
          ),
          
          // Reconnect button if disconnected
          if (!isConnected) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _reconnect(ref),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  'Reconnect',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      loading: () => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(strokeWidth: 1),
          ),
          SizedBox(width: 6),
          Text('Connecting...', style: TextStyle(fontSize: 11)),
        ],
      ),
      error: (error, stack) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.orange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'Connection Error',
            style: TextStyle(fontSize: 11, color: Colors.orange),
          ),
        ],
      ),
    );
  }

  /// Re-establish the in-process call-graph source.
  Future<void> _reconnect(WidgetRef ref) async {
    await ref.read(emulationOrchestratorProvider).callGraphSource.connect();
  }
}
