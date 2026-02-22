#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ensure script is run with sudo
# ============================================================
if [[ $EUID -ne 0 ]]; then
  echo "[!] This script must be run with sudo."
  echo "    Usage: sudo $0"
  exit 1
fi

# ============================================================
# Directory containing YAML files
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Loop through YAML experiment files
# ============================================================
for yaml in "$SCRIPT_DIR"/exp_*.yaml; do
  if [[ -f "$yaml" ]]; then
    echo "===================================================="
    echo "[RUNNING] $yaml"
    echo "===================================================="

    bash "$SCRIPT_DIR/iperf+old.sh" "$yaml"

    echo
    echo "[DONE] $yaml"
    echo
  fi
done

echo "All experiments completed."
