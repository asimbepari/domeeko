#!/usr/bin/env bash
# prep.sh - ligand/receptor preparation functions (sourced by domeeko)
set -uo pipefail

ORIGINAL_PATH="$PATH"

# ---------------------------
# Defaults (can be overridden by environment or wrapper)
# ---------------------------
USE_MGL="${USE_MGL:-false}"
MGL="${MGL:-}"
recpdb="${RECEPTOR_PDB:-}"
ligdir="${LIGAND_DIR:-}"
out_lig_3d="${OUT_LIG_3D:-sdf_3D}"
out_pdbqt="${OUT_PDBQT:-pdbqt_out}"
steps_mmff="${MMFF_STEPS:-5000}"
ff="${FORCE_FIELD:-MMFF94}"
report_dir="${REPORT_DIR:-prep_reports}"

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
# Receptor QC
# ---------------------------
receptor_qc() {
    mkdir -p "$report_dir"
    echo "[INFO] Receptor QC..."
    alt=$(awk '$0 ~ /^(ATOM|HETATM)/ && substr($0,17,1)!=" " {c++} END{print c+0}' "$recpdb")
    echo "[INFO] ALTLOC atoms: $alt"
    [[ "$alt" -gt 0 ]] && echo "[WARN] Alternate locations detected"
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
    "${RUN_CMD[@]}" mk_prepare_receptor.py \
        -i "$recpdb" \
        --write_pdbqt "$finalqt" \
        --default_altloc A \
        --allow_bad_res
    echo "[INFO] Receptor prepared (Meeko): $finalqt"
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
# Ligand 3D generation (SDF -> 3D SDF)
# ---------------------------
ligand_3d_gen() {
    mkdir -p "$out_lig_3d"
    echo "[INFO] Ligand 3D generation..."
    if ! "${RUN_CMD[@]}" obabel -V &>/dev/null; then
        echo "[WARN] OpenBabel unavailable → RDKit fallback"
        OB_FAIL=1
    else
        OB_FAIL=0
    fi
    shopt -s nullglob
    ligs=("$ligdir"/*.sdf)
    if [[ ${#ligs[@]} -eq 0 ]]; then
        echo "[ERROR] No .sdf ligands found in $ligdir"
        exit 1
    fi
    for f in "${ligs[@]}"; do
        base=$(basename "$f" .sdf)
        out="$out_lig_3d/${base}_3D.sdf"
        echo "[INFO] Processing $base"
        if [[ "$OB_FAIL" -eq 0 ]]; then
            if "${RUN_CMD[@]}" obabel "$f" -O "$out" --gen3d --minimize --ff "$ff" --steps "$steps_mmff" 2>/tmp/obabel_err.$$; then
                [[ -s "$out" ]] && { echo "[INFO] OBABEL OK: $base"; rm -f /tmp/obabel_err.$$; continue; }
            fi
            echo "[WARN] OBABEL failed → RDKit fallback: $base"
        fi
        "${RUN_CMD[@]}" python3 - <<EOF
from rdkit import Chem
from rdkit.Chem import AllChem
mol = Chem.SDMolSupplier("$f", removeHs=False)[0]
if mol is None: raise SystemExit("FAIL")
mol = Chem.AddHs(mol)
AllChem.EmbedMolecule(mol)
AllChem.MMFFOptimizeMolecule(mol)
w = Chem.SDWriter("$out")
w.write(mol)
w.close()
EOF
        if [[ ! -s "$out" ]]; then
            echo "[ERROR] failed: $base"
            rm -f "$out"
        fi
    done
}

# ---------------------------
# Ligand PDBQT conversion
# ---------------------------
ligand_pdbqt_convert() {
    mkdir -p "$out_pdbqt"
    echo "[INFO] Ligand PDBQT conversion..."
    shopt -s nullglob
    for f in "$out_lig_3d"/*_3D.sdf; do
        base=$(basename "$f" _3D.sdf)
        "${RUN_CMD[@]}" mk_prepare_ligand.py -i "$f" --multimol_outdir "$out_pdbqt" >/dev/null 2>&1
        echo "[INFO] Converted: $base"
    done
}

# Export all functions for wrapper
export -f ensure_docking_env receptor_qc split_alt_mgl receptor_prep_meeko receptor_prep_mgl ligand_3d_gen ligand_pdbqt_convert