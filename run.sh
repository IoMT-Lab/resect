#!/bin/bash
set -e

# Resolve paths relative to this script, not the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared configuration (paths/ports), written by the System Configuration UI
# and seeded by install.sh. Sourced here so the scripts and app agree.
if [ -f "$SCRIPT_DIR/resect.config" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/resect.config"
fi

echo "=== Starting Resect ==="
echo ""

# ---------------------------------------------------------------------------
# Ensure Flutter is on PATH (prefer the configured SDK location).
# ---------------------------------------------------------------------------
if ! command -v flutter >/dev/null 2>&1; then
    if [ -n "$FLUTTER_DIR" ] && [ -x "$FLUTTER_DIR/bin/flutter" ]; then
        export PATH="$FLUTTER_DIR/bin:$PATH"
    elif [ -x "$HOME/Development/flutter/bin/flutter" ]; then
        export PATH="$HOME/Development/flutter/bin:$PATH"
    elif [ -x "$HOME/development/flutter/bin/flutter" ]; then
        export PATH="$HOME/development/flutter/bin:$PATH"
    else
        echo "✗ ERROR: flutter not found on PATH or in the configured FLUTTER_DIR."
        echo "  Re-run ./install.sh to install it."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Drift code generation (only when the generated files are missing; pass
# --regen to force a rebuild after changing artifact_database.dart).
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR/emulator_orchestrator"
if [ "$1" = "--regen" ] || [ ! -f lib/data/database/artifact_database.g.dart ]; then
    echo "Running Drift code generation..."
    dart run build_runner build --delete-conflicting-outputs
    echo "✓ Code generation complete"
else
    echo "✓ Drift codegen up to date (pass --regen to force rebuild)"
fi
echo ""

# ---------------------------------------------------------------------------
# hooks-dart: when the local override is active, keep its embedded Python
# module constants (lib/src/system_modules.dart) in sync with the canonical
# .py files. The generator uses only dart:io — no pub fetch, no SSH path.
# ---------------------------------------------------------------------------
HOOKS_DART_PATH="${HOOKS_DART_PATH:-$SCRIPT_DIR/../hooks-dart}"
if [ -f "$SCRIPT_DIR/pubspec_overrides.yaml" ] \
   && grep -q "^[[:space:]]*hooks:" "$SCRIPT_DIR/pubspec_overrides.yaml" \
   && [ -f "$HOOKS_DART_PATH/tool/gen_system_modules.dart" ]; then
    (cd "$HOOKS_DART_PATH" && dart run tool/gen_system_modules.dart --check >/dev/null) || {
        echo "Regenerating hooks-dart embedded module constants..."
        (cd "$HOOKS_DART_PATH" && dart run tool/gen_system_modules.dart)
    }
    echo "✓ hooks-dart embedded modules up to date"
    echo ""
fi

# ---------------------------------------------------------------------------
# Flutter app. The emulation engine (Renode + objdump) runs in-process via the
# pure-Dart packages — there is no Python server to start.
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR/emulator_ui"
echo "Starting Flutter app..."
flutter run -d linux
