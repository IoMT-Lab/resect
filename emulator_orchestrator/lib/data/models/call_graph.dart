import 'symbol.dart';

/// Represents the complete call graph for a firmware binary.
/// 
/// This is the main data structure that holds all functions/symbols
/// and their relationships (who calls whom).
class CallGraph {
  /// Path to the ELF file this call graph was generated from
  final String elfPath;
  
  /// Map of function name -> Symbol data
  /// Example: {"main": Symbol(...), "SystemInit": Symbol(...)}
  final Map<String, Symbol> symbols;

  CallGraph({
    required this.elfPath,
    required this.symbols,
  });

  /// Create a CallGraph from JSON data received from Python server
  /// 
  /// Expected format from server:
  /// [true, {
  ///   "main": {"num_instructions": 42, "called_symbols": {"init": 1}},
  ///   "init": {"num_instructions": 10, "called_symbols": {}}
  /// }]
  factory CallGraph.fromJson(String elfPath, List<dynamic> response) {
    // Response is [success, data] from Python
    final success = response[0] as bool;
    if (!success) {
      throw Exception('Failed to generate call graph: ${response[1]}');
    }

    final data = response[1] as Map<String, dynamic>;
    final symbols = <String, Symbol>{};
    
    // Convert each entry to a Symbol object
    data.forEach((name, symbolData) {
      symbols[name] = Symbol.fromJson(name, symbolData as Map<String, dynamic>);
    });

    return CallGraph(
      elfPath: elfPath,
      symbols: symbols,
    );
  }

  /// Create a CallGraph from serialized JSON (the format produced by [toJson]).
  ///
  /// This enables loading a previously saved call graph from file,
  /// e.g. for offline fidelity computation.
  factory CallGraph.fromSerializedJson(Map<String, dynamic> json) {
    final elfPath = json['elfPath'] as String;
    final symbolsData = json['symbols'] as Map<String, dynamic>;
    final symbols = <String, Symbol>{};
    symbolsData.forEach((name, data) {
      symbols[name] = Symbol.fromJson(name, data as Map<String, dynamic>);
    });
    return CallGraph(elfPath: elfPath, symbols: symbols);
  }

  /// Get a specific symbol by name, or null if not found
  Symbol? getSymbol(String name) => symbols[name];

  /// Get all symbols that call the given function
  /// (reverse lookup - who calls this function?)
  List<String> getCallers(String functionName) {
    final callers = <String>[];
    
    for (final entry in symbols.entries) {
      if (entry.value.calledSymbols.containsKey(functionName)) {
        callers.add(entry.key);
      }
    }
    
    return callers;
  }

  /// Get total number of functions in the call graph
  int get totalFunctions => symbols.length;

  /// Get total number of call relationships (edges in the graph)
  int get totalEdges {
    var count = 0;
    for (final symbol in symbols.values) {
      count += symbol.calledSymbols.length;
    }
    return count;
  }

  Map<String, dynamic> toJson() => {
      'elfPath': elfPath,
      'symbols': symbols.map((name, symbol) => MapEntry(name, symbol.toJson())),
    };

  @override
  String toString() => 'CallGraph(elfPath: $elfPath, functions: $totalFunctions, edges: $totalEdges)';
}
