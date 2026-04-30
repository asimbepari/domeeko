#!/usr/bin/env bash
# dock.sh - docking/ranking functions (sourced by domeeko)
set -euo pipefail

# ---------------------------
# Defaults
# ---------------------------
RECEPTOR="${RECEPTOR:-}"
LIGAND_DIR="${LIGAND_DIR:-}"
OUTDIR="${OUTDIR:-docking_results}"
EXHAUSTIVENESS="${EXHAUSTIVENESS:-8}"
CPU="${CPU:-4}"
PADDING="${PADDING:-5}"
SEED="${SEED:-42}"
LOGDIR="${LOGDIR:-logs}"
RANK_OUTPUT="${RANK_OUTPUT:-ranked_results.csv}"
MANUAL_BOX="${MANUAL_BOX:-0}"
CENTER_X="${CENTER_X:-}"
CENTER_Y="${CENTER_Y:-}"
CENTER_Z="${CENTER_Z:-}"
SIZE_X="${SIZE_X:-}"
SIZE_Y="${SIZE_Y:-}"
SIZE_Z="${SIZE_Z:-}"

# ---------------------------
# Required tools check (same as prep.sh)
# ---------------------------
ensure_docking_env() {
    local missing_tools=()
    local required=(
        vina
        mk_prepare_receptor.py
        mk_prepare_ligand.py
        obabel
        python3
    )

    echo "[INFO] Checking for required docking tools..."

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_tools+=("$cmd")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required tools: ${missing_tools[*]}"
        echo "[INFO] Please activate a Conda/Mamba/Micromamba environment that contains:"
        echo "       meeko rdkit vina openbabel pdbfixer"
        echo "[INFO] Example: micromamba activate docking"
        exit 1
    fi

    echo "[INFO] All required tools found."

    RUN_CMD=()
}

# ---------------------------
# Grid box calculation
# ---------------------------
compute_or_use_box() {
    if [[ $MANUAL_BOX -eq 1 ]]; then
        center_x="$CENTER_X"; center_y="$CENTER_Y"; center_z="$CENTER_Z"
        size_x="$SIZE_X"; size_y="$SIZE_Y"; size_z="$SIZE_Z"
        echo "Using manual grid box:"
    else
        read center_x center_y center_z size_x size_y size_z <<< $(awk -v pad="$PADDING" '
        BEGIN { minx=miny=minz=1e9; maxx=maxy=maxz=-1e9 }
        /^ATOM/ { x=$7; y=$8; z=$9
                  if (x<minx) minx=x; if (x>maxx) maxx=x
                  if (y<miny) miny=y; if (y>maxy) maxy=y
                  if (z<minz) minz=z; if (z>maxz) maxz=z }
        END { cx=(minx+maxx)/2; cy=(miny+maxy)/2; cz=(minz+maxz)/2
              sx=(maxx-minx)+pad; sy=(maxy-miny)+pad; sz=(maxz-minz)+pad
              printf "%.4f %.4f %.4f %.4f %.4f %.4f", cx, cy, cz, sx, sy, sz }' "$RECEPTOR")
        echo "Computed grid box from receptor (padding=$PADDING Å):"
    fi
    printf "  center: %.2f %.2f %.2f\n  size:   %.2f %.2f %.2f\n" "$center_x" "$center_y" "$center_z" "$size_x" "$size_y" "$size_z"
}

# ---------------------------
# Backup existing logs
# ---------------------------
backup_logs() {
    if [[ -d "$LOGDIR" && -n "$(ls -A "$LOGDIR" 2>/dev/null)" ]]; then
        ts=$(date +"%Y%m%d_%H%M%S")
        backup_dir="${LOGDIR}_backup_${ts}"
        echo "[INFO] Backing up existing logs → $backup_dir"
        cp -r "$LOGDIR" "$backup_dir"
        rm -rf "$LOGDIR"/*
    fi
}

# ---------------------------
# Batch docking
# ---------------------------
batch_dock() {
    ensure_docking_env
    mkdir -p "$OUTDIR" "$LOGDIR"
    backup_logs
    compute_or_use_box

    shopt -s nullglob
    ligands=("$LIGAND_DIR"/*.pdbqt)
    if [[ ${#ligands[@]} -eq 0 ]]; then
        echo "ERROR: No PDBQT ligands found in $LIGAND_DIR"
        exit 1
    fi

    receptor_base=$(basename "$RECEPTOR" .pdbqt)
    for lig in "${ligands[@]}"; do
        base=$(basename "$lig" .pdbqt)
        echo "Docking: $base"
        "${RUN_CMD[@]}" vina \
            --receptor "$RECEPTOR" \
            --ligand "$lig" \
            --center_x "$center_x" --center_y "$center_y" --center_z "$center_z" \
            --size_x "$size_x" --size_y "$size_y" --size_z "$size_z" \
            --exhaustiveness "$EXHAUSTIVENESS" \
            --cpu "$CPU" \
            --num_modes 9 --energy_range 3 \
            --seed "$SEED" \
            --out "$OUTDIR/${base}_${receptor_base}.pdbqt" \
            > "$LOGDIR/${base}_${receptor_base}.log" 2>&1
    done
    echo "Docking complete. Logs in $LOGDIR"
}

# ---------------------------
# Parse Vina logs, rank by affinity, save sorted CSV, print top 10
# ---------------------------
parse_and_rank() {
    echo "======================================"
    echo "Ranking docking results"
    echo "======================================"

    shopt -s nullglob
    logs=("$LOGDIR"/*.log)

    if [[ ${#logs[@]} -eq 0 ]]; then
        echo "ERROR: No log files found in $LOGDIR"
        exit 1
    fi

    tmpfile=$(mktemp)

    # Write header
    echo "ligand,affinity_kcalmol" > "$RANK_OUTPUT"

    for log in "${logs[@]}"; do
        ligand=$(basename "$log" .log)
        # Extract the first affinity score (best mode) from Vina log
        score=$(awk '
            BEGIN {found=0}
            /-----\+------------\+----------\+----------/ {found=1; next}
            found && NF>=2 {
                print $2;
                exit
            }
        ' "$log")
        score=${score:-NA}
        echo "$ligand,$score" >> "$tmpfile"
    done

    # Sort numeric by affinity (lowest = best), NA values go to end
    sort -t',' -k2 -n "$tmpfile" >> "$RANK_OUTPUT"

    rm -f "$tmpfile"

    echo ""
    echo "======================================"
    echo "TOP 10 LIGANDS (best affinity first)"
    echo "======================================"

    # Display top 10 (header + 10 data rows)
    head -n 11 "$RANK_OUTPUT" | column -t -s','

    echo "======================================"
    echo "Ranking completed"
    echo "Log directory : $LOGDIR"
    echo "Output CSV    : $RANK_OUTPUT"
    echo "Ligands ranked: ${#logs[@]}"
    echo "======================================"
}


export -f ensure_docking_env batch_dock parse_and_rank compute_or_use_box backup_logs