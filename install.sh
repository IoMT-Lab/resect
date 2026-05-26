#!/bin/bash
set -e

echo "=== Resect — Installation ==="
echo ""

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  gcc-arm-none-eabi \
  git git-lfs \
  curl unzip wget lsb-release \
  software-properties-common \
  libsqlite3-dev

# Python — read required version from Pipfile; Ubuntu 22.04 ships 3.10 so
# install the exact version via the deadsnakes PPA if needed.
PYTHON_VERSION=$(grep 'python_version' "$INSTALL_DIR/emulation_engine/Pipfile" \
  | grep -oP '"\K[^"]+')
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update -q
sudo apt-get install -y "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" python3-pip pipenv

echo "✓ System packages installed"

# ---------------------------------------------------------------------------
# 2. Flutter SDK (git install — snap has issues with Linux desktop builds)
# ---------------------------------------------------------------------------
FLUTTER_DIR="$HOME/development/flutter"

if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    echo "✓ Flutter already installed at $FLUTTER_DIR"
else
    echo "Installing Flutter SDK..."
    git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_DIR"
fi

# Ensure Flutter is on PATH for this script
export PATH="$FLUTTER_DIR/bin:$PATH"

# Add to shell profile if not already there
if ! grep -q 'development/flutter/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo '' >> "$HOME/.bashrc"
    echo '# Flutter SDK' >> "$HOME/.bashrc"
    echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> "$HOME/.bashrc"
    echo "Added Flutter to ~/.bashrc PATH"
fi

echo "Flutter version: $(flutter --version --machine 2>/dev/null | head -1 || flutter --version | head -1)"

# Pre-cache artifacts and enable Linux desktop
flutter precache
flutter config --enable-linux-desktop

echo "✓ Flutter SDK ready"

# ---------------------------------------------------------------------------
# 3. Python backend (emulation_engine — inside the repo)
# ---------------------------------------------------------------------------
ENGINE_DIR="$INSTALL_DIR/emulation_engine"

if [ ! -d "$ENGINE_DIR" ]; then
    echo "emulation_engine not found — cloning..."
    echo ""
    read -rp "  Enter the emulation_engine git URL: " ENGINE_URL
    if [ -z "$ENGINE_URL" ]; then
        echo "✗ ERROR: No URL provided. Clone it manually:"
        echo "    git clone <emulation-engine-url> $ENGINE_DIR"
        exit 1
    fi
    git clone "$ENGINE_URL" "$ENGINE_DIR"
fi

echo "Setting up Python backend at $ENGINE_DIR..."
cd "$ENGINE_DIR"

# Git LFS — fetch the Renode binary
if [ -d ".git" ]; then
    echo "Initializing Git LFS..."
    git lfs install
    echo "Fetching LFS files (Renode binary)..."
    git lfs pull
else
    echo "⚠ Warning: emulation_engine is not a git repository, skipping Git LFS"
fi

# Install Python dependencies
echo "Installing Python packages with pipenv..."
export PIPENV_IGNORE_VIRTUALENVS=1
export PIPENV_VERBOSITY=-1
pipenv install --dev 2>&1 | tee /tmp/pipenv_install.log
echo "Virtualenv location: $(pipenv --venv)"

# Verify Renode
RENODE_BIN="$ENGINE_DIR/renode_1.16.0-dotnet_portable/renode"
if [ -f "$RENODE_BIN" ]; then
    chmod +x "$RENODE_BIN"
    echo "✓ Renode binary found at $RENODE_BIN"
else
    echo "⚠ Warning: Renode binary not found at $RENODE_BIN"
    echo "  If using Git LFS, run: cd $ENGINE_DIR && git lfs pull"
fi

echo "✓ Python backend ready"

# ---------------------------------------------------------------------------
# 4. Dart workspace — resolve dependencies for both packages
# ---------------------------------------------------------------------------
WORKSPACE_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKSPACE_ROOT"

echo "Resolving Dart workspace dependencies..."
dart pub get

echo "✓ Dart workspace ready"

# ---------------------------------------------------------------------------
# 5. VirtualBox (from Oracle's repository — Ubuntu's package lags behind
#    new kernels and the DKMS module often fails to build)
# ---------------------------------------------------------------------------
echo "Installing VirtualBox from Oracle repository..."
sudo apt-get install -y linux-headers-$(uname -r)

wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] \
  https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" \
  | sudo tee /etc/apt/sources.list.d/virtualbox.list
sudo apt-get update -q && sudo apt-get install -y virtualbox-7.2

if ! command -v vboxmanage &>/dev/null; then
    echo "✗ ERROR: VirtualBox failed to install (vboxmanage not found)"
    exit 1
fi

# Build kernel modules (Oracle's package doesn't always auto-build them)
sudo /sbin/vboxconfig

# Verify the kernel module is loaded
if ! lsmod | grep -q vboxdrv; then
    echo "✗ ERROR: VirtualBox kernel module (vboxdrv) failed to load."
    echo "  Try: sudo /sbin/vboxconfig"
    exit 1
fi

echo "✓ VirtualBox $(vboxmanage --version) installed"

# ---------------------------------------------------------------------------
# 6. Vagrant
# ---------------------------------------------------------------------------
echo "Installing Vagrant..."
wget -qO- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update -q && sudo apt-get install -y vagrant

if ! command -v vagrant &>/dev/null; then
    echo "✗ ERROR: Vagrant failed to install"
    exit 1
fi

echo "✓ Vagrant $(vagrant --version) installed"

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
echo ""
echo "=== Verification ==="

echo -n "Flutter:       "; flutter --version 2>/dev/null | head -1
echo -n "Dart:          "; dart --version 2>&1
echo -n "pipenv:        "; pipenv --version 2>/dev/null || echo "not found"
echo -n "arm-objdump:   "; which arm-none-eabi-objdump 2>/dev/null || echo "not found"
echo -n "Renode:        "; [ -x "$RENODE_BIN" ] && echo "$RENODE_BIN" || echo "not found"
echo -n "VirtualBox:    "; vboxmanage --version 2>/dev/null || echo "not found"
echo -n "Vagrant:       "; vagrant --version 2>/dev/null || echo "not found"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "To run the GUI:   ./run.sh"
echo "To use the CLI:   dart run emulator_orchestrator:cli --help"
echo "To run the API:   dart run emulator_orchestrator:server --help"
