import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';

/// Right sidebar showing metadata about selected nodes/edges.
/// 
/// Displays detailed information about:
/// - Selected function (symbol)
/// - Instruction count
/// - Functions it calls
/// - Functions that call it
class MetadataSidebar extends ConsumerWidget {
  const MetadataSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpanded = ref.watch(rightSidebarExpandedProvider);
    final selectedSymbol = ref.watch(selectedSymbolProvider);
    final callgraphAsync = ref.watch(callgraphProvider);

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
              child: selectedSymbol == null
                  ? _buildEmptyState(context)
                  : callgraphAsync.when(
                      data: (callGraph) {
                        if (callGraph == null) {
                          return _buildEmptyState(context);
                        }
                        return _buildSymbolDetails(context, ref, callGraph, selectedSymbol);
                      },
                      loading: () => const Center(child: CircularProgressIndicator()),
                      error: (error, stack) => Center(
                        child: Text('Error: $error'),
                      ),
                    ),
            ),
          ] else ...[
            // Rotated label when collapsed
            Expanded(
              child: GestureDetector(
                onTap: () {
                  ref.read(rightSidebarExpandedProvider.notifier).state = true;
                },
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(
                      'METADATA',
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
  Widget _buildHeader(BuildContext context, WidgetRef ref, bool isExpanded) {
    return Container(
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
              ref.read(rightSidebarExpandedProvider.notifier).state = !isExpanded;
            },
            tooltip: isExpanded ? 'Collapse Metadata' : 'Expand Metadata',
          ),
          if (isExpanded) ...[
            const SizedBox(width: 4),
            Text(
              'METADATA',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build the empty state when nothing is selected
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          'Select a function to view details',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// Build the details view for a selected symbol
  Widget _buildSymbolDetails(
    BuildContext context,
    WidgetRef ref,
    callGraph,
    String symbolName,
  ) {
    final symbol = callGraph.getSymbol(symbolName);
    if (symbol == null) {
      return _buildEmptyState(context);
    }

    final callers = callGraph.getCallers(symbolName);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Function name
        Text(
          'Function',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(
          symbolName,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Instruction count
        Text(
          'Instructions',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${symbol.numInstructions}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),

        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),

        // Force override dropdown
        _buildOverrideDropdown(context, ref, symbolName),

        const SizedBox(height: 12),

        // Hook preference dropdown
        _buildHookDropdown(context, ref, symbolName),

        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),

        // Functions this symbol calls
        Text(
          'Calls (${symbol.calledSymbols.length})',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        
        if (symbol.calledSymbols.isEmpty)
          Text(
            'No outgoing calls',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...symbol.calledSymbols.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () {
                  // Navigate to the called function
                  ref.read(selectedSymbolProvider.notifier).state = entry.key;
                },
                child: Row(
                  children: [
                    const Icon(Icons.arrow_forward, size: 12),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        entry.key,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '×${entry.value}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        
        // Functions that call this symbol
        Text(
          'Called By (${callers.length})',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        
        if (callers.isEmpty)
          Text(
            'No incoming calls',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...callers.map((caller) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () {
                  // Navigate to the caller function
                  ref.read(selectedSymbolProvider.notifier).state = caller;
                },
                child: Row(
                  children: [
                    const Icon(Icons.arrow_back, size: 12),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        caller,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  /// Build the force override dropdown for the selected symbol.
  Widget _buildOverrideDropdown(BuildContext context, WidgetRef ref, String symbolName) {
    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final overrides = ref.watch(hookOverridesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Force Override',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        hooksAsync.when(
          data: (hooks) {
            if (hooks.isEmpty) {
              return Text(
                'No hooks available',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              );
            }

            final selectedId = overrides[symbolName];

            return DropdownButton<int?>(
              value: selectedId,
              isExpanded: true,
              hint: Text(
                'None (no override)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text(
                    'None (no override)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                ...hooks.asMap().entries.map((entry) {
                  final index = entry.key;
                  final artifact = entry.value;
                  return DropdownMenuItem<int?>(
                    value: artifact.id,
                    child: Text(
                      _hookLabel(index, artifact.artifactData),
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),
              ],
              onChanged: (artifactId) {
                final ovr = Map<String, int>.from(
                  ref.read(hookOverridesProvider),
                );
                if (artifactId == null) {
                  ovr.remove(symbolName);
                } else {
                  ovr[symbolName] = artifactId;
                }
                ref.read(hookOverridesProvider.notifier).state = ovr;

                // Persist to emulator model
                final emulator = ref.read(currentEmulatorProvider);
                if (emulator != null) {
                  ref.read(currentEmulatorProvider.notifier).state =
                      emulator.copyWith(
                        hookOverrides: ovr,
                        modifiedAt: DateTime.now(),
                      );
                  ref.read(emulatorDirtyProvider.notifier).state = true;
                }
              },
            );
          },
          loading: () => const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (e, _) => Text(
            'Error: $e',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Build the hook preference dropdown for the selected symbol.
  Widget _buildHookDropdown(BuildContext context, WidgetRef ref, String symbolName) {
    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final preferences = ref.watch(hookPreferencesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preferred Hook',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        hooksAsync.when(
          data: (hooks) {
            if (hooks.isEmpty) {
              return Text(
                'No hooks available',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              );
            }

            final selectedId = preferences[symbolName];

            return DropdownButton<int?>(
              value: selectedId,
              isExpanded: true,
              hint: Text(
                'Auto (default order)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  child: Text(
                    'Auto (default order)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                ...hooks.asMap().entries.map((entry) {
                  final index = entry.key;
                  final artifact = entry.value;
                  return DropdownMenuItem<int?>(
                    value: artifact.id,
                    child: Text(
                      _hookLabel(index, artifact.artifactData),
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),
              ],
              onChanged: (artifactId) {
                final prefs = Map<String, int>.from(
                  ref.read(hookPreferencesProvider),
                );
                if (artifactId == null) {
                  prefs.remove(symbolName);
                } else {
                  prefs[symbolName] = artifactId;
                }
                ref.read(hookPreferencesProvider.notifier).state = prefs;

                // Persist to emulator model
                final emulator = ref.read(currentEmulatorProvider);
                if (emulator != null) {
                  ref.read(currentEmulatorProvider.notifier).state =
                      emulator.copyWith(
                        hookPreferences: prefs,
                        modifiedAt: DateTime.now(),
                      );
                  ref.read(emulatorDirtyProvider.notifier).state = true;
                }
              },
            );
          },
          loading: () => const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (e, _) => Text(
            'Error: $e',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Generate a human-readable label for a hook artifact.
  String _hookLabel(int index, String code) {
    final trimmed = code.trim();
    if (trimmed.contains('Create(0,')) {
      return 'Hook ${index + 1}: return 0';
    } else if (trimmed.contains('Create(1,')) {
      return 'Hook ${index + 1}: return 1';
    }
    final firstLine = trimmed.split('\n').last.trim();
    final preview = firstLine.length > 40 ? '${firstLine.substring(0, 37)}...' : firstLine;
    return 'Hook ${index + 1}: $preview';
  }
}
