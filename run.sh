#!/bin/bash

# Resolve paths relative to this script, not the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENGINE_DIR="$SCRIPT_DIR/emulation_engine"

if [ ! -d "$ENGINE_DIR" ]; then
    echo "✗ ERROR: emulation_engine not found at $ENGINE_DIR"
    echo "  Clone it into this repo:  git clone <url> $ENGINE_DIR"
    exit 1
fi

echo "=== Starting Resect ==="
echo ""

# ---------------------------------------------------------------------------
# Python server
# ---------------------------------------------------------------------------
echo "Starting Python server..."
cd "$ENGINE_DIR"

# Force pipenv to ignore any existing virtualenv
export PIPENV_IGNORE_VIRTUALENVS=1
export PIPENV_VERBOSITY=-1

echo "Using pipenv from: $(which pipenv)"
echo "Virtualenv location: $(pipenv --venv 2>/dev/null || echo 'Not created yet')"
export RENODE_EXECUTABLE="$(pwd)/renode_1.16.0-dotnet_portable/renode"
echo "Renode executable: $RENODE_EXECUTABLE"

# Check if Renode exists and is executable
if [ ! -f "$RENODE_EXECUTABLE" ]; then
    echo "✗ ERROR: Renode executable not found at: $RENODE_EXECUTABLE"
    exit 1
fi

if [ ! -x "$RENODE_EXECUTABLE" ]; then
    echo "⚠ Renode not executable, making it executable..."
    chmod +x "$RENODE_EXECUTABLE"
fi

# Test Renode can run
echo "Testing Renode executable..."
"$RENODE_EXECUTABLE" --version 2>&1 | head -20
RENODE_EXIT=$?
if [ $RENODE_EXIT -ne 0 ]; then
    echo "✗ ERROR: Renode failed with exit code $RENODE_EXIT"
    exit 1
fi
echo "✓ Renode executable works"

# Kill any existing server processes
echo "Checking for existing server processes..."
if lsof -Pi :5000 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Killing existing Renode process on port 5000..."
    kill $(lsof -t -i:5000) 2>/dev/null || true
    sleep 1
fi

if lsof -Pi :12356 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Killing existing server process on port 12356..."
    kill $(lsof -t -i:12356) 2>/dev/null || true
    sleep 1
fi

# Verify ports are free
if lsof -Pi :5000 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "✗ ERROR: Port 5000 is still in use after cleanup:"
    lsof -Pi :5000 -sTCP:LISTEN
    exit 1
fi

if lsof -Pi :12356 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "✗ ERROR: Port 12356 is still in use after cleanup:"
    lsof -Pi :12356 -sTCP:LISTEN
    exit 1
fi

# Create logging directory for Renode
mkdir -p /tmp/renode_logs

# Get the virtualenv path and activate it directly
VENV_PATH=$(pipenv --venv 2>/dev/null)
if [ -z "$VENV_PATH" ]; then
    echo "✗ ERROR: Could not find virtualenv"
    exit 1
fi

# Run Python directly from the virtualenv
"$VENV_PATH/bin/python" -m emulation_engine.engine > /tmp/resect_server.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server to start..."
sleep 8

# Check if server is actually running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "✗ ERROR: Python server failed to start!"
    echo ""
    echo "=== Full server log ==="
    cat /tmp/resect_server.log
    echo ""
    echo "=== Checking for port conflicts ==="
    echo "Processes on port 5000:"
    lsof -Pi :5000 2>/dev/null || echo "None"
    echo "Processes on port 12356:"
    lsof -Pi :12356 2>/dev/null || echo "None"
    exit 1
fi

echo "✓ Python server started (PID: $SERVER_PID)"
echo "Server logs: /tmp/resect_server.log"
echo ""
echo "Verifying server is listening on port 12356..."
for i in {1..10}; do
    if lsof -Pi :12356 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "✓ Server is listening on port 12356"
        break
    fi
    echo "Waiting for server to listen... ($i/10)"
    sleep 1
done

if ! lsof -Pi :12356 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "✗ ERROR: Server never started listening on port 12356"
    echo "Server log:"
    cat /tmp/resect_server.log
    kill $SERVER_PID 2>/dev/null
    exit 1
fi

# ---------------------------------------------------------------------------
# Flutter app
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR/emulator_ui"
echo "Starting Flutter app..."

# Use git Flutter instead of snap
export PATH="$HOME/development/flutter/bin:$PATH"

flutter run -d linux

# Cleanup: kill server when Flutter app exits
kill $SERVER_PID 2>/dev/null
