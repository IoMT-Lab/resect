/// Orchestrator, CLI, and API server for ARM firmware emulation.
///
/// This package provides the business logic layer for controlling
/// emulation via the Python emulation_engine backend.
library emulator_orchestrator;

// Core
export 'core/app_paths.dart';
export 'core/constants.dart';

// Orchestrator
export 'orchestrator/emulation_orchestrator.dart';
export 'orchestrator/python_server.dart';
export 'orchestrator/service_connector.dart';
export 'orchestrator/events/orchestrator_events.dart';
export 'orchestrator/events/synthesizer_events.dart';
export 'orchestrator/exceptions/orchestrator_exceptions.dart';
export 'orchestrator/workflows/analysis_workflow.dart';
export 'orchestrator/workflows/emulation_workflow.dart';
export 'orchestrator/workflows/emulator_workflow.dart';
export 'orchestrator/workflows/synthesizer_workflow.dart';

// Engine abstraction
export 'orchestrator/engine/engine.dart';
export 'orchestrator/engine/renode/renode_engine_lifecycle.dart';
export 'orchestrator/engine/renode/renode_call_graph_source.dart';
export 'orchestrator/engine/renode/renode_emulation_controller.dart';
export 'orchestrator/engine/renode/renode_trace_source.dart';

// Data models
export 'data/models/call_graph.dart';
export 'data/models/emulation_state.dart';
export 'data/models/emulator.dart';
export 'data/models/fidelity_result.dart';
export 'data/models/firmware_record.dart';
export 'data/models/graph_point.dart';
export 'data/models/recent_emulator.dart';
export 'data/models/symbol.dart';
export 'data/models/synthesizer_result.dart';
export 'data/models/trace_activity_event.dart';

// Data services
export 'data/services/artifact_library_service.dart';
export 'data/services/callgraph_service.dart';
export 'data/services/fidelity_calculator.dart';
export 'data/services/filtered_trace_service.dart';
export 'data/services/lifecycle_service.dart';
export 'data/services/trace_service.dart';

// Data repositories
export 'data/repositories/emulator_repository.dart';

// Database
export 'data/database/artifact_database.dart' hide Symbol;

// API
export 'api/api_server.dart';
