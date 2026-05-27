/// Represents a single function/symbol in the call graph.
/// 
/// Each symbol has a name, instruction count, and information about
/// which other functions it calls (and how many times).
class Symbol {
  /// The name of the function (e.g., "main", "SystemInit")
  final String name;
  
  /// Number of assembly instructions in this function
  final int numInstructions;
  
  /// Map of function names this symbol calls -> number of times called
  /// Example: {"HAL_Init": 1, "delay": 5}
  final Map<String, int> calledSymbols;

  Symbol({
    required this.name,
    required this.numInstructions,
    required this.calledSymbols,
  });

  /// Create a Symbol from JSON data received from Python server
  /// 
  /// Expected format:
  /// {
  ///   "num_instructions": 42,
  ///   "called_symbols": {"function_a": 1, "function_b": 3}
  /// }
  factory Symbol.fromJson(String name, Map<String, dynamic> json) => Symbol(
      name: name,
      numInstructions: json['num_instructions'] as int,
      calledSymbols: Map<String, int>.from(json['called_symbols'] ?? {}),
    );

  /// Convert Symbol back to JSON (for saving/caching)
  Map<String, dynamic> toJson() => {
      'num_instructions': numInstructions,
      'called_symbols': calledSymbols,
    };

  @override
  String toString() => 'Symbol(name: $name, instructions: $numInstructions, calls: ${calledSymbols.length})';
}
