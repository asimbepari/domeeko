#!/usr/bin/env bash
# make_complex.sh
# Complex generation utilities for domeeko

# NOTE: keep sourcing-safe (no set -euo pipefail here unless desired globally)

TOP_N="${TOP_N:-10}"
TOPLIST="${TOPLIST:-ranked_results.csv}"
OUT_COMPLEX="${OUT_COMPLEX:-complexes}"
DOCKED_PDBQT="${DOCKED_PDBQT:-Top_Docked}"
# =========================================================
# MODEL 1 extraction (robust for Vina PDBQT)
# =========================================================
extract_first_model() {

    local input_pdbqt="$1"
    local output_pdbqt="$2"

    [[ ! -f "$input_pdbqt" ]] && {
        echo "[ERROR] Missing input PDBQT: $input_pdbqt"
        return 1
    }

    awk '
    BEGIN {keep=1}

    # stop at second model if present
    /^MODEL[[:space:]]+2/ {exit}

    keep {print}

    ' "$input_pdbqt" > "$output_pdbqt"

    if [[ ! -s "$output_pdbqt" ]]; then
        echo "[WARNING] Empty pose extracted from: $input_pdbqt"
        return 1
    fi
}

# =========================================================
# Resolve top ligand list (CSV or TXT)
# =========================================================
resolve_top_list() {

    local outfile="$1"
    > "$outfile"

    # -----------------------------
    # CSV mode (ranked_results.csv)
    # -----------------------------
    if [[ "$TOPLIST" == *.csv ]]; then

        tail -n +2 "$TOPLIST" \
        | head -n "$TOP_N" \
        | cut -d',' -f1 \
        | while read -r lig; do

            [[ -z "$lig" ]] && continue
            lig=$(basename "$lig")
            lig="${lig%.pdbqt}"
            echo "$lig"

        done >> "$outfile"

    # -----------------------------
    # TXT mode
    # -----------------------------
    else

        head -n "$TOP_N" "$TOPLIST" \
        | while read -r lig; do

            [[ -z "$lig" ]] && continue

            lig=$(echo "$lig" | tr -d '\r')
            lig=$(basename "$lig")
            lig="${lig%.pdbqt}"

            echo "$lig"

        done >> "$outfile"

    fi
}

# =========================================================
# Backup helper (safe)
# =========================================================
backup_dir_if_nonempty() {

    local target="$1"

    [[ ! -d "$target" ]] && return 0

    if [[ -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then

        local ts backup

        ts=$(date +"%Y%m%d_%H%M%S")
        backup="${target}_backup_${ts}"

        echo "[INFO] Backing up: $target → $backup"

        cp -r "$target" "$backup"

        rm -rf "${target:?}/"*
    fi
}

# =========================================================
# Copy top docked ligands (DEBUG VERSION)
# =========================================================

copy_top_docked() {

    log_debug "ENTER copy_top_docked"

    mkdir -p Top_Docked

    log_debug "DOCKED_PDBQT = $DOCKED_PDBQT"
    log_debug "TOPLIST     = $TOPLIST"
    log_debug "TOP_N       = $TOP_N"

    if [[ -d Top_Docked ]]; then
        log_debug "Checking existing Top_Docked contents..."
        ls -1 Top_Docked 2>/dev/null | head -n 5 || true
        backup_dir_if_nonempty "Top_Docked"
    fi

    local tmplist
    tmplist=$(mktemp)

    log_debug "Resolving top list..."

    resolve_top_list "$tmplist"

    log_debug "Resolved ligands:"
    cat "$tmplist" || true

    local total
    total=$(wc -l < "$tmplist" 2>/dev/null || echo 0)

    log_debug "Ligands in list: $total"

    local lig src match found=0

    while read -r lig; do

        [[ -z "$lig" ]] && continue

        lig=$(basename "$lig")
        lig="${lig%.pdbqt}"

        log_debug "Processing ligand: $lig"

        src="${DOCKED_PDBQT}/${lig}.pdbqt"

        log_debug "Looking for: $src"

        if [[ -f "$src" ]]; then
            log_debug "FOUND direct match"
            cp "$src" Top_Docked/
            ((found++))
            continue
        fi

        log_debug "Trying fuzzy match..."

        match=$(find "$DOCKED_PDBQT" \
            -maxdepth 1 \
            -type f \
            -name "${lig}*.pdbqt" \
            | head -n 1)

        if [[ -n "$match" ]]; then
            log_debug "FOUND fuzzy match: $match"
            cp "$match" Top_Docked/
            ((found++))
        else
            log_warn "Missing docked ligand: $lig"
        fi

    done < "$tmplist"

    rm -f "$tmplist"

    log_debug "EXIT copy_top_docked"
    log_info "Top docked ligands copied: $found"
}

# =========================================================
# Build receptor-ligand complexes
# =========================================================

make_complexes() {

    log_debug "ENTER make_complexes"

    mkdir -p "${OUT_COMPLEX}/Complex_PDBQT"
    mkdir -p "${OUT_COMPLEX}/Complex_PDB"

    local tmpdir
    tmpdir=$(mktemp -d)

    log_debug "RECEPTOR = $RECEPTOR"

    if [[ -z "$RECEPTOR" || ! -f "$RECEPTOR" ]]; then
        log_error "Receptor missing: $RECEPTOR"
        rm -rf "$tmpdir"
        return 1
    fi

    shopt -s nullglob

    local ligands=(Top_Docked/*.pdbqt)

    #log_info "Ligands found: ${#ligands[@]}"

    if [[ ${#ligands[@]} -eq 0 ]]; then
        log_warn "No ligands in Top_Docked"
        rm -rf "$tmpdir"
        return 0
    fi

    local count=0

    for lig in "${ligands[@]}"; do

        log_debug "Processing ligand: $lig"

        local base tmp_pose
        base=$(basename "$lig" .pdbqt)

        tmp_pose="${tmpdir}/${base}_pose1.pdbqt"

        log_debug "Building complex: $base"

        if ! extract_first_model "$lig" "$tmp_pose"; then
            log_warn "Pose extraction failed: $base"
            continue
        fi

        log_debug "Pose extracted"

        local complex_pdbqt="${OUT_COMPLEX}/Complex_PDBQT/${base}_complex.pdbqt"
        local complex_pdb="${OUT_COMPLEX}/Complex_PDB/${base}_complex.pdb"

        cat "$RECEPTOR" "$tmp_pose" > "$complex_pdbqt"

        if obabel "$complex_pdbqt" -O "$complex_pdb" >/dev/null 2>&1; then
            log_debug "obabel OK: $base"
        else
            log_warn "obabel failed: $base"
        fi

        ((count++))

    done

    rm -rf "$tmpdir"

    log_info "Complexes generated: $count	[${OUT_COMPLEX}/Complex_PDB]"
    log_debug "EXIT make_complexes"
}