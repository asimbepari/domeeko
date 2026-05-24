#!/usr/bin/env bash
# receptor_clean.sh - domeeko receptor QC + cleaning module (stable v0.3.2)

#set -euo pipefail

DOMEEKO_RECEPTOR_CLEAN_VERSION="0.3.2"

# ==========================================================
# LOGGING
# ==========================================================
qc_log_msg() {
    local level="$1"
    local msg="$2"

    echo "[$level] $msg"
    [[ -n "${QC_LOG:-}" ]] && echo "[$level] $msg" >> "$QC_LOG"
}

# ==========================================================
# VALIDATION
# ==========================================================
receptor_validate_input() {
    [[ -z "${recpdb:-}" ]] && return 1
    [[ ! -f "$recpdb" ]] && return 1
    [[ ! -s "$recpdb" ]] && return 1

    local n
    n=$(grep -cE '^(ATOM|HETATM)' "$recpdb" 2>/dev/null || echo 0)

    [[ "$n" -gt 0 ]] || return 1

    qc_log_msg INFO "Input validation passed"
}

# ==========================================================
# LIGAND DETECTION
# ==========================================================
receptor_detect_ligands() {
    local pdb="$1"

    awk '
    $1=="HETATM" {
        r=substr($0,18,3)
        gsub(/ /,"",r)
        if (r!="HOH" && r!="WAT" && r!="") seen[r]=1
    }
    END {
        for (i in seen) print i
    }
    ' "$pdb" | sort -u || true
}

# ==========================================================
# SAFE CENTER WRAPPER
# ==========================================================
_safe_center_call() {
    local pdb="$1"
    local out="$2"

    fx_center_of_mass --pdb_file "$pdb" --out "$out" >/dev/null 2>&1 || return 1
    [[ -s "$out" ]] || return 1
}

# ==========================================================
# RAW CENTER (FIXED LIGAND EXPANSION)
# ==========================================================
receptor_report_raw() {
    local pdb="$1"

    qc_log_msg INFO "Computing RAW receptor center + ligands"

    local out="${REPORT_DIR}/raw_centers.txt"

    mapfile -t ligands < <(receptor_detect_ligands "$pdb")

    if [[ ${#ligands[@]} -gt 0 ]]; then
        qc_log_msg INFO "Detected ligands: ${ligands[*]}"

        # FIX: expand correctly into repeated flags
        local args=()
        for l in "${ligands[@]}"; do
            args+=(--ligname "$l")
        done

        fx_center_of_mass \
            --pdb_file "$pdb" \
            --out "$out" \
            "${args[@]}" >/dev/null 2>&1 || {
                qc_log_msg ERROR "RAW center computation failed"
                return 1
            }

    else
        qc_log_msg INFO "No ligands detected"

        _safe_center_call "$pdb" "$out" || {
            qc_log_msg ERROR "RAW center computation failed"
            return 1
        }
    fi

    cat "$out"
}

# ==========================================================
# CLEANED CENTER (MOLECULE ONLY)
# ==========================================================
receptor_report_cleaned_center() {
    local pdb="$1"

    qc_log_msg INFO "Computing CLEANED receptor center"

    local out="${REPORT_DIR}/cleaned_centers.txt"

    _safe_center_call "$pdb" "$out" || {
        qc_log_msg ERROR "CLEANED center computation failed"
        return 1
    }

    cat "$out"
}

# ==========================================================
# CLEANING ENGINE
# ==========================================================
receptor_clean_pdb_old() {
    local input_pdb="$1"
    local output_pdb="$2"
    shift 2

    local keep_ligs=()
    local chain_filter=""

    # -----------------------------
    # Parse optional args
    # -----------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chain)
                chain_filter="$2"
                shift 2
                ;;
            *)
                keep_ligs+=("$1")
                shift
                ;;
        esac
    done

    qc_log_msg INFO "Cleaning receptor PDB"

    awk -v keep_list="${keep_ligs[*]}" -v chain_filter="$chain_filter" '
    function trim(x) {
        gsub(/^[ \t]+|[ \t]+$/, "", x)
        return x
    }

    function get_chain(line) {
        c = substr(line, 22, 1)
        return trim(c)
    }

    BEGIN {
        split(keep_list, keep, " ")
        for (i in keep) {
            if (keep[i] != "")
                keep_map[keep[i]] = 1
        }
    }

    # ----------------------------------------------------
    # Remove structural noise
    # ----------------------------------------------------
    # always remove LINK/Master/ANISOU
	/^ANISOU|^MASTER/ { next }

	# remove bonding only when chain filtering OR always (recommended)
	{
		if (chain_filter != "") {
			if ($0 ~ /^CONECT|^LINK/) next
		} else {
			if ($0 ~ /^CONECT/) next
		}
	}

    # ----------------------------------------------------
    # Optional chain filtering (applies to ATOM + HETATM)
    # ----------------------------------------------------
    function chain_ok(line) {
        if (chain_filter == "") return 1
        return get_chain(line) == chain_filter
    }

    # ----------------------------------------------------
    # HETATM handling (ligand keep logic preserved)
    # ----------------------------------------------------
    /^HETATM/ {

        if (!chain_ok($0)) next

        r = substr($0, 18, 3)
        gsub(/ /, "", r)

        if (r in keep_map) {
            print
        }

        next
    }

    # ----------------------------------------------------
    # ATOM handling (chain filtering only, no ligand logic)
    # ----------------------------------------------------
    /^ATOM/ {

        if (!chain_ok($0)) next
        print
        next
    }

    # ----------------------------------------------------
    # everything else unchanged
    # ----------------------------------------------------
    { print }

    END { print "END" }
    ' "$input_pdb" > "$output_pdb"

    [[ -s "$output_pdb" ]] || return 1
}

receptor_clean_pdb_old() {
    local input_pdb="$1"
    local output_pdb="$2"
    shift 2

    local keep_ligs=()
    local chain_filter=""

    # -----------------------------
    # Parse optional args
    # -----------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chain)
                chain_filter="$2"
                shift 2
                ;;
            *)
                keep_ligs+=("$1")
                shift
                ;;
        esac
    done

    qc_log_msg INFO "Cleaning receptor PDB"

    awk -v keep_list="${keep_ligs[*]}" -v chain_filter="$chain_filter" '
    function trim(x) {
        gsub(/^[ \t]+|[ \t]+$/, "", x)
        return x
    }

    function get_chain(line) {
        return trim(substr(line, 22, 1))
    }

    function chain_ok(line) {
        if (chain_filter == "") return 1
        return get_chain(line) == chain_filter
    }

    BEGIN {
        split(keep_list, keep, " ")
        for (i in keep) {
            if (keep[i] != "")
                keep_map[keep[i]] = 1
        }
    }

    # ----------------------------------------------------
    # ALWAYS remove structural noise first
    # ----------------------------------------------------
    /^ANISOU|^MASTER/ { next }

    # CONECT/LINK always removed AFTER chain decision stage
    /^CONECT|^LINK/ { next }

    # ----------------------------------------------------
    # ATOM: chain filtering only
    # ----------------------------------------------------
    /^ATOM/ {
        if (!chain_ok($0)) next
        print
        next
    }

    # ----------------------------------------------------
    # HETATM: chain filter FIRST, then ligand logic
    # ----------------------------------------------------
    /^HETATM/ {
        if (!chain_ok($0)) next

        r = substr($0, 18, 3)
        gsub(/ /, "", r)

        if (r in keep_map) {
            print
        }

        next
    }

    # ----------------------------------------------------
    # everything else unchanged
    # ----------------------------------------------------
    { print }

    END { print "END" }
    ' "$input_pdb" > "$output_pdb"

    [[ -s "$output_pdb" ]] || return 1
}


receptor_clean_pdb() {

    local input_pdb="$1"
    local output_pdb="$2"
    shift 2

    local keep_ions=false
    local keep_waters=false

    local keep_ligs=()
    local chain_filter=""

    # --------------------------------------------------
    # Parse optional args
    # --------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in

            --chain)
                chain_filter="$2"
                shift 2
                ;;

            --keep_ions)
                keep_ions=true
                shift
                ;;

            --keep_waters)
                keep_waters=true
                shift
                ;;

            *)
                keep_ligs+=("$1")
                shift
                ;;

        esac
    done

    qc_log_msg INFO "Cleaning receptor PDB"

    [[ -n "$chain_filter" ]] && \
        qc_log_msg INFO "Keeping chain: $chain_filter"

    [[ "$keep_ions" == true ]] && \
        qc_log_msg INFO "Keeping structural ions"

    [[ "$keep_waters" == true ]] && \
        qc_log_msg INFO "Keeping crystallographic waters"

    awk \
    -v keep_list="${keep_ligs[*]}" \
    -v chain_filter="$chain_filter" \
    -v keep_ions="$keep_ions" \
    -v keep_waters="$keep_waters" '

    # ==================================================
    # Utilities
    # ==================================================

    function trim(x) {
        gsub(/^[ \t]+|[ \t]+$/, "", x)
        return x
    }

    function get_chain(line) {
        return trim(substr(line,22,1))
    }

    function get_resname(line) {
        r = substr(line,18,3)
        gsub(/ /,"",r)
        return r
    }

    function chain_ok(line) {

        if (chain_filter == "")
            return 1

        return (get_chain(line) == chain_filter)
    }

    # ==================================================
    # Initialization
    # ==================================================

    BEGIN {

        split(keep_list, keep, " ")

        for (i in keep) {
            if (keep[i] != "")
                keep_map[keep[i]] = 1
        }

        # common structural ions/metals
        ion["MG"]=1
        ion["ZN"]=1
        ion["MN"]=1
        ion["CA"]=1
        ion["NA"]=1
        ion["K"]=1
        ion["FE"]=1
        ion["CU"]=1
        ion["CO"]=1
        ion["NI"]=1
        ion["CD"]=1

        # waters
        water["HOH"]=1
        water["WAT"]=1
        water["H2O"]=1
    }

    # ==================================================
    # Remove problematic metadata
    # ==================================================

    /^ANISOU/ { next }
    /^MASTER/ { next }

    # Meeko commonly dislikes CONECT
    /^CONECT/ { next }

    # ==================================================
    # Protein atoms
    # ==================================================

    /^ATOM/ {

        if (!chain_ok($0))
            next

        print
        next
    }

    # ==================================================
    # HETATM handling
    # ==================================================

    /^HETATM/ {

        if (!chain_ok($0))
            next

        res = get_resname($0)

        # ----------------------------------------------
        # Explicit ligand retention
        # ----------------------------------------------
        if (res in keep_map) {
            print
            next
        }

        # ----------------------------------------------
        # Optional ion retention
        # ----------------------------------------------
        if (keep_ions == "true" && res in ion) {
            print
            next
        }

        # ----------------------------------------------
        # Optional water retention
        # ----------------------------------------------
        if (keep_waters == "true" && res in water) {
            print
            next
        }

        # default:
        # remove all remaining HETATM
        next
    }

    # ==================================================
    # Preserve TER
    # ==================================================

    /^TER/ {
        print
        next
    }

    # ==================================================
    # Keep useful headers only
    # ==================================================

    /^HEADER|^TITLE|^COMPND|^SOURCE|^REMARK/ {
        print
        next
    }

    # ==================================================
    # END records
    # ==================================================

    /^END/ {
        seen_end=1
        print
        next
    }

    END {

        if (!seen_end)
            print "END"
    }

    ' "$input_pdb" > "$output_pdb"

    # --------------------------------------------------
    # Validation
    # --------------------------------------------------

    [[ -s "$output_pdb" ]] || {
        qc_log_msg ERROR "Cleaning failed: empty output"
        return 1
    }

#    qc_log_msg INFO "Cleaned receptor written: $output_pdb"
}


# ==========================================================
# STATS
# ==========================================================
receptor_statistics() {
    local pdb="$1"

    qc_log_msg INFO "ATOM    : $(grep -c '^ATOM' "$pdb" 2>/dev/null || echo 0)"
    qc_log_msg INFO "HETATM  : $(grep -c '^HETATM' "$pdb" 2>/dev/null || echo 0)"
    qc_log_msg INFO "TER     : $(grep -c '^TER' "$pdb" 2>/dev/null || echo 0)"
    qc_log_msg INFO "CONECT  : $(grep -c '^CONECT' "$pdb" 2>/dev/null || echo 0)"
    qc_log_msg INFO "LINK    : $(grep -c '^LINK' "$pdb" 2>/dev/null || echo 0)"
}

# ==========================================================
# MAIN PIPELINE
# ==========================================================
receptor_qc() {

    REPORT_DIR="${report_dir:-prep_reports}"
    mkdir -p "$REPORT_DIR"
    QC_LOG="${REPORT_DIR}/receptor_qc.log"

    qc_log_msg INFO "========== DOMEEKO RECEPTOR QC =========="
    qc_log_msg INFO "Version: $DOMEEKO_RECEPTOR_CLEAN_VERSION"
    qc_log_msg INFO "Input PDB: $recpdb"

    receptor_validate_input || return 1
    receptor_statistics "$recpdb"
    receptor_report_raw "$recpdb"

    local base cleaned_pdb
    base="${recpdb%.*}"
    base="${base%_cleaned}"
    cleaned_pdb="${base}_cleaned.pdb"

    receptor_clean_pdb "$recpdb" "$cleaned_pdb" \
    ${KEEP_CHAINS[@]:+"--chain"} "${KEEP_CHAINS[@]:-}" \
    "${KEEP_LIGANDS[@]:-}" || return 1

    qc_log_msg INFO "Cleaned receptor written: $cleaned_pdb"

    recpdb="$cleaned_pdb"

    receptor_validate_input || return 1
    receptor_report_cleaned_center "$recpdb"

    qc_log_msg INFO "Final receptor: $recpdb"
    qc_log_msg INFO "QC completed successfully"
}