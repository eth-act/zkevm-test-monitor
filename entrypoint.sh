#!/bin/bash
set -eu

# Expected volumes:
# /dut/bin - contains the DUT executable
# /dut/plugin - contains the plugin directory

# Check if DUT binary is provided
if [ ! -d "/dut/bin" ] || [ -z "$(ls -A /dut/bin)" ]; then
  echo "Error: No DUT binary found. Please mount a directory containing the DUT executable to /dut/bin"
  echo "Example: docker run -v /path/to/dut/binary:/dut/bin ..."
  exit 1
fi

# Check if DUT plugin is provided
if [ ! -d "/dut/plugin" ] || [ -z "$(ls -A /dut/plugin)" ]; then
  echo "Error: No DUT plugin found. Please mount the plugin directory to /dut/plugin"
  echo "Example: docker run -v /path/to/plugin:/dut/plugin ..."
  exit 1
fi

DUT_EXECUTABLE="/dut/bin/dut-exe"

# If no known executable found, find any executable
if [ -z "$DUT_EXECUTABLE" ]; then
  DUT_EXECUTABLE=$(find /dut/bin -type f -executable -name "*vm" | head -n1)
fi

# Still nothing? Try any executable
if [ -z "$DUT_EXECUTABLE" ]; then
  DUT_EXECUTABLE=$(find /dut/bin -type f -executable | grep -v "build_script" | head -n1)
fi

if [ -z "$DUT_EXECUTABLE" ]; then
  echo "Error: No suitable executable found in /dut/bin"
  echo "Found files:"
  ls -la /dut/bin/
  exit 1
fi

# Get the base name of the executable
DUT_NAME=$(basename "$DUT_EXECUTABLE")
echo "Found DUT executable: $DUT_NAME"

# Find the plugin name by looking for the Python file
PLUGIN_PY=$(find /dut/plugin -name "riscof_*.py" | head -n1)
if [ -z "$PLUGIN_PY" ]; then
  echo "Error: No riscof_*.py file found in /dut/plugin"
  exit 1
fi

# Extract plugin name from the Python file name
PLUGIN_NAME=$(basename "$PLUGIN_PY" | sed 's/riscof_//' | sed 's/\.py$//')
echo "Found plugin: $PLUGIN_NAME"

# Copy plugin contents to plugins directory
echo "Setting up plugin..."
mkdir -p "/riscof/plugins/$PLUGIN_NAME"
cp -r /dut/plugin/* "/riscof/plugins/$PLUGIN_NAME/"

# Create __init__.py files to make proper Python packages
touch "/riscof/plugins/__init__.py"
cat >"/riscof/plugins/$PLUGIN_NAME/__init__.py" <<'EOF'
from pkgutil import extend_path
__path__ = extend_path(__path__, __name__)
EOF

# Make DUT executable available in PATH
mkdir -p /riscof/dut-bin
cp "$DUT_EXECUTABLE" "/riscof/dut-bin/"
chmod +x "/riscof/dut-bin/$DUT_NAME"
export PATH="/riscof/dut-bin:$PATH"

# Generate config.ini dynamically
echo "Generating config.ini for $PLUGIN_NAME..."
cat >/riscof/config.ini <<EOF
[RISCOF]
ReferencePlugin=sail_cSim
ReferencePluginPath=plugins/sail_cSim
DUTPlugin=$PLUGIN_NAME
DUTPluginPath=plugins/$PLUGIN_NAME

[$PLUGIN_NAME]
pluginpath=plugins/$PLUGIN_NAME
ispec=plugins/$PLUGIN_NAME/${PLUGIN_NAME}_isa.yaml
pspec=plugins/$PLUGIN_NAME/${PLUGIN_NAME}_platform.yaml
target_run=1
PATH=/riscof/dut-bin/
jobs=48

[sail_cSim]
pluginpath=plugins/sail_cSim
PATH=/riscof/emulators/sail-riscv/bin/
jobs=48
EOF

# Clear results directory except .keep file
if [ -d "/riscof/riscof_work" ]; then
  echo "Clearing previous results..."
  find /riscof/riscof_work -mindepth 1 -name .keep -prune -o -exec rm -rf {} + 2>/dev/null || true
fi

# If command line arguments are provided, run them
# Otherwise, run the default riscof command
if [ $# -eq 0 ]; then
  echo "Running RISCOF tests..."
  exec riscof run --config=/riscof/config.ini --suite=/riscof/riscv-arch-test/riscv-test-suite/ --env=/riscof/riscv-arch-test/riscv-test-suite/env --no-clean
else
  exec "$@"
fi
