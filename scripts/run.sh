#!/usr/bin/env bash
#
# Script to manage a micromamba environment 'domeeko' with required packages.
# Provides functions to check WSL, create/activate the environment.
# When sourced, it defines functions for later use.
# When executed directly, it checks/creates the environment and prints activation instructions.
#
# Usage:
#   source script.sh             # define functions
#   activate_domeeko             # create (if needed) and activate environment
#   check_wsl                    # check if running under WSL
#   check_env_domeeko            # check if environment exists
#   create_env_domeeko           # create environment from scratch
#
#   ./script.sh                  # direct execution: check status and show activation command
#

set -euo pipefail

# ---------- Functions ----------

# Check if running under WSL
check_wsl() {
    if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/sys/kernel/osrelease 2>/dev/null; then
        echo "✅ WSL is active (running under WSL)."
        return 0
    else
        echo "❌ Not running under WSL (or WSL detection failed)."
        return 1
    fi
}

# Check if micromamba is available
check_micromamba() {
    if command -v micromamba >/dev/null 2>&1; then
        echo "✅ micromamba found: $(command -v micromamba)"
        return 0
    else
        echo "❌ micromamba not found in PATH. Please install micromamba first:"
        echo "   https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html"
        return 1
    fi
}

# Check if environment 'domeeko' exists
check_env_domeeko() {
    if check_micromamba >/dev/null 2>&1; then
        if micromamba env list | awk '{print $1}' | grep -qx 'domeeko'; then
            echo "✅ Environment 'domeeko' exists."
            return 0
        else
            echo "❌ Environment 'domeeko' does NOT exist."
            return 1
        fi
    else
        return 1
    fi
}

# Create environment 'domeeko' with required packages
create_env_domeeko() {
    echo "🔧 Creating micromamba environment 'domeeko'..."
    if ! check_micromamba; then
        return 1
    fi
    # Use conda-forge channel and specify version constraints
    micromamba create -c conda-forge -n domeeko \
        "python>=3.10,<3.13" \
        "rdkit>=2023.09" \
        "openbabel>=3.1.1" \
        "vina>=1.2.5" \
        "meeko>=0.7" \
        -y
    echo "✅ Environment 'domeeko' created successfully."
}

# Activate environment 'domeeko' in current shell (only works when script is sourced)
# If environment does not exist, it creates it first.
activate_domeeko() {
    if ! check_micromamba; then
        echo "❌ Cannot activate: micromamba not available."
        return 1
    fi
    if ! check_env_domeeko >/dev/null 2>&1; then
        echo "Environment missing. Creating it now..."
        create_env_domeeko || return 1
    fi
    # Initialize micromamba shell hooks for bash (if not already done)
    if ! type __micromamba_env_activate >/dev/null 2>&1; then
        eval "$(micromamba shell hook --shell bash)"
    fi
    micromamba activate domeeko
    echo "✅ Environment 'domeeko' activated. Current prefix: $CONDA_PREFIX"
}

# ---------- Main (when script is executed directly, not sourced) ----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Domeeko Environment Management ==="
    check_wsl
    check_micromamba || exit 1

    if check_env_domeeko >/dev/null 2>&1; then
        echo "✅ Environment 'domeeko' is ready."
    else
        echo "Environment not found. Creating it now..."
        create_env_domeeko || exit 1
    fi

    echo ""
    echo "To activate the environment in this shell, run:"
    echo "  source $0   # first load the functions"
    echo "  activate_domeeko"
    echo "Or directly use micromamba: micromamba activate domeeko"
source domeeko.sh
fi

