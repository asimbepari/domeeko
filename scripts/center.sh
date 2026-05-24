#!/usr/bin/env bash
# center.sh - production-safe geometric center engine (per‑chain by default)

#set -euo pipefail

# ==========================================================
# SAFE GEOMETRIC CENTER (strict PDB fixed columns)
# ==========================================================
_geometric_center() {
    local pdb="$1"
    local mode="$2"

    awk -v mode="$mode" '
    BEGIN {
        x=0; y=0; z=0; n=0
    }

    {
        rec = substr($0,1,6)

        if (mode == "MOLECULE") {
            if (rec == "ATOM  " || rec == "HETATM") {
                x += substr($0,31,8) + 0
                y += substr($0,39,8) + 0
                z += substr($0,47,8) + 0
                n++
            }
        }

        else if (mode == "LIGAND") {
            if (rec == "HETATM") {
                res = substr($0,18,3)
                gsub(/ /,"",res)
                if (res == lig) {
                    x += substr($0,31,8) + 0
                    y += substr($0,39,8) + 0
                    z += substr($0,47,8) + 0
                    n++
                }
            }
        }
    }

    END {
        if (n > 0)
            printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
    }
    ' "$pdb"
}

# ==========================================================
# MOLECULE CENTER
# ==========================================================
_molecule_center() {
    local pdb="$1"

    awk '
    BEGIN {x=0;y=0;z=0;n=0}

    {
        if (substr($0,1,6)=="ATOM  " || substr($0,1,6)=="HETATM") {
            x += substr($0,31,8) + 0
            y += substr($0,39,8) + 0
            z += substr($0,47,8) + 0
            n++
        }
    }

    END {
        if (n==0) exit 1
        printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
    }
    ' "$pdb"
}

# ==========================================================
# LIGAND CENTER (optionally per chain)
# ==========================================================
_ligand_center() {
    local pdb="$1"
    local lig="$2"
    local chain="$3"   # optional, can be empty

    awk -v lig="$lig" -v chain="$chain" '
    BEGIN {x=0;y=0;z=0;n=0}

    {
        if (substr($0,1,6)=="HETATM") {
            res = substr($0,18,3)
            gsub(/ /,"",res)
            c = substr($0,22,1)

            if (res == lig && (chain == "" || c == chain)) {
                x += substr($0,31,8) + 0
                y += substr($0,39,8) + 0
                z += substr($0,47,8) + 0
                n++
            }
        }
    }

    END {
        if (n==0) exit 1
        printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
    }
    ' "$pdb"
}

# ==========================================================
# RESIDUE CENTER
# ==========================================================
_residue_center() {
    local pdb="$1"
    local r="$2"

    awk -v r="$r" '
    BEGIN {x=0;y=0;z=0;n=0}

    {
        if (substr($0,1,6)=="ATOM  " || substr($0,1,6)=="HETATM") {
            num = substr($0,23,4)+0
            if (num == r) {
                x += substr($0,31,8)+0
                y += substr($0,39,8)+0
                z += substr($0,47,8)+0
                n++
            }
        }
    }

    END {
        if (n==0) exit 1
        printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
    }
    ' "$pdb"
}

# ==========================================================
# CHAIN CENTER
# ==========================================================
_chain_center() {
    local pdb="$1"
    local c="$2"

    awk -v c="$c" '
    BEGIN {x=0;y=0;z=0;n=0}

    {
        if (substr($0,1,6)=="ATOM  " || substr($0,1,6)=="HETATM") {
            if (substr($0,22,1)==c) {
                x += substr($0,31,8)+0
                y += substr($0,39,8)+0
                z += substr($0,47,8)+0
                n++
            }
        }
    }

    END {
        if (n==0) exit 1
        printf "%.4f %.4f %.4f\n", x/n, y/n, z/n
    }
    ' "$pdb"
}

# ==========================================================
# LIGAND LIST (global or per chain)
# ==========================================================
_list_ligands() {
    local pdb="$1"
    local chain="$2"   # optional

    awk -v chain="$chain" '
    substr($0,1,6)=="HETATM" {
        r=substr($0,18,3); gsub(/ /,"",r)
        c=substr($0,22,1)
        if (r!="HOH" && r!="WAT" && (chain == "" || c == chain)) {
            seen[r]=1
        }
    }
    END {for (i in seen) print i}
    ' "$pdb" | sort
}

# ==========================================================
# DETECT ALL CHAINS IN THE PDB
# ==========================================================
_detect_chains() {
    local pdb="$1"
    awk '
    /^(ATOM  |HETATM)/ {
        chain = substr($0,22,1)
        if (chain != " " && chain != "") chains[chain]=1
    }
    END { for(c in chains) printf "%s ", c }
    ' "$pdb" | sort -u
}

# ==========================================================
# WRITE CENTERS (per-chain by default)
# ==========================================================
_write_centers() {
    local pdb="$1"
    local out="$2"
    local ligs="$3"
    local res="$4"
    local user_chains="$5"   # optional filter

    # Detect all chains present in the PDB
    local all_chains
    all_chains=$(_detect_chains "$pdb")
    all_chains="${all_chains%" "}"   # remove trailing space

    # Decide which chains to process
    local -a process_chains=()
    if [[ -n "$user_chains" ]]; then
        # Use only the chains specified by --chain
        process_chains=( $user_chains )
    else
        # Use all detected chains (if any)
        process_chains=( $all_chains )
    fi

    local tmp
    tmp=$(mktemp)

    # Overall molecule center (always)
    local mol
    mol=$(_molecule_center "$pdb") || {
        echo "ERROR: molecule center failed" >&2
        return 1
    }
    {
        echo "[MOLECULE]"
        echo "$mol"
        echo ""
    } >> "$tmp"

    # ----- If chains exist (either detected or user‑filtered) -----
    if [[ ${#process_chains[@]} -gt 0 ]]; then
        # Print info about all detected chains (to stderr)
        if [[ -n "$all_chains" ]]; then
            echo "[INFO] Detected chains: $all_chains" >&2
        fi

        # 1. Print centers for each chain we are processing
        for ch in "${process_chains[@]}"; do
            local c
            c=$(_chain_center "$pdb" "$ch" || true)
            if [[ -n "$c" ]]; then
                {
                    echo "[chain${ch}]"
                    echo "$c"
                    echo ""
                } >> "$tmp"
            fi
        done

        # 2. Print per‑chain ligand centers
        for ch in "${process_chains[@]}"; do
            local lig_list
            lig_list=$(_list_ligands "$pdb" "$ch")
            if [[ -n "$lig_list" ]]; then
                echo "[INFO] Detected ligands for chain ${ch}: $lig_list" >&2
            fi
            for lig in $lig_list; do
                local c
                c=$(_ligand_center "$pdb" "$lig" "$ch" || true)
                if [[ -n "$c" ]]; then
                    {
                        echo "[${ch}: LIG_${lig}]"
                        echo "$c"
                        echo ""
                    } >> "$tmp"
                fi
            done
        done
    else
        # ----- No chains at all → fallback to legacy output -----
        # AUTO-DETECT global ligands if not provided
        if [[ -z "$ligs" ]]; then
            ligs=$(_list_ligands "$pdb" "" | tr '\n' ' ')
        fi

        # Global ligands
        for lig in $ligs; do
            [[ -z "$lig" ]] && continue
            local c
            c=$(_ligand_center "$pdb" "$lig" "" || true)
            if [[ -n "$c" ]]; then
                {
                    echo "[LIG_$lig]"
                    echo "$c"
                    echo ""
                } >> "$tmp"
            fi
        done

        # Residues (unchanged)
        for r in $res; do
            [[ -z "$r" ]] && continue
            c=$(_residue_center "$pdb" "$r" || true)
            [[ -n "$c" ]] && {
                echo "[RES_$r]"
                echo "$c"
                echo ""
            } >> "$tmp"
        done

        # Legacy chain centers (should not happen because we have no chains, but keep)
        for ch in $user_chains; do
            [[ -z "$ch" ]] && continue
            c=$(_chain_center "$pdb" "$ch" || true)
            [[ -n "$c" ]] && {
                echo "[CHAIN_$ch]"
                echo "$c"
                echo ""
            } >> "$tmp"
        done
    fi

    cat "$tmp"
    #cp "$tmp" "$out"
	
	# Extract basename from pdb file (remove directory and extension)
	local pdb_basename
	pdb_basename=$(basename "$pdb" | sed 's/\.[^.]*$//')   # e.g., "base" from "base.pdb"

	# Compute new output filename: <original_dir>/<original_name>_<basename>.<ext>
	local out_dir=$(dirname "$out")
	local out_name=$(basename "$out")
	local out_base="${out_name%.*}"
	local out_ext="${out_name##*.}"

	local new_out
	if [[ "$out_name" == "$out_ext" ]]; then
		# No extension → just append basename
		new_out="${out_dir}/${out_base}_${pdb_basename}"
	else
		# Insert basename before extension
		new_out="${out_dir}/${out_base}_${pdb_basename}.${out_ext}"
	fi

	# Use the new output path
	cp "$tmp" "$new_out"

	# Optionally print the actual output file path (for debugging)
	echo "[INFO] Wrote centers to: $new_out" >&2

    rm -f "$tmp"
}

# ==========================================================
# MAIN (unchanged interface)
# ==========================================================
fx_center_of_mass() {
    local pdb=""
    local out="center.txt"
    local -a ligs=()
    local -a res=()
    local -a chains=()
    local list=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pdb_file) pdb="$2"; shift 2 ;;
            --ligname) ligs+=("$2"); shift 2 ;;
            --res_num) res+=("$2"); shift 2 ;;
            --chain) chains+=("$2"); shift 2 ;;
            --out) out="$2"; shift 2 ;;
            --list-ligands) list=true; shift ;;
            *) echo "ERROR: unknown $1" >&2; return 1 ;;
        esac
    done

    [[ -z "$pdb" || ! -f "$pdb" ]] && return 1

    if $list; then
        _list_ligands "$pdb" ""
        return 0
    fi

    _write_centers "$pdb" "$out" "${ligs[*]:-}" "${res[*]:-}" "${chains[*]:-}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fx_center_of_mass "$@"
fi