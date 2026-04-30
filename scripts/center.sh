#!/usr/bin/env bash
# center.sh - Compute geometric centers and list ligands in PDB
# Usage:
#   List ligands only:   fx_center_of_mass --pdb_file FILE --list-ligands [--out FILE]
#   Molecule only:       fx_center_of_mass --pdb_file FILE [--out FILE]  (writes center.txt + ligands.txt)
#   With selections:     fx_center_of_mass --pdb_file FILE [--ligname NAME]... [--res_num NUM]... [--chain A]... [--out FILE] [--write-ligands]

set -euo pipefail

# ----------------------------------------------------------------------
# Helper: geometric center (unweighted) of atoms matching an awk pattern
# ----------------------------------------------------------------------
_geometric_center_by_awk() {
    local pdb="$1"
    local awk_cond="$2"
    awk '
        BEGIN {x=0; y=0; z=0; n=0}
        ($1=="ATOM" || $1=="HETATM") && ('"$awk_cond"') {
            x+=$7; y+=$8; z+=$9; n++
        }
        END {
            if (n>0) printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
        }
    ' "$pdb"
}

# ----------------------------------------------------------------------
# Whole molecule center (all ATOM + HETATM)
# ----------------------------------------------------------------------
_whole_molecule_center() {
    local pdb="$1"
    _geometric_center_by_awk "$pdb" "1"
}

# ----------------------------------------------------------------------
# Ligand center (by residue name)
# ----------------------------------------------------------------------
_ligand_center() {
    local pdb="$1"
    local lig_name="$2"
    _geometric_center_by_awk "$pdb" "substr(\$0,18,3) == \"$lig_name\""
}

# ----------------------------------------------------------------------
# Residue center (by number)
# ----------------------------------------------------------------------
_residue_center() {
    local pdb="$1"
    local resid="$2"
    _geometric_center_by_awk "$pdb" "substr(\$0,23,4)+0 == $resid"
}

# ----------------------------------------------------------------------
# Chain center
# ----------------------------------------------------------------------
_chain_center() {
    local pdb="$1"
    local chain="$2"
    _geometric_center_by_awk "$pdb" "substr(\$0,22,1) == \"$chain\""
}

# ----------------------------------------------------------------------
# List all unique ligand (HETATM) residue names (excluding water HOH)
# Output: one ligand name per line
# ----------------------------------------------------------------------
_list_ligands() {
    local pdb="$1"
    awk '
        $1 == "HETATM" {
            lig = substr($0,18,3)
            if (lig != "" && lig != "HOH") seen[lig]=1
        }
        END {
            for (l in seen) print l
        }
    ' "$pdb" | sort
}

# ----------------------------------------------------------------------
# Write ligands.txt (or custom file) and print a message to stdout
# ----------------------------------------------------------------------
_write_ligands_file() {
    local pdb="$1"
    local out_file="$2"
    local ligands
    ligands=$(_list_ligands "$pdb")
    if [[ -z "$ligands" ]]; then
        echo "No HETATM ligands (excluding water) found in $pdb" >&2
        return 1
    fi
    echo "$ligands" > "$out_file"
	cat "$out_file"
    echo "Ligand list saved to $out_file"
}

# ----------------------------------------------------------------------
# Write center output (labelled blocks) to a file and stdout
# ----------------------------------------------------------------------
_write_centers() {
    local pdb="$1"
    local out_file="$2"
    local -a ligs=("${!3}")
    local -a residues=("${!4}")
    local -a chains=("${!5}")

    local tmp_out=$(mktemp)

    # Molecule center
    local mol_center
    mol_center=$(_whole_molecule_center "$pdb")
    if [[ -z "$mol_center" ]]; then
        echo "ERROR: No atoms found in PDB file" >&2
        rm -f "$tmp_out"
        return 1
    fi
    echo "[Molecule]" >> "$tmp_out"
    echo "center_x = $(echo "$mol_center" | cut -d' ' -f1)" >> "$tmp_out"
    echo "center_y = $(echo "$mol_center" | cut -d' ' -f2)" >> "$tmp_out"
    echo "center_z = $(echo "$mol_center" | cut -d' ' -f3)" >> "$tmp_out"
    echo "" >> "$tmp_out"

    # Ligands
    for lig in "${ligs[@]}"; do
        local center
        center=$(_ligand_center "$pdb" "$lig")
        if [[ -z "$center" ]]; then
            echo "WARNING: Ligand '$lig' not found in PDB" >&2
            continue
        fi
        echo "[LIG_${lig}]" >> "$tmp_out"
        echo "center_x = $(echo "$center" | cut -d' ' -f1)" >> "$tmp_out"
        echo "center_y = $(echo "$center" | cut -d' ' -f2)" >> "$tmp_out"
        echo "center_z = $(echo "$center" | cut -d' ' -f3)" >> "$tmp_out"
        echo "" >> "$tmp_out"
    done

    # Residues
    for resid in "${residues[@]}"; do
        local center
        center=$(_residue_center "$pdb" "$resid")
        if [[ -z "$center" ]]; then
            echo "WARNING: Residue number $resid not found in PDB" >&2
            continue
        fi
        echo "[RES_${resid}]" >> "$tmp_out"
        echo "center_x = $(echo "$center" | cut -d' ' -f1)" >> "$tmp_out"
        echo "center_y = $(echo "$center" | cut -d' ' -f2)" >> "$tmp_out"
        echo "center_z = $(echo "$center" | cut -d' ' -f3)" >> "$tmp_out"
        echo "" >> "$tmp_out"
    done

    # Chains
    for ch in "${chains[@]}"; do
        local center
        center=$(_chain_center "$pdb" "$ch")
        if [[ -z "$center" ]]; then
            echo "WARNING: Chain '$ch' not found in PDB" >&2
            continue
        fi
        echo "[CHAIN_${ch}]" >> "$tmp_out"
        echo "center_x = $(echo "$center" | cut -d' ' -f1)" >> "$tmp_out"
        echo "center_y = $(echo "$center" | cut -d' ' -f2)" >> "$tmp_out"
        echo "center_z = $(echo "$center" | cut -d' ' -f3)" >> "$tmp_out"
        echo "" >> "$tmp_out"
    done

    cat "$tmp_out"
    cp "$tmp_out" "$out_file"
    echo "Center(s) saved to $out_file"
    rm -f "$tmp_out"
}

# ----------------------------------------------------------------------
# Main function
# ----------------------------------------------------------------------
fx_center_of_mass() {
    local pdb_file=""
    local out_file="center.txt"
    local -a lignames=()
    local -a res_nums=()
    local -a chains=()
    local list_ligands=false
    local write_ligands=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pdb_file) pdb_file="$2"; shift 2 ;;
            --ligname) lignames+=("$2"); shift 2 ;;
            --res_num) res_nums+=("$2"); shift 2 ;;
            --chain) chains+=("$2"); shift 2 ;;
            --out) out_file="$2"; shift 2 ;;
            --list-ligands) list_ligands=true; shift ;;
            --write-ligands) write_ligands=true; shift ;;
            *) echo "ERROR: Unknown option $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$pdb_file" ]] || [[ ! -f "$pdb_file" ]]; then
        echo "ERROR: --pdb_file is required and must exist" >&2
        return 1
    fi

    # MODE 1: --list-ligands only
    if $list_ligands; then
        local lig_out="${out_file}"
        if [[ "$out_file" == "center.txt" ]]; then
            lig_out="ligands.txt"
        fi
        _write_ligands_file "$pdb_file" "$lig_out"
        return 0
    fi

    # Determine if we are in "only pdb_file" mode (no selections)
    local no_selections=true
    if [[ ${#lignames[@]} -gt 0 || ${#res_nums[@]} -gt 0 || ${#chains[@]} -gt 0 ]]; then
        no_selections=false
    fi

    # Write centers
    _write_centers "$pdb_file" "$out_file" lignames[@] res_nums[@] chains[@]

    # Write ligands.txt if:
    # - only --pdb_file was given (no selections), OR
    # - --write-ligands flag is present
    if $no_selections || $write_ligands; then
        _write_ligands_file "$pdb_file" "ligands.txt"
    fi
}

# ----------------------------------------------------------------------
# If run directly
# ----------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fx_center_of_mass "$@"
fi