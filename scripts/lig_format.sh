#!/usr/bin/env bash
# lig_format.sh - domeeko ligand format + QC pipeline
# v0.3.0 (stable architecture)

set -euo pipefail

LIG_FORMAT_VERSION="0.3.0"

# ==========================================================
# LOGGING
# ==========================================================
lig_log() {
    local level="$1"
    local msg="$2"

    echo "[$level] $msg"

    if [[ -n "${LIG_LOG:-}" ]]; then
        echo "[$level] $msg" >> "$LIG_LOG"
    fi
}

# ==========================================================
# DEPENDENCY CHECK
# ==========================================================
check_tools() {
    command -v obabel >/dev/null 2>&1 || {
        lig_log ERROR "OpenBabel not found"
        return 1
    }

    if python3 -c "import rdkit" >/dev/null 2>&1; then
        RDKIT_AVAILABLE=true
    else
        RDKIT_AVAILABLE=false
        lig_log INFO "RDKit not available (fallback disabled)"
    fi

    lig_log INFO "Chemical toolchain OK"
}

# ==========================================================
# FILE TYPE DETECTION
# ==========================================================
detect_format() {
    echo "${1##*.}" | tr '[:upper:]' '[:lower:]'
}

# ==========================================================
# OBABEL CONVERSION
# ==========================================================
obabel_convert() {
    local infile="$1"
    local outfile="$2"
    local remove_salt="$3"
    local add_h="$4"

    local cmd=(obabel "$infile" -O "$outfile")

    [[ "$remove_salt" == "true" ]] && cmd+=(-r)
    [[ "$add_h" == "true" ]] && cmd+=(-h)

    "${cmd[@]}" >/dev/null 2>&1
}

# ==========================================================
# RDKit FALLBACK CONVERSION
# ==========================================================
rdkit_convert() {
    local infile="$1"
    local outfile="$2"

    python3 <<EOF
from rdkit import Chem

suppl = Chem.SDMolSupplier("$infile", removeHs=False)
w = Chem.SDWriter("$outfile")

count = 0
for mol in suppl:
    if mol:
        w.write(mol)
        count += 1

w.close()

if count == 0:
    raise SystemExit(1)
EOF
}

# ==========================================================
# FILTERING
# ==========================================================
passes_filters() {
    local molfile="$1"

    python3 <<EOF
from rdkit import Chem
from rdkit.Chem import Descriptors

mw_min = float("${mw_min:-0}")
mw_max = float("${mw_max:-2000}")
min_atoms = int("${min_atoms:-0}")
max_atoms = int("${max_atoms:-500}")

suppl = Chem.SDMolSupplier("$molfile", removeHs=False)

for mol in suppl:
    if not mol:
        continue

    mw = Descriptors.MolWt(mol)
    nat = mol.GetNumHeavyAtoms()

    if mw_min <= mw <= mw_max and min_atoms <= nat <= max_atoms:
        raise SystemExit(0)

raise SystemExit(1)
EOF
}

# ==========================================================
# CHEMICAL QC (Lipinski + PAINS)
# ==========================================================
chemical_qc() {
    local molfile="$1"

    python3 <<EOF
from rdkit import Chem
from rdkit.Chem import Descriptors, Lipinski
from rdkit.Chem.FilterCatalog import FilterCatalog, FilterCatalogParams
import os

run_lipinski = os.environ.get("run_lipinski", "False") == "True"
run_pains = os.environ.get("run_pains", "False") == "True"

suppl = Chem.SDMolSupplier("$molfile", removeHs=False)

params = FilterCatalogParams()
params.AddCatalog(FilterCatalogParams.FilterCatalogs.PAINS_A)
catalog = FilterCatalog(params)

for mol in suppl:
    if mol is None:
        continue

    mw = Descriptors.MolWt(mol)
    logp = Descriptors.MolLogP(mol)
    hbd = Lipinski.NumHDonors(mol)
    hba = Lipinski.NumHAcceptors(mol)

    if run_lipinski:
        if mw > 500 or logp > 5 or hbd > 5 or hba > 10:
            continue

    if run_pains:
        if catalog.HasMatch(mol):
            continue

    exit(0)

exit(1)
EOF
}

# ==========================================================
# SPLIT MULTI-MODEL (SAFE + DETECTABLE)
# ==========================================================
split_multimol_backup() {
    local infile="$1"
    local split_dir="$2"
    local base="$3"

    mkdir -p "$split_dir"

#    lig_log INFO "Checking multi-model structure: $base"

    # Attempt split
    if obabel "$infile" -osdf -m -O "$split_dir/${base}_model.sdf" >/dev/null 2>&1; then

        local i=1
        local found=0

        for f in "$split_dir/${base}_model"*.sdf; do
            [[ -f "$f" ]] || continue
            mv "$f" "$split_dir/${base}_${i}.sdf"
            ((i++))
            found=1
        done

        if [[ $found -eq 1 ]]; then
            lig_log INFO "Multi-model split: $((i-1)) structures"
            return 0
        fi
    fi

    # fallback single
    cp "$infile" "$split_dir/${base}_1.sdf"
    lig_log INFO "Single structure assumed"
}

split_multimol() {

    local infile="$1"
    local split_dir="$2"
    local base="$3"

    mkdir -p "$split_dir"

#    lig_log INFO "Checking multi-model structure: $base"

    # Step 1: split using OpenBabel
    obabel "$infile" -osdf -m -O "$split_dir/${base}_raw.sdf" >/dev/null 2>&1 || {
        lig_log INFO "Single structure assumed"
        cp "$infile" "$split_dir/${base}_1.sdf"
        return 0
    }

    # Step 2: rename using FIRST LINE (title / CID)
    local i=1

    for f in "$split_dir/${base}_raw"*.sdf; do
        [[ -f "$f" ]] || continue

        # Extract first line (molecule title in SDF)
        local title
        title=$(head -n 1 "$f" | tr -cd '[:alnum:]_-')

        # fallback if empty
        [[ -z "$title" ]] && title="${base}_${i}"

        mv "$f" "$split_dir/${title}.sdf"

        ((i++))
    done

#    lig_log INFO "Multi-model split: renamed structures = $((i-1))"
}

# ==========================================================
# PROCESS SINGLE MOLECULE (PURE FUNCTION)
# ==========================================================
process_single_file() {

    local infile="$1"
    local outdir="$2"
    local outtype="$3"
    local tmpdir="$4"

    local base
    base="$(basename "${infile%.*}")"

#    lig_log INFO "Processing: $base"

    local intermediate="$tmpdir/${base}.sdf"
    local final_out="$outdir/${base}.${outtype}"

    # STEP 1: convert
    if ! obabel_convert "$infile" "$intermediate" "$remove_salt" "$add_h"; then
        lig_log INFO "OBabel fallback → RDKit"
        if [[ "$RDKIT_AVAILABLE" == true ]]; then
            rdkit_convert "$infile" "$intermediate" || {
                lig_log ERROR "Conversion failed: $base"
                return 1
            }
        else
            lig_log ERROR "No converter available"
            return 1
        fi
    fi

    # STEP 2: filters
    if [[ "$run_filters" == true ]]; then
        passes_filters "$intermediate" || {
            lig_log ERROR "Filter failed: $base"
            return 1
        }
    fi

    # STEP 3: QC
    if [[ "$run_lipinski" == true || "$run_pains" == true ]]; then
        chemical_qc "$intermediate" || {
            lig_log ERROR "QC failed: $base"
            return 1
        }
    fi

    # STEP 4: output
    if [[ "$outtype" == "sdf" ]]; then
        cp "$intermediate" "$final_out"
    else
        obabel_convert "$intermediate" "$final_out" "false" "false" || {
            lig_log ERROR "Final conversion failed: $base"
            return 1
        }
    fi

    lig_log INFO "Output: $final_out"
}

# ==========================================================
# MAIN PIPELINE
# ==========================================================
lig_format_main() {

    local input=""
    local outdir=""
    local outtype="sdf"

    remove_salt=true
    add_h=true

    run_filters=false
    run_lipinski=false
    run_pains=false

    mw_min=0
    mw_max=2000
    min_atoms=0
    max_atoms=500

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input) input="$2"; shift 2 ;;
            --outdir) outdir="$2"; shift 2 ;;
            --outtype) outtype="$2"; shift 2 ;;
            --remove_salt) remove_salt="$2"; shift 2 ;;
            --add_h) add_h="$2"; shift 2 ;;
            --filter) run_filters=true; shift ;;
            --mw_min) mw_min="$2"; shift 2 ;;
            --mw_max) mw_max="$2"; shift 2 ;;
            --atoms_min) min_atoms="$2"; shift 2 ;;
            --atoms_max) max_atoms="$2"; shift 2 ;;
            --lipinski) run_lipinski=true; shift ;;
            --pains) run_pains=true; shift ;;
            *) lig_log ERROR "Unknown option: $1"; return 1 ;;
        esac
    done

    [[ -z "$input" ]] && {
        lig_log ERROR "Input required"
        return 1
    }

    check_tools || return 1

    # output setup
    [[ -z "$outdir" ]] && outdir="${input%.*}_${outtype}_out"
    mkdir -p "$outdir"

    TMP_DIR="$outdir/.tmp"
    mkdir -p "$TMP_DIR"

    LIG_LOG="$outdir/lig_format.log"

    lig_log INFO "Ligand formatter v$LIG_FORMAT_VERSION"
    lig_log INFO "Input: $input"

    # detect input mode
    local input_mode="file"
    [[ -d "$input" ]] && input_mode="dir"

    # ------------------------------------------------------
    # PROCESS
    # ------------------------------------------------------
    if [[ "$input_mode" == "dir" ]]; then

        for f in "$input"/*; do
            [[ -f "$f" ]] || continue

            local base
            base="$(basename "${f%.*}")"

            local split_dir="$TMP_DIR/split_$base"
            split_multimol "$f" "$split_dir" "$base"

            for mol in "$split_dir"/*.sdf; do
                [[ -f "$mol" ]] || continue
                process_single_file "$mol" "$outdir" "$outtype" "$TMP_DIR"
            done
        done

    else
        local base
        base="$(basename "${input%.*}")"

        local split_dir="$TMP_DIR/split_$base"
        split_multimol "$input" "$split_dir" "$base"

        for mol in "$split_dir"/*.sdf; do
            [[ -f "$mol" ]] || continue
            process_single_file "$mol" "$outdir" "$outtype" "$TMP_DIR"
        done
    fi

    rm -rf "$TMP_DIR"

    lig_log INFO "DONE"
}

# ==========================================================
# CLI ENTRY
# ==========================================================
lig_format() {
    lig_format_main "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    lig_format "$@"
fi