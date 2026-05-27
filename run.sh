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
# Flutter app. The emulation engine (Renode + objdump) runs in-process via the
# pure-Dart packages — there is no Python server to start.
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR/emulator_ui"
echo "Starting Flutter app..."
flutter run -d linux
