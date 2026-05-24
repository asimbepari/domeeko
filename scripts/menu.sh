#!/usr/bin/env bash
# ============================================================
# menu.sh - domeeko interactive menu (with file/dir preview)
# ============================================================
# - Shows matching files/directories before input (no numbers)
# - Enter full or relative path; 0 to cancel
# ============================================================

set -uo pipefail

# ----------------------------------------------
# UI Helpers
# ----------------------------------------------
section() {
    echo
    echo "──────────────────────────────────────────────────────────────"
    echo "$1"
    echo "──────────────────────────────────────────────────────────────"
}

pause() {
    echo
    read -rp "Press ENTER to continue..."
}

# ----------------------------------------------
# FILE SELECTOR – shows matching files, then asks for path
# ----------------------------------------------
choose_file() {
    local pattern="${1:-*}"
    local base="${2:-.}"
    local depth="${3:-2}"

    {
        echo "──────────────────────────────────────────────"
        echo "FILE SELECTOR"
        echo "Base: $base"
        echo "Pattern: $pattern"
        echo "Depth: $depth"
        echo "──────────────────────────────────────────────"

        mapfile -t files < <(
            find "$base" -maxdepth "$depth" -type f -name "$pattern" | sort
        )

        if (( ${#files[@]} == 0 )); then
            echo "[ERROR] No matching files found"
            return 1
        fi

        local i=1
        for f in "${files[@]}"; do
            echo "  [$i] $f"
            ((i++))
        done

        echo "  [0] Cancel"
        echo "──────────────────────────────────────────────"
    } >&2

    read -rp "Select file [1-${#files[@]}]: " sel

    [[ "$sel" == "0" ]] && return 1
    [[ "$sel" =~ ^[0-9]+$ ]] || return 1
    (( sel >= 1 && sel <= ${#files[@]} )) || return 1

    printf "%s" "${files[$((sel-1))]}"
}

choose_directory_by_filetype() {
    local base="${1:-.}"
    local pattern="${2:-*.pdbqt}"
    local depth="${3:-5}"

    {
        echo "──────────────────────────────────────────────"
        echo "DIRECTORY SELECTOR (filtered)"
        echo "Base: $base"
        echo "File filter: $pattern"
        echo "Search depth: $depth"
        echo "──────────────────────────────────────────────"

        mapfile -t dirs < <(
            find "$base" -maxdepth "$depth" -type f -name "$pattern" \
                -printf "%h\n" | sort -u
        )

        if (( ${#dirs[@]} == 0 )); then
            echo "[ERROR] No directories contain matching files"
            return 1
        fi

        local i=1
        for d in "${dirs[@]}"; do
            echo "  [$i] $d/"
            ((i++))
        done

        echo "  [0] Cancel"
        echo "──────────────────────────────────────────────"
    } >&2

    read -rp "Select directory [1-${#dirs[@]}]: " sel

    [[ "$sel" == "0" ]] && return 1
    [[ "$sel" =~ ^[0-9]+$ ]] || return 1
    (( sel >= 1 && sel <= ${#dirs[@]} )) || return 1

    printf "%s" "${dirs[$((sel-1))]}"
}


choose_docked_directory() {
    local base="${1:-.}"
    local depth="${2:-5}"
    local pattern="${3:-*.pdbqt}"

    local -a dirs=()

    {
        echo "──────────────────────────────────────────────"
        echo "DOCKED DIRECTORY SELECTOR"
        echo "Base: $base"
        echo "Pattern: $pattern"
        echo "Depth: $depth"
        echo "──────────────────────────────────────────────"

        # IMPORTANT FIX:
        # find directories that CONTAIN matching files
        mapfile -t dirs < <(
            find "$base" -maxdepth "$depth" -type f -name "$pattern" -printf "%h\n" \
            | sort -u
        )

        if [[ ${#dirs[@]} -eq 0 ]]; then
            echo "[ERROR] No docking result directories found" >&2
            return 1
        fi

        local i=1
        for d in "${dirs[@]}"; do
            echo "  [$i] $d/"
            ((i++))
        done

        echo "  [0] Cancel"
        echo "──────────────────────────────────────────────"
    } >&2

    read -rp "Select directory [1-${#dirs[@]}]: " sel

    [[ "$sel" == "0" ]] && return 1
    [[ "$sel" =~ ^[0-9]+$ ]] || return 1
    (( sel >= 1 && sel <= ${#dirs[@]} )) || return 1

    printf "%s" "${dirs[$((sel-1))]}"
}

# ----------------------------------------------
# Optional docking box input
# ----------------------------------------------
ask_box() {
    local manual="$1"

    [[ "$manual" =~ ^[Yy]$ ]] || return 1

    echo "──────────────────────────────────────────────" >&2
    echo "BOX DEFINITION (center + size)" >&2
    echo "Enter: cx cy cz sx sy sz" >&2
    echo "──────────────────────────────────────────────" >&2

    read -r cx cy cz sx sy sz

    [[ -z "$cx" ]] && return 1

    printf -- "--box %s %s %s %s %s %s" \
        "$cx" "$cy" "$cz" "$sx" "$sy" "$sz"
}

print_cmd() {
    printf '%q ' "$@"
    echo
}


# ============================================================
# MENU FUNCTIONS (all original items preserved)
# ============================================================

workflow_menu() {

    clear
    echo "FULL DOCKING WORKFLOW"

    # ======================================================
    # INPUT SELECTION
    # ======================================================
    section "RECEPTOR (PDB)"
    receptor=$(choose_file "*.pdb") || return

    section "LIGAND DIRECTORY"
    ligdir=$(choose_directory_by_filetype "." "*.sdf") || return

    # ======================================================
    # CORE PARAMETERS (grouped)
    # ======================================================
    echo "──────────────────────────────────────────────"
    echo "CORE PARAMETERS"
    echo "──────────────────────────────────────────────"

    read -rp "Force field [MMFF94]: " ff
    read -rp "Steps [5000]: " steps

    ff=${ff:-MMFF94}
    steps=${steps:-5000}

    echo "──────────────────────────────────────────────"
    echo "DOCKING PARAMETERS"
    echo "──────────────────────────────────────────────"

    read -rp "Exhaustiveness [8]: " exhaust
    read -rp "CPU [4]: " cpu

    exhaust=${exhaust:-8}
    cpu=${cpu:-4}

    echo "──────────────────────────────────────────────"
    echo "OPTIONAL FILTERS"
    echo "──────────────────────────────────────────────"

    read -rp "Keep ligand(s) (space-separated, optional): " keep
    read -rp "Keep chain(s) (space-separated, optional): " chains

    echo "──────────────────────────────────────────────"
    echo "BOX DEFINITION"
    echo "──────────────────────────────────────────────"

    read -rp "Manual box? [y/N]: " manual

    # ======================================================
    # COMMAND BUILD (SAFE)
    # ======================================================
    cmd=(
        domeeko full
        --receptor "$receptor"
        --lig_dir "$ligdir"
        --ff "$ff"
        --steps "$steps"
        --exhaustiveness "$exhaust"
        --cpu "$cpu"
    )

    # Optional arguments
    [[ -n "$keep" ]] && cmd+=(--keep_lig $keep)
    [[ -n "$chains" ]] && cmd+=(--chain $chains)

    # Box handling (safe)
    box=$(ask_box "$manual") || true
    if [[ -n "$box" ]]; then
        read -r -a box_args <<< "$box"
        cmd+=("${box_args[@]}")
    fi

    # ======================================================
    # PREVIEW
    # ======================================================
    section "COMMAND"
    printf '%q ' "${cmd[@]}"
    echo

    # ======================================================
    # EXECUTION
    # ======================================================
    read -rp "Run? [y/N]: " r

    if [[ "$r" =~ ^[Yy]$ ]]; then
        "${cmd[@]}"
    fi

    pause
}

docking_menu() {

    clear
    echo "DOCKING (blind docking)"

    # -------------------------
    # INPUTS
    # -------------------------
    section "RECEPTOR PDBQT"
    receptor=$(choose_file "*.pdbqt" ".") || return

    section "LIGAND DIRECTORY"
	ligdir=$(choose_directory_by_filetype "." "*.pdbqt") || return

    read -rp "Exhaustiveness [8]: " exhaust
    read -rp "CPU [4]: " cpu
    read -rp "Manual box? [y/N]: " manual

    exhaust=${exhaust:-8}
    cpu=${cpu:-4}

    # -------------------------
    # BUILD COMMAND (SAFE)
    # -------------------------
    cmd=(
        domeeko dock
        --receptor "$receptor"
        --lig_pdbqt "$ligdir"
        --exhaustiveness "$exhaust"
        --cpu "$cpu"
    )

    # -------------------------
    # OPTIONAL BOX
    # -------------------------
    box=$(ask_box "$manual") || true

    if [[ -n "$box" ]]; then
        read -r -a box_args <<< "$box"
        cmd+=("${box_args[@]}")
    fi

    # -------------------------
    # PREVIEW
    # -------------------------
    section "COMMAND"
    print_cmd "${cmd[@]}"

    # -------------------------
    # EXECUTION
    # -------------------------
    read -rp "Run? [y/N]: " r

    if [[ "$r" =~ ^[Yy]$ ]]; then
        "${cmd[@]}"
    fi

    pause
}


ligand_menu() {

    while true; do
        clear

        cat <<'EOF'
==========================================
LIGAND TOOLS
==========================================
  [1] Ligand Format Conversion
  [2] Ligand Preparation
  [0] Back
==========================================
EOF

        printf "Select: " >&2
        read -r c
        [[ -z "$c" ]] && continue

        case "$c" in

        1)
            section "LIGAND FORMAT CONVERSION"

            input_dir=$(choose_directory_by_filetype "." "*.sdf") || {
                echo "[INFO] No directory selected"
                read -rp "Press Enter to continue..." _
                continue
            }

            printf "Output format [sdf]: " >&2
            read -r outtype
            outtype=${outtype:-sdf}

            printf "Run QC stage? [y/N]: " >&2
            read -r qc

            printf "Run PAINS filter? [y/N]: " >&2
            read -r pains

            printf "Run Lipinski filter? [y/N]: " >&2
            read -r lip

            cmd=(
                domeeko lig_format
                --input "$input_dir"
                --outtype "$outtype"
            )

            [[ "$qc" =~ ^[Yy]$ ]] && cmd+=(--qc)
            [[ "$pains" =~ ^[Yy]$ ]] && cmd+=(--pains)
            [[ "$lip" =~ ^[Yy]$ ]] && cmd+=(--lipinski)

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

            printf "Run? [Y/n]: " >&2
            read -r r
            if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
                "${cmd[@]}"
            fi

            pause
            ;;

        2)
            section "LIGAND PREPARATION"

            ligdir=$(choose_directory_by_filetype "." "*.sdf") || {
                echo "[INFO] No directory selected"
                read -rp "Press Enter to continue..." _
                continue
            }

            printf "Force field [MMFF94]: " >&2
            read -r ff
            ff=${ff:-MMFF94}

            printf "Steps [5000]: " >&2
            read -r steps
            steps=${steps:-5000}

            # OpenBabel options
            printf "Add ALL hydrogens (-h)? [Y/n]: " >&2
            read -r h_ans
            h_ans=${h_ans:-Y}
            local h_flag="yes"
            [[ "$h_ans" =~ ^[Nn]$ ]] && h_flag="no"

            local addpolarh_flag="no"
            if [[ "$h_flag" == "no" ]]; then
                printf "Add only POLAR hydrogens (--polarh)? [y/N]: " >&2
                read -r polar_ans
                [[ "$polar_ans" =~ ^[Yy]$ ]] && addpolarh_flag="yes"
            fi

            printf "Generate 3D coordinates (--gen3d)? [Y/n]: " >&2
            read -r gen3d_ans
            gen3d_ans=${gen3d_ans:-Y}
            local gen3d_flag="yes"
            [[ "$gen3d_ans" =~ ^[Nn]$ ]] && gen3d_flag="no"

            printf "Minimize geometry (--minimize)? [Y/n]: " >&2
            read -r min_ans
            min_ans=${min_ans:-Y}
            local minimize_flag="yes"
            [[ "$min_ans" =~ ^[Nn]$ ]] && minimize_flag="no"

            cmd=(
                domeeko lig_prep
                --lig_dir "$ligdir"
                --ff "$ff"
                --steps "$steps"
                --h "$h_flag"
                --gen3d "$gen3d_flag"
                --minimize "$minimize_flag"
            )
            [[ "$addpolarh_flag" == "yes" ]] && cmd+=(--addpolarh "$addpolarh_flag")

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

            printf "Run? [Y/n]: " >&2
            read -r r
            if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
                "${cmd[@]}"
            fi

            pause
            ;;

        0)
            break
            ;;

        *)
            echo "[ERROR] Invalid selection"
            read -rp "Press Enter to continue..." _
            ;;
        esac
    done
}

receptor_menu() {

    while true; do
        clear

        cat <<'EOF'
==========================================
RECEPTOR TOOLS
==========================================
  [1] Receptor Preparation
  [2] Get Docking Center
  [0] Back
==========================================
EOF

        printf "Select: " >&2
        read -r c
        [[ -z "$c" ]] && continue

        case "$c" in

        # ======================================================
        # 1. RECEPTOR PREPARATION
        # ======================================================
        1)
            section "RECEPTOR PREPARATION"

            receptor=$(choose_file "*.pdb") || {
                echo "[INFO] No receptor selected"
                read -rp "Press Enter to continue..." _
                continue
            }

            printf "Keep ligands (IDs): " >&2
            read -r keep

            printf "Keep chains (e.g. A B C): " >&2
            read -r chains

            printf "Use MGLTools pipeline? [y/N]: " >&2
            read -r mgl

            cmd=(
                domeeko rec_prep
                --receptor "$receptor"
            )

            [[ -n "$keep" ]] && cmd+=(--keep_lig $keep)
            [[ -n "$chains" ]] && cmd+=(--chain $chains)
            [[ "$mgl" =~ ^[Yy]$ ]] && cmd+=(--use_mgl)

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

			printf "Run? [Y/n]: " >&2
			read -r r
			if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
				"${cmd[@]}"
			fi


            pause
            ;;

        # ======================================================
        # 2. CENTER DETECTION
        # ======================================================
        2)
            section "GET DOCKING CENTER"

            pdb=$(choose_file "*.pdb") || {
                echo "[INFO] No structure selected"
                read -rp "Press Enter to continue..." _
                continue
            }

            printf "Ligand name (optional): " >&2
            read -r lig

            cmd=(
                domeeko get_center
                --pdb_file "$pdb"
            )

            [[ -n "$lig" ]] && cmd+=(--ligname "$lig")

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

			printf "Run? [Y/n]: " >&2
			read -r r
			if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
				"${cmd[@]}"
			fi


            pause
            ;;

        # ======================================================
        # EXIT
        # ======================================================
        0)
            break
            ;;

        *)
            echo "[ERROR] Invalid selection"
            read -rp "Press Enter to continue..." _
            ;;
        esac
    done
}

analysis_menu() {

    while true; do
        clear

        cat <<'EOF'
==========================================
ANALYSIS TOOLS
==========================================
  [1] Rank Docking Results
  [0] Back
==========================================
EOF

        printf "Select: " >&2
        read -r c
        [[ -z "$c" ]] && continue

        case "$c" in

        # ======================================================
        # RANKING
        # ======================================================
        1)
            section "DOCKING RANKING"

            logdir=$(choose_directory_by_filetype "." "*.log") || {
                echo "[INFO] No log directory selected"
                read -rp "Press Enter to continue..." _
                continue
            }

            printf "Output CSV [ranked.csv]: " >&2
            read -r out
            out=${out:-ranked.csv}

            cmd=(
                domeeko rank
                --logdir "$logdir"
                --output "$out"
            )

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

			printf "Run? [Y/n]: " >&2
			read -r r
			if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
				"${cmd[@]}"
			fi


            pause
            ;;

        # ======================================================
        # EXIT
        # ======================================================
        0)
            break
            ;;

        *)
            echo "[ERROR] Invalid selection"
            read -rp "Press Enter to continue..." _
            ;;
        esac
    done
}

complex_menu() {

    while true; do
        clear

        cat <<'EOF'
==========================================
COMPLEX GENERATION
==========================================
  [1] Build Complexes from Docking
  [0] Back
==========================================
EOF

        printf "Select: " >&2
        read -r c
        [[ -z "$c" ]] && continue

        case "$c" in

        1)
            section "COMPLEX GENERATION"

            # -------------------------
            # Receptor selection
            # -------------------------
            rec=$(choose_file "*.pdbqt" "." 2) || {
                echo "[INFO] No receptor selected"
                read -rp "Press Enter..." _
                continue
            }

            [[ -f "$rec" ]] || {
                echo "[ERROR] Invalid receptor file"
                read -rp "Press Enter..." _
                continue
            }

            # -------------------------
            # Docked directory selection
            # -------------------------
            docked=$(choose_docked_directory "." 6 "*.pdbqt") || {
                echo "[INFO] No docked directory selected"
                read -rp "Press Enter..." _
                continue
            }

            [[ -d "$docked" ]] || {
                echo "[ERROR] Invalid docked directory"
                read -rp "Press Enter..." _
                continue
            }

            # -------------------------
            # Toplist selection
            # -------------------------
            toplist=$(choose_file "*.csv" "." 3) || {
                echo "[INFO] No toplist selected"
                read -rp "Press Enter..." _
                continue
            }

            [[ -f "$toplist" ]] || {
                echo "[ERROR] Invalid toplist file"
                read -rp "Press Enter..." _
                continue
            }

            # -------------------------
            # Parameters
            # -------------------------
            printf "Top N [10]: " >&2
            read -r n
            n=${n:-10}

            # -------------------------
            # Command
            # -------------------------
            cmd=(
                domeeko make_complex
                --receptor "$rec"
                --docked_pdbqt "$docked"
                --toplist "$toplist"
                --topn "$n"
            )

            section "COMMAND"
            printf '%q ' "${cmd[@]}"
            echo

			printf "Run? [Y/n]: " >&2
			read -r r
			if [[ -z "$r" || "$r" =~ ^[Yy]$ ]]; then
				"${cmd[@]}"
			fi


            pause
            ;;

        0)
            break
            ;;

        *)
            echo "[ERROR] Invalid selection"
            read -rp "Press Enter..." _
            ;;
        esac
    done
}


config_menu() {

    while true; do

        clear

cat <<'EOF'
==========================================
CONFIGURATION
==========================================
  [1] Show Current Configuration
  [2] Edit Setting
  [3] Save Current Environment
  [4] Reset to Defaults
  [5] Quick Performance Setup
  [0] Back
==========================================
EOF

        read -rp "Select: " c

        case "$c" in

            1)

                section "CURRENT CONFIGURATION"
                domeeko config
                pause
                ;;

            2)

                section "EDIT SETTING"

cat <<'EOF'
Examples:
  CPU=8
  EXH=24
  FF=MMFF94
  STEPS=5000
  PAD=5
  SEED=42
  OUT=docking_results
  LOG=logs

Multiple:
  CPU=8, EXH=32, PAD=8
EOF

                echo
                read -rp "KEY=VALUE pairs: " kv

                IFS=',' read -ra pairs <<< "$kv"

                cmd=(domeeko config --set)

                for p in "${pairs[@]}"; do
                    p="$(echo "$p" | xargs)"
                    [[ -n "$p" ]] && cmd+=("$p")
                done

                "${cmd[@]}"

                pause
                ;;

            3)

                domeeko config --save
                pause
                ;;

            4)

                read -rp "Reset configuration? [y/N]: " r

                if [[ "$r" =~ ^[Yy]$ ]]; then
                    domeeko config --reset
                fi

                pause
                ;;

            5)

                section "QUICK PERFORMANCE SETUP"

                read -rp "CPU cores [4]: " cpu
                read -rp "Exhaustiveness [16]: " exh

                cpu=${cpu:-4}
                exh=${exh:-16}

                domeeko config --set \
                    CPU="$cpu" \
                    EXH="$exh"

                pause
                ;;

            0)
                break
                ;;

            *)
                echo "[ERROR] Invalid selection"
                pause
                ;;
        esac
    done
}

examples_menu() {
    clear
    cat <<'EOF'
EXAMPLES
  domeeko full --receptor protein.pdb --lig_dir ligands/
  domeeko dock --receptor rec.pdbqt --lig_pdbqt pdbqt_out/
  domeeko rec_prep --receptor protein.pdb
  domeeko lig_prep --lig_dir ligands/ --ff MMFF94
  domeeko rank --logdir logs/ --output results.csv
EOF
    pause
}

system_check_menu() {
    clear
    for t in vina obabel python3; do
        command -v "$t" >/dev/null && echo "[OK] $t" || echo "[FAIL] $t"
    done
    pause
}

# ============================================================
# MAIN MENU (shows non‑empty subdirs)
# ============================================================
interactive_menu() {
    while true; do
        clear

        echo "=========================================="
        echo "DOMEEKO MENU"
        echo "Current directory: $(pwd)"
        echo "=========================================="

        cat <<'EOF'
  [1] Full Docking Workflow
  [2] Ligand Tools
  [3] Receptor Tools
  [4] Docking
  [5] Analysis
  [6] Complex Generation
  [7] Configuration
  [8] Examples
  [9] System Check
  [0] Exit
EOF

        echo "=========================================="

        read -rp "Select: " c

        case "$c" in
            1) workflow_menu ;;
            2) ligand_menu ;;
            3) receptor_menu ;;
            4) docking_menu ;;
            5) analysis_menu ;;
            6) complex_menu ;;
            7) config_menu ;;
            8) examples_menu ;;
            9) system_check_menu ;;
            0) exit 0 ;;
            *)
                echo "[ERROR] Invalid selection"
                read -rp "Press Enter to continue..." _
                ;;
        esac
    done
}
# ----------------------------------------------
# ENTRY POINT
# ----------------------------------------------
#interactive_menu