#!/usr/bin/env bash
# domeeko - modular CLI for docking preparation and docking
set -euo pipefail

if [[ -n "${CONDA_PREFIX:-}" && -d "${CONDA_PREFIX}/share/domeeko/scripts" ]]; then
    SCRIPT_DIR="${CONDA_PREFIX}/share/domeeko/scripts"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
fi
source "$SCRIPT_DIR/prep.sh"
source "$SCRIPT_DIR/dock.sh"
source "$SCRIPT_DIR/center.sh"

CONFIG_FILE="$HOME/.domeekorc"

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# Domeeko configuration
USE_MGL=${USE_MGL:-false}
MGL=${MGL:-}
RECEPTOR_PDB=${RECEPTOR_PDB:-}
LIGAND_DIR=${LIGAND_DIR:-}
MMFF_STEPS=${MMFF_STEPS:-5000}
FORCE_FIELD=${FORCE_FIELD:-MMFF94}
EXHAUSTIVENESS=${EXHAUSTIVENESS:-8}
CPU=${CPU:-4}
PADDING=${PADDING:-5}
SEED=${SEED:-42}
OUTDIR=${OUTDIR:-docking_results}
LOGDIR=${LOGDIR:-logs}
RANK_OUTPUT=${RANK_OUTPUT:-ranked_results.csv}
EOF
    echo "Configuration saved to $CONFIG_FILE"
}

usage() {
    cat <<EOF
domeeko - Modular docking preparation and docking

USAGE:
  domeeko lig_prep --lig_dir DIR [--steps N] [--ff NAME]
  domeeko rec_prep --receptor FILE [--use_mgl] [--mgl_path PATH]
  domeeko full --receptor FILE --lig_dir DIR [options]
  domeeko dock --receptor FILE --lig_pdbqt DIR [options]
  domeeko rank --logdir DIR [--output CSV]
  domeeko config [--set KEY=VALUE] [--save]
  domeeko get_center --pdb_file FILE [--ligname NAME] [--res_num NUM] [--chain A] [--list-ligands] [--write-ligands] [--out FILE]

OPTIONS for prep:
  --steps N          MMFF optimization steps (default: 5000)
  --ff NAME          Force field (MMFF94, UFF, etc.)
  --use_mgl          Use MGLTools legacy pipeline
  --mgl_path PATH    Path to MGLTools installation

OPTIONS for docking:
  --exhaustiveness N (default: 8)
  --cpu N            (default: 4)
  --padding N        (default: 5)
  --seed N           (default: 42)
  --outdir DIR       (default: docking_results)
  --logdir DIR       (default: logs)
  --box CX CY CZ SX SY SZ  (manual box)

EXAMPLES:
  domeeko lig_prep --lig_dir my_ligands
  domeeko rec_prep --receptor protein/clean.pdb
  domeeko full --receptor protein/clean.pdb --lig_dir ligands
  domeeko dock --receptor protein.pdbqt --lig_pdbqt pdbqt_out -e 16
  domeeko rank --logdir logs --output top20.csv
EOF
}

cmd_lig_prep() {
    load_config
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lig_dir) ligdir="$2"; shift 2 ;;
            --steps) steps_mmff="$2"; shift 2 ;;
            --ff) ff="$2"; shift 2 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "$ligdir" ]] && { echo "ERROR: --lig_dir required"; exit 1; }
    ensure_docking_env
    ligand_3d_gen
    ligand_pdbqt_convert
}

cmd_rec_prep() {
    load_config
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --receptor) recpdb="$2"; shift 2 ;;
            --use_mgl) USE_MGL=true; shift ;;
            --mgl_path) MGL="$2"; shift 2 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "$recpdb" ]] && { echo "ERROR: --receptor required"; exit 1; }
    ensure_docking_env
    receptor_qc
    if $USE_MGL; then
        split_alt_mgl
        receptor_prep_mgl
    else
        receptor_prep_meeko
    fi
}

cmd_full() {
    load_config   # Load defaults for steps, ff, etc.
    local rec="" ligd=""
    local use_mgl=false
    local mgl_path=""
    local steps_val="$steps_mmff"
    local ff_val="$ff"
    # Docking parameters (will override config if provided)
    local exhaust="$EXHAUSTIVENESS"
    local cpu_cores="$CPU"
    local pad="$PADDING"
    local seed_val="$SEED"
    local out_dir="$OUTDIR"
    local log_dir="$LOGDIR"
    local skip_rank=0
    # Manual box defaults (empty)
    local manual_box=0
    local cx="" cy="" cz="" sx="" sy="" sz=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --receptor) rec="$2"; shift 2 ;;
            --lig_dir) ligd="$2"; shift 2 ;;
            --steps) steps_val="$2"; shift 2 ;;
            --ff) ff_val="$2"; shift 2 ;;
            --use_mgl) use_mgl=true; shift ;;
            --mgl_path) mgl_path="$2"; shift 2 ;;
            --exhaustiveness) exhaust="$2"; shift 2 ;;
            --cpu) cpu_cores="$2"; shift 2 ;;
            --padding) pad="$2"; shift 2 ;;
            --seed) seed_val="$2"; shift 2 ;;
            --outdir) out_dir="$2"; shift 2 ;;
            --logdir) log_dir="$2"; shift 2 ;;
            --no-rank) skip_rank=1; shift ;;
            --box) manual_box=1
                cx="$2"; cy="$3"; cz="$4"; sx="$5"; sy="$6"; sz="$7"
                shift 7 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "$rec" ]] && { echo "ERROR: --receptor required"; exit 1; }
    [[ -z "$ligd" ]] && { echo "ERROR: --lig_dir required"; exit 1; }

    # Set preparation variables
    recpdb="$rec"
    ligdir="$ligd"
    USE_MGL="$use_mgl"
    MGL="$mgl_path"
    steps_mmff="$steps_val"
    ff="$ff_val"

    # Set docking variables (override defaults)
    EXHAUSTIVENESS="$exhaust"
    CPU="$cpu_cores"
    PADDING="$pad"
    SEED="$seed_val"
    OUTDIR="$out_dir"
    LOGDIR="$log_dir"
    if [[ $manual_box -eq 1 ]]; then
        MANUAL_BOX=1
        CENTER_X="$cx"; CENTER_Y="$cy"; CENTER_Z="$cz"
        SIZE_X="$sx"; SIZE_Y="$sy"; SIZE_Z="$sz"
    else
        MANUAL_BOX=0
    fi

    # 1. Receptor preparation
    ensure_docking_env
    receptor_qc
    if $USE_MGL; then
        split_alt_mgl
        receptor_prep_mgl
        RECEPTOR="${recpdb%.*}_A.pdbqt"
    else
        receptor_prep_meeko
        RECEPTOR="${recpdb%.*}.pdbqt"
    fi

    # 2. Ligand preparation
    ligand_3d_gen
    ligand_pdbqt_convert
    LIGAND_DIR="$out_pdbqt"   # PDBQT output directory from ligand prep

    # 3. Docking
    batch_dock

    # 4. Ranking (unless skipped)
    if [[ $skip_rank -eq 0 ]]; then
        echo ""
        parse_and_rank
    else
        echo "Ranking skipped (--no-rank)."
    fi
}

cmd_get_center() {
    # Simply pass all arguments to fx_center_of_mass
    fx_center_of_mass "$@"
}

cmd_dock() {
    load_config
    local lig_pdbqt_dir="" rec=""
    local skip_rank=0   # new flag

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --receptor) rec="$2"; shift 2 ;;
            --lig_pdbqt) lig_pdbqt_dir="$2"; shift 2 ;;
            --exhaustiveness) EXHAUSTIVENESS="$2"; shift 2 ;;
            --cpu) CPU="$2"; shift 2 ;;
            --padding) PADDING="$2"; shift 2 ;;
            --seed) SEED="$2"; shift 2 ;;
            --outdir) OUTDIR="$2"; shift 2 ;;
            --logdir) LOGDIR="$2"; shift 2 ;;
            --no-rank) skip_rank=1; shift ;;
            --box) MANUAL_BOX=1
                CENTER_X="$2"; CENTER_Y="$3"; CENTER_Z="$4"
                SIZE_X="$5"; SIZE_Y="$6"; SIZE_Z="$7"
                shift 7 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done

    [[ -z "$rec" ]] && { echo "ERROR: --receptor required"; exit 1; }
    [[ -z "$lig_pdbqt_dir" ]] && { echo "ERROR: --lig_pdbqt required"; exit 1; }

    RECEPTOR="$rec"
    LIGAND_DIR="$lig_pdbqt_dir"

    # Run docking
    batch_dock

    # Run ranking unless --no-rank was given
    if [[ $skip_rank -eq 0 ]]; then
        echo ""
        parse_and_rank
    else
        echo "Ranking skipped (--no-rank)."
    fi
}

cmd_rank() {
    load_config
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logdir) LOGDIR="$2"; shift 2 ;;
            --output) RANK_OUTPUT="$2"; shift 2 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "$LOGDIR" ]] && { echo "ERROR: --logdir required"; exit 1; }
    parse_and_rank
}

cmd_config() {
    if [[ "$1" == "--save" ]]; then
        save_config
    elif [[ "$1" == "--set" ]]; then
        for arg in "${@:2}"; do
            export "$arg"
        done
        save_config
    else
        cat "$CONFIG_FILE" 2>/dev/null || echo "No config. Run 'domeeko config --save'."
    fi
}

COMMAND="${1:-}"
shift || true
case "$COMMAND" in
    lig_prep) cmd_lig_prep "$@" ;;
    rec_prep) cmd_rec_prep "$@" ;;
    get_center) cmd_get_center "$@" ;;
	full) cmd_full "$@" ;;
    dock) cmd_dock "$@" ;;
    rank) cmd_rank "$@" ;;
    config) cmd_config "$@" ;;
    -h|--help|help) usage ;;
    *) echo "Unknown command: $COMMAND"; usage; exit 1 ;;
esac