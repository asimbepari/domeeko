#!/usr/bin/env bash
# prep.sh - ligand/receptor preparation functions (sourced by domeeko)
#set -uo pipefail

ORIGINAL_PATH="$PATH"

# ---------------------------
# Defaults (can be overridden by environment or wrapper)
# ---------------------------
USE_MGL="${USE_MGL:-false}"
MGL="${MGL:-}"
recpdb="${RECEPTOR_PDB:-}"
ligdir="${LIGAND_DIR:-}"
out_lig_3d="${OUT_LIG_3D:-sdf_3D}"
out_lig_pdbqt="${OUT_LIG_PDBQT:-pdbqt_out}"
out_pdbqt="$out_lig_pdbqt"

steps_mmff="${MMFF_STEPS:-5000}"
ff="${FORCE_FIELD:-MMFF94}"
report_dir="${REPORT_DIR:-prep_reports}"

# New optional arguments for OpenBabel ligand preparation
# Defaults: -h = yes, --gen3d = yes, --minimize = yes, --addpolarh = no
OBABEL_H="${OBABEL_H:-yes}"                 # -h (add all hydrogens)
OBABEL_GEN3D="${OBABEL_GEN3D:-yes}"         # --gen3d (generate 3D coordinates)
OBABEL_MINIMIZE="${OBABEL_MINIMIZE:-yes}"   # --minimize (geometry optimization)
OBABEL_ADDPOLARH="${OBABEL_ADDPOLARH:-no}"  # --polarh (add only polar hydrogens; used only if OBABEL_H=no)

# ---------------------------
# Required tools check (no automatic env creation)
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

    # Optional: check for existing 'docking' environment (info only)
    if command -v micromamba &>/dev/null; then
        if micromamba env list | grep -q "^docking "; then
            echo "[INFO] Micromamba environment 'docking' exists (but not required)."
        else
            echo "[INFO] No micromamba environment named 'docking' found; using current PATH."
        fi
    elif command -v conda &>/dev/null; then
        if conda env list | grep -q "^docking "; then
            echo "[INFO] Conda environment 'docking' exists (but not required)."
        else
            echo "[INFO] No conda environment named 'docking' found; using current PATH."
        fi
    else
        echo "[INFO] Neither micromamba nor conda detected; relying on system PATH."
    fi

    # No wrapper – run commands directly from PATH
    RUN_CMD=()
}

# ---------------------------
# Optional MGL split
# ---------------------------
split_alt_mgl() {
    $USE_MGL || return 0
    echo "[INFO] Splitting ALTLOC (MGLTools)..."
    "${RUN_CMD[@]}" pythonsh \
        "$MGL/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_pdb_split_alt_confs.py" \
        -r "$recpdb"
}

# ---------------------------
# Receptor prep: Meeko (default)
# ---------------------------
receptor_prep_meeko() {
    finalqt="${recpdb%.*}.pdbqt"
    cleaned_pdb="${recpdb%.*}_clean_tmp.pdb"
    log_file="${recpdb%.*}_meeko.log"

    echo "[INFO] Preparing receptor with Meeko..."

    # ---------------------------------------------------------
    # First attempt: raw receptor
    # ---------------------------------------------------------
    if "${RUN_CMD[@]}" mk_prepare_receptor.py \
        -i "$recpdb" \
        --write_pdbqt "$finalqt" \
        --default_altloc A \
        --allow_bad_res \
        2>&1 | tee "$log_file"
    then
        if [[ -f "$finalqt" ]]; then
            echo "[INFO] Receptor prepared (Meeko): $finalqt"
            return 0
        fi
    fi

    echo "[WARNING] Meeko failed on raw receptor."
    echo "[INFO] Attempting automatic cleanup of problematic records..."

    # ---------------------------------------------------------
    # Cleanup problematic PDB records
    # Removes records commonly causing Meeko polymer failures
    # ---------------------------------------------------------
    grep -Ev '^(CONECT|LINK|MASTER)' "$recpdb" | \
    sed '/^ANISOU/d' > "$cleaned_pdb"

    # ---------------------------------------------------------
    # Second attempt: cleaned receptor
    # ---------------------------------------------------------
    if "${RUN_CMD[@]}" mk_prepare_receptor.py \
        -i "$cleaned_pdb" \
        --write_pdbqt "$finalqt" \
        --default_altloc A \
        --allow_bad_res \
        2>&1 | tee -a "$log_file"
    then
        if [[ -f "$finalqt" ]]; then
            echo "[INFO] Receptor prepared after cleanup: $finalqt"
            return 0
        fi
    fi

    # ---------------------------------------------------------
    # Failure handling
    # ---------------------------------------------------------
    echo "[ERROR] Meeko receptor preparation failed."
    echo "[ERROR] See log file: $log_file"
    echo ""
    echo "[INFO] Suggested fixes:"
    echo "  1. Clean receptor manually"
    echo "  2. Remove problematic ligands/cofactors"
    echo "  3. Try MGLTools fallback:"
    echo "       domeeko rec_prep --use_mgl ..."
    echo ""

    return 1
}

# ---------------------------
# Receptor prep: MGLTools (legacy)
# ---------------------------
receptor_prep_mgl() {
    $USE_MGL || return 0
    finalrec="${recpdb%.*}_A.pdb"
    finalqt="${recpdb%.*}_A.pdbqt"
    "${RUN_CMD[@]}" pythonsh \
        "$MGL/MGLToolsPckgs/AutoDockTools/Utilities24/prepare_receptor4.py" \
        -r "$finalrec" -o "$finalqt" -A hydrogens
    echo "[INFO] Receptor prepared (MGLTools): $finalqt"
}

# ---------------------------
# Backup non-empty directory
# ---------------------------
backup_dir_if_nonempty_old() {
    local target_dir="$1"

    if [[ -d "$target_dir" && -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
        local ts
        local backup_dir

        ts=$(date +"%Y%m%d_%H%M%S")

        backup_dir="${target_dir}_backup_${ts}"

        echo "[INFO] Backing up existing directory:"
        echo "       $target_dir → $backup_dir"

        cp -r "$target_dir" "$backup_dir"

        rm -rf "${target_dir:?}/"*
    fi
}

backup_dir_if_nonempty() {
    local target_dir="$1"
    # Safety
    if [[ -z "$target_dir" || "$target_dir" == "/" ]]; then
        echo "[ERROR] Refusing to backup dangerous path: '$target_dir'"
        return 1
    fi

    # Check if directory exists and contains anything (including hidden files)
    if [[ -d "$target_dir" ]] && [[ -n "$(find "$target_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        local ts
        local backup_dir
        ts=$(date +"%Y%m%d_%H%M%S")
        backup_dir="${target_dir}_backup_${ts}"

        echo "[INFO] Backing up '$target_dir' → '$backup_dir'"

        # Use rsync if available, otherwise cp with error handling
        if command -v rsync &>/dev/null; then
            rsync -a "$target_dir/" "$backup_dir/" || {
                echo "[ERROR] rsync backup failed"
                return 1
            }
        else
            cp -r "$target_dir" "$backup_dir" || {
                echo "[ERROR] cp backup failed"
                return 1
            }
        fi

        # Remove contents of original directory (but keep the directory)
        find "$target_dir" -mindepth 1 -delete || {
            echo "[ERROR] Failed to clean original directory"
            return 1
        }
    fi
}

# ---------------------------
# Ligand 3D generation (SDF -> 3D SDF)
# ---------------------------
ligand_3d_gen() {

    backup_dir_if_nonempty "$out_lig_3d"
    mkdir -p "$out_lig_3d"

    echo "[INFO] Ligand 3D generation..."

    local OB_FAIL

    if ! "${RUN_CMD[@]}" obabel -V &>/dev/null; then
        echo "[WARN] OpenBabel unavailable → RDKit fallback"
        OB_FAIL=1
    else
        OB_FAIL=0
    fi

    shopt -s nullglob
    local ligs=("$ligdir"/*.sdf)

    if [[ ${#ligs[@]} -eq 0 ]]; then
        echo "[ERROR] No .sdf ligands found in:"
        echo "        $ligdir"
        exit 1
    fi

    local f
    local base
    local out
    local errfile

    count=0
    total=${#ligs[@]}

    for f in "${ligs[@]}"; do
        count=$((count + 1))
        base=$(basename "$f" .sdf)
        out="$out_lig_3d/${base}_3D.sdf"

        # -----------------------------------
        # OpenBabel attempt (with configurable options)
        # -----------------------------------
        if [[ "$OB_FAIL" -eq 0 ]]; then
            errfile=$(mktemp)

            # Build obabel command dynamically
            local ob_cmd=("${RUN_CMD[@]}" obabel "$f")

            # Hydrogen option: -h (all H) takes precedence over --polarh
            if [[ "${OBABEL_H}" == "yes" ]]; then
                ob_cmd+=("-h")
            elif [[ "${OBABEL_ADDPOLARH}" == "yes" ]]; then
                ob_cmd+=("--polarh")
            fi

            # Always keep -r (remove duplicate bonds)
            ob_cmd+=("-r")

            # 3D generation
            if [[ "${OBABEL_GEN3D}" == "yes" ]]; then
                ob_cmd+=("--gen3d")
            fi

            # Minimization
            if [[ "${OBABEL_MINIMIZE}" == "yes" ]]; then
                ob_cmd+=("--minimize" "--ff" "$ff" "--steps" "$steps_mmff")
            fi

            # Output
            ob_cmd+=("-O" "$out")

            # Run the command
            if "${ob_cmd[@]}" 2>"$errfile"; then
                if [[ -s "$out" ]]; then
                    echo "[INFO] OpenBabel success: $base	Complete ($count/$total)"
                    rm -f "$errfile"
                    continue
                fi
            fi

            echo "[WARN] OpenBabel failed → RDKit fallback: $base"
            rm -f "$errfile"
        fi

        # -----------------------------------
        # RDKit fallback (unchanged)
        # -----------------------------------
        if ! "${RUN_CMD[@]}" python3 - <<EOF
from rdkit import Chem
from rdkit.Chem import AllChem

mol = Chem.SDMolSupplier("$f", removeHs=False)[0]

if mol is None:
    raise SystemExit("RDKit failed to read molecule")

mol = Chem.AddHs(mol)

AllChem.EmbedMolecule(mol)
AllChem.MMFFOptimizeMolecule(mol)

writer = Chem.SDWriter("$out")
writer.write(mol)
writer.close()
EOF
        then
            echo "[ERROR] RDKit generation failed: $base"
            rm -f "$out"
            continue
        fi

        if [[ ! -s "$out" ]]; then
            echo "[ERROR] Empty output generated: $base"
            rm -f "$out"
            continue
        fi

        echo "[INFO] RDKit success: $base"
    done

    echo "[INFO] 3D ligand generation completed"
}

# ---------------------------
# Ligand PDBQT conversion
# ---------------------------
ligand_pdbqt_convert() {

    mkdir -p "$out_pdbqt"

    backup_dir_if_nonempty "$out_pdbqt"

    echo "[INFO] Ligand PDBQT conversion..."

    shopt -s nullglob

    local sdf_files=("$out_lig_3d"/*_3D.sdf)

    if [[ ${#sdf_files[@]} -eq 0 ]]; then
        echo "[ERROR] No 3D ligand SDF files found in:"
        echo "        $out_lig_3d"
        exit 1
    fi

    local f
    local base
    count=0
    total=${#sdf_files[@]}

    for f in "${sdf_files[@]}"; do
        count=$((count + 1))
        base=$(basename "$f" _3D.sdf)

        if "${RUN_CMD[@]}" mk_prepare_ligand.py \
            -i "$f" \
            --multimol_outdir "$out_pdbqt" \
            >/dev/null 2>&1; then

            echo "[INFO] Converted: $base	Complete ($count/$total)"
        else
            echo "[ERROR] PDBQT conversion failed: $base"
        fi
    done

    echo "[INFO] Ligand PDBQT conversion completed"
}