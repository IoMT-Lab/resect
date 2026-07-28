#!/bin/bash
set -e

# Opt-in flags
WITH_VAGRANT_TEST=0
for arg in "$@"; do
    case "$arg" in
        --with-vagrant-test) WITH_VAGRANT_TEST=1 ;;
        -h|--help)
            cat <<EOF
Usage: ./install.sh [--with-vagrant-test]

Options:
  --with-vagrant-test  Also install VirtualBox + Vagrant for the CI/CD
                       test harness. Adds ~250 MB plus DKMS kernel modules.
                       Skip this unless you specifically need the
                       "Run Vagrant Test" feature.
  -h, --help           Show this help.
EOF
            exit 0
            ;;
    esac
done

echo "=== Resect — Installation ==="
if [ "$WITH_VAGRANT_TEST" -eq 1 ]; then
    echo "  (including VirtualBox + Vagrant for CI test harness)"
fi
echo ""

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared configuration — source it so values set by the System Configuration UI
# (or a prior install) take precedence over the built-in detection below.
if [ -f "$INSTALL_DIR/resect.config" ]; then
    # shellcheck disable=SC1091
    source "$INSTALL_DIR/resect.config"
fi

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  binutils-arm-none-eabi \
  git git-lfs \
  curl unzip wget lsb-release \
  software-properties-common

# Flutter's Linux build uses clang++, which links against libstdc++. Install
# the libstdc++-N-dev package matching the GCC install clang has selected
# (clang's default GCC pick can be newer than what `g++` would pull in, so
# relying on `apt install g++` is unreliable on rolling distros).
GCC_VERSION=$(clang++ -v -E - </dev/null 2>&1 \
  | grep -oP 'Selected GCC installation:.*/\K[0-9]+' | head -1)
if [ -n "$GCC_VERSION" ]; then
    echo "clang selects GCC $GCC_VERSION; installing libstdc++-${GCC_VERSION}-dev"
    sudo apt-get install -y "libstdc++-${GCC_VERSION}-dev"
else
    echo "⚠ Could not detect clang's GCC version; falling back to g++ default"
    sudo apt-get install -y g++
fi

echo "✓ System packages installed"

# ---------------------------------------------------------------------------
# 2. Flutter SDK (git install — snap has issues with Linux desktop builds)
# ---------------------------------------------------------------------------
# Locate an existing Flutter install before cloning. Order:
#   1. `flutter` on the user's PATH (any shell-managed install)
#   2. ~/Development/flutter (capital D — matches this repo's convention)
#   3. ~/development/flutter (lowercase — older convention)
# Only clone a fresh copy when none of those exist.
if [ -n "$FLUTTER_DIR" ] && [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    echo "✓ Flutter from resect.config at $FLUTTER_DIR"
elif command -v flutter >/dev/null 2>&1; then
    FLUTTER_DIR="$(dirname "$(dirname "$(command -v flutter)")")"
    echo "✓ Flutter already on PATH at $FLUTTER_DIR"
elif [ -x "$HOME/Development/flutter/bin/flutter" ]; then
    FLUTTER_DIR="$HOME/Development/flutter"
    echo "✓ Flutter already installed at $FLUTTER_DIR"
elif [ -x "$HOME/development/flutter/bin/flutter" ]; then
    FLUTTER_DIR="$HOME/development/flutter"
    echo "✓ Flutter already installed at $FLUTTER_DIR"
else
    FLUTTER_DIR="$HOME/Development/flutter"
    echo "Installing Flutter SDK to $FLUTTER_DIR..."
    git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_DIR"
fi

# Ensure Flutter is on PATH for the rest of this script
export PATH="$FLUTTER_DIR/bin:$PATH"

# Add to shell profile only if `flutter` isn't already found by new shells.
# Test in a clean subshell so the export above doesn't mask it.
if ! env -i HOME="$HOME" bash -lc 'command -v flutter' >/dev/null 2>&1; then
    echo '' >> "$HOME/.bashrc"
    echo '# Flutter SDK' >> "$HOME/.bashrc"
    echo "export PATH=\"$FLUTTER_DIR/bin:\$PATH\"" >> "$HOME/.bashrc"
    echo "Added $FLUTTER_DIR/bin to ~/.bashrc PATH"
fi

echo "Flutter version: $(flutter --version --machine 2>/dev/null | head -1 || flutter --version | head -1)"

# Pre-cache only Linux desktop artifacts — `flutter precache` with no args
# also downloads Android, iOS, web, Windows, and macOS bits we never use.
flutter precache --linux
flutter config --enable-linux-desktop \
  --no-enable-android --no-enable-ios --no-enable-web \
  --no-enable-windows-desktop --no-enable-macos-desktop

echo "✓ Flutter SDK ready"


# ---------------------------------------------------------------------------
# 4. Dart workspace — resolve dependencies for both packages
# ---------------------------------------------------------------------------
WORKSPACE_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKSPACE_ROOT"

echo "Resolving Dart workspace dependencies..."
dart pub get

echo "✓ Dart workspace ready"

# ---------------------------------------------------------------------------
# 5 & 6. VirtualBox + Vagrant (opt-in — only needed for the CI test harness)
# ---------------------------------------------------------------------------
if [ "$WITH_VAGRANT_TEST" -eq 1 ]; then
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

    if ! lsmod | grep -q vboxdrv; then
        echo "✗ ERROR: VirtualBox kernel module (vboxdrv) failed to load."
        echo "  Try: sudo /sbin/vboxconfig"
        exit 1
    fi

    echo "✓ VirtualBox $(vboxmanage --version) installed"

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
else
    echo "Skipping VirtualBox + Vagrant (re-run with --with-vagrant-test to install)."
fi

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
echo ""
echo "=== Verification ==="

echo -n "Flutter:       "; flutter --version 2>/dev/null | head -1
echo -n "Dart:          "; dart --version 2>&1
echo -n "arm-objdump:   "; which arm-none-eabi-objdump 2>/dev/null || echo "not found"
if [ "$WITH_VAGRANT_TEST" -eq 1 ]; then
    echo -n "VirtualBox:    "; vboxmanage --version 2>/dev/null || echo "not found"
    echo -n "Vagrant:       "; vagrant --version 2>/dev/null || echo "not found"
fi

echo ""

# ---------------------------------------------------------------------------
# Seed resect.config — the shared source of truth for the app and scripts.
# Only fills keys that aren't already present, so UI edits survive re-runs.
# ---------------------------------------------------------------------------
CONFIG_FILE="$INSTALL_DIR/resect.config"
if [ ! -f "$CONFIG_FILE" ]; then
    {
        echo "# resect.config"
        echo "# Shared by install.sh / run.sh and the System Configuration UI."
    } > "$CONFIG_FILE"
fi

write_default() {  # key value — append only if the key is not already set
    if ! grep -q "^$1=" "$CONFIG_FILE" 2>/dev/null; then
        echo "$1=\"$2\"" >> "$CONFIG_FILE"
    fi
}

write_default FLUTTER_DIR "$FLUTTER_DIR"
write_default RENODE_PORT "${RENODE_PORT:-5000}"
write_default ARM_OBJDUMP "$(command -v arm-none-eabi-objdump || echo arm-none-eabi-objdump)"
write_default X86_OBJDUMP "$(command -v objdump || echo objdump)"
echo "✓ Wrote $CONFIG_FILE"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "To run the GUI:   ./run.sh"
echo "To use the CLI:   dart run emulator_orchestrator:cli --help"
echo "To run the API:   dart run emulator_orchestrator:server --help"
