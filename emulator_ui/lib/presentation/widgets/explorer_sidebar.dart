import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import '../../providers/app_providers.dart';
import 'emulator_explorer_widget.dart';

/// Left sidebar showing emulator files and symbols.
///
/// Allows users to:
/// - Select ELF files to analyze
/// - Browse loaded symbols
/// - Collapse/expand the sidebar
class ExplorerSidebar extends ConsumerWidget {
  const ExplorerSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isExpanded = ref.watch(leftSidebarExpandedProvider);
    final currentTab = ref.watch(explorerTabProvider);
    final selectedElfPath = ref.watch(selectedElfPathProvider);
    final callgraphAsync = ref.watch(callgraphProvider);

    return Container(
      color: Theme.of(context).appBarTheme.backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with title and toggle button
          _buildHeader(context, ref, isExpanded),

          const Divider(height: 1),

          // Tab bar (only show when expanded)
          if (isExpanded) ...[
            _buildTabBar(context, ref, currentTab),
            const Divider(height: 1),
          ],

          // Content (only show if expanded)
          if (isExpanded) ...[
            // Show content based on current tab
            if (currentTab == ExplorerTab.emulator)
              const Expanded(child: EmulatorExplorerWidget())
            else
              ..._buildSymbolsTabContent(
                  context, ref, selectedElfPath, callgraphAsync),
          ] else ...[
            // Rotated label when collapsed
            Expanded(
              child: GestureDetector(
                onTap: () {
                  ref.read(leftSidebarExpandedProvider.notifier).state = true;
                },
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 1,
                    child: Text(
                      'EXPLORER',
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

  /// Build tab bar for EMULATOR/SYMBOLS switching
  Widget _buildTabBar(
      BuildContext context, WidgetRef ref, ExplorerTab currentTab) {
    return Row(
      children: [
        Expanded(
          child: _buildTab(
            context,
            ref,
            label: 'EMULATOR',
            tab: ExplorerTab.emulator,
            isSelected: currentTab == ExplorerTab.emulator,
          ),
        ),
        Expanded(
          child: _buildTab(
            context,
            ref,
            label: 'SYMBOLS',
            tab: ExplorerTab.symbols,
            isSelected: currentTab == ExplorerTab.symbols,
          ),
        ),
      ],
    );
  }

  Widget _buildTab(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required ExplorerTab tab,
    required bool isSelected,
  }) {
    return InkWell(
      onTap: () => ref.read(explorerTabProvider.notifier).state = tab,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }

  /// Build SYMBOLS tab content (existing functionality)
  List<Widget> _buildSymbolsTabContent(
    BuildContext context,
    WidgetRef ref,
    String? selectedElfPath,
    AsyncValue<CallGraph?> callgraphAsync,
  ) {
    return [
      // File picker button
      Padding(
        padding: const EdgeInsets.all(8.0),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _pickFile(ref),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Open ELF File'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ),

      const Divider(height: 1),

      // Show selected file info
      if (selectedElfPath != null) ...[
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current File:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                _getFileName(selectedElfPath),
                style: Theme.of(context).textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Symbol list
        Expanded(
          child: callgraphAsync.when(
            data: (callGraph) {
              if (callGraph == null) {
                return const Center(child: Text('No data'));
              }

              return _SymbolTreeView(callGraph: callGraph);
            },
            loading: () => const Center(
              child: CircularProgressIndicator(),
            ),
            error: (error, stack) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error, color: Colors.red),
                    const SizedBox(height: 8),
                    Text(
                      'Error loading call graph',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      error.toString(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                            fontSize: 10,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ] else ...[
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Open an ELF file to view call graph',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    ];
  }

  /// Build the header with title and toggle button
  Widget _buildHeader(BuildContext context, WidgetRef ref, bool isExpanded) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          if (isExpanded) ...[
            Text(
              'EXPLORER',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
          ],
          IconButton(
            icon: Icon(
              isExpanded ? Icons.chevron_left : Icons.chevron_right,
              size: 18,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              ref.read(leftSidebarExpandedProvider.notifier).state = !isExpanded;
            },
            tooltip: isExpanded ? 'Collapse Explorer' : 'Expand Explorer',
          ),
        ],
      ),
    );
  }

  /// Open file picker to select an ELF file
  Future<void> _pickFile(WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select ELF File',
    );

    if (result != null && result.files.single.path != null) {
      final elfPath = result.files.single.path!;
      // Set the ELF path to trigger call graph generation
      ref.read(selectedElfPathProvider.notifier).state = elfPath;
    }
  }

  /// Extract just the filename from a full path
  String _getFileName(String path) {
    return path.split('/').last;
  }
}

/// Tree view widget for organizing symbols by entry points and isolated nodes
class _SymbolTreeView extends ConsumerStatefulWidget {
  final dynamic callGraph;

  const _SymbolTreeView({required this.callGraph});

  @override
  ConsumerState<_SymbolTreeView> createState() => _SymbolTreeViewState();
}

class _SymbolTreeViewState extends ConsumerState<_SymbolTreeView> {
  final Set<String> _expandedNodes = {};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callGraph = widget.callGraph;

    // Build caller relationships
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};

    for (var entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (var called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }

    // Find entry points (nodes with no callers or named main/reset)
    final entryPoints = <String>[];
    for (var symbol in callGraph.symbols.keys) {
      if (hasConnections.contains(symbol) &&
          (!callers.containsKey(symbol) ||
           symbol.toLowerCase().contains('main') ||
           symbol.toLowerCase().contains('reset'))) {
        entryPoints.add(symbol);
      }
    }
    entryPoints.sort();

    // Find isolated nodes (no connections at all)
    final isolatedNodes = <String>[];
    for (var symbol in callGraph.symbols.keys) {
      if (!hasConnections.contains(symbol)) {
        isolatedNodes.add(symbol);
      }
    }
    isolatedNodes.sort();

    // Filter based on search query
    final isSearching = _searchQuery.isNotEmpty;
    final filteredEntryPoints = isSearching
        ? entryPoints.where((s) => s.toLowerCase().contains(_searchQuery.toLowerCase())).toList()
        : entryPoints;
    final filteredIsolatedNodes = isSearching
        ? isolatedNodes.where((s) => s.toLowerCase().contains(_searchQuery.toLowerCase())).toList()
        : isolatedNodes;

    // If searching, also find matching called symbols
    final matchingCalledSymbols = <String>[];
    if (isSearching) {
      for (var entry in callGraph.symbols.entries) {
        if (entry.key.toLowerCase().contains(_searchQuery.toLowerCase()) &&
            !filteredEntryPoints.contains(entry.key) &&
            !filteredIsolatedNodes.contains(entry.key)) {
          matchingCalledSymbols.add(entry.key);
        }
      }
      matchingCalledSymbols.sort();
    }

    return Column(
      children: [
        // Search box
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search symbols...',
              prefixIcon: const Icon(Icons.search, size: 16),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            style: Theme.of(context).textTheme.bodySmall,
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
        ),

        // Results
        Expanded(
          child: ListView(
            children: [
              // Entry points section
              if (filteredEntryPoints.isNotEmpty) ...[
                _buildSectionHeader(context, 'Entry Points', filteredEntryPoints.length),
                ...filteredEntryPoints.map((symbol) => isSearching
                    ? _buildSymbolTile(context, symbol, callGraph, indent: 0)
                    : _buildEntryPointNode(context, symbol, callGraph)),
              ],

              // Matching called symbols (only show when searching)
              if (isSearching && matchingCalledSymbols.isNotEmpty) ...[
                _buildSectionHeader(context, 'Other Matches', matchingCalledSymbols.length),
                ...matchingCalledSymbols.map((symbol) =>
                    _buildSymbolTile(context, symbol, callGraph, indent: 0)),
              ],

              // Isolated nodes section
              if (filteredIsolatedNodes.isNotEmpty) ...[
                _buildSectionHeader(context, 'Isolated Nodes', filteredIsolatedNodes.length),
                if (_expandedNodes.contains('__isolated__') || isSearching)
                  ...filteredIsolatedNodes.map((symbol) => _buildSymbolTile(context, symbol, callGraph, indent: 1)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, int count) {
    final isExpanded = _expandedNodes.contains('__isolated__') || title != 'Isolated Nodes';

    return InkWell(
      onTap: () {
        setState(() {
          if (title == 'Isolated Nodes') {
            if (_expandedNodes.contains('__isolated__')) {
              _expandedNodes.remove('__isolated__');
            } else {
              _expandedNodes.add('__isolated__');
            }
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
        child: Row(
          children: [
            if (title == 'Isolated Nodes')
              Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
              ),
            const SizedBox(width: 4),
            Text(
              '$title ($count)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryPointNode(BuildContext context, String symbolName, dynamic callGraph) {
    final isExpanded = _expandedNodes.contains(symbolName);
    final symbol = callGraph.symbols[symbolName];
    if (symbol == null) return const SizedBox.shrink();
    final hasChildren = symbol.calledSymbols.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSymbolTile(
          context,
          symbolName,
          callGraph,
          indent: 0,
          isExpandable: hasChildren,
          isExpanded: isExpanded,
          onExpandToggle: hasChildren ? () {
            setState(() {
              if (isExpanded) {
                _expandedNodes.remove(symbolName);
              } else {
                _expandedNodes.add(symbolName);
              }
            });
          } : null,
        ),
        if (isExpanded && hasChildren)
          ...symbol.calledSymbols.keys.map((calledSymbol) {
            return _buildSymbolTile(context, calledSymbol, callGraph, indent: 1);
          }),
      ],
    );
  }

  Widget _buildSymbolTile(
    BuildContext context,
    String symbolName,
    dynamic callGraph, {
    int indent = 0,
    bool isExpandable = false,
    bool isExpanded = false,
    VoidCallback? onExpandToggle,
  }) {
    final symbol = callGraph.symbols[symbolName];
    if (symbol == null) return const SizedBox.shrink();

    final isSelected = ref.watch(selectedSymbolProvider) == symbolName;

    return InkWell(
      onTap: () {
        if (isExpandable && onExpandToggle != null) {
          onExpandToggle();
        }
        ref.read(selectedSymbolProvider.notifier).state = symbolName;
      },
      child: Container(
        padding: EdgeInsets.only(
          left: 8.0 + (indent * 16.0),
          right: 8.0,
          top: 4.0,
          bottom: 4.0,
        ),
        color: isSelected ? Theme.of(context).colorScheme.primary.withOpacity(0.2) : null,
        child: Row(
          children: [
            if (isExpandable)
              Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
              )
            else
              const SizedBox(width: 16),
            const SizedBox(width: 4),
            const Icon(Icons.functions, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    symbolName,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${symbol.numInstructions} instructions',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
