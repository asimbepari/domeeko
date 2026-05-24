#!/usr/bin/env bash
#cmd_prep.sh
cmd_lig_format() {

    load_config

    local input=""
    local outdir="${LIG_FORMAT_OUTDIR:-}"
    local outtype="${LIG_FORMAT_TYPE:-sdf}"

    local run_qc=false
    local run_pains=false
    local run_lipinski=false

    while [[ $# -gt 0 ]]; do
        case "$1" in

            --input) input="$2"; shift 2 ;;
            --outdir) outdir="$2"; shift 2 ;;
            --outtype) outtype="$2"; shift 2 ;;

            --qc) run_qc=true; shift ;;
            --pains) run_pains=true; shift ;;
            --lipinski) run_lipinski=true; shift ;;

            --mw-min) mw_min="$2"; shift 2 ;;
            --mw-max) mw_max="$2"; shift 2 ;;
            --min-atoms) min_atoms="$2"; shift 2 ;;
            --max-atoms) max_atoms="$2"; shift 2 ;;

            --no-h) no_h=true; shift ;;
            --keep-salt) keep_salt=true; shift ;;

            *)
                echo "[ERROR] Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    [[ -z "$input" ]] && {
        echo "[ERROR] --input required"
        exit 1
    }

    ensure_docking_env

    # ------------------------------------------------------
    # CRITICAL FIX:
    # export flags so RDKit QC can see them
    # ------------------------------------------------------
    export run_lipinski
    export run_pains

    lig_format_main \
        --input "$input" \
        ${outdir:+--outdir "$outdir"} \
        --outtype "$outtype" \
        $([[ "${no_h:-false}" == true ]] && echo "--no-h") \
        $([[ "${keep_salt:-false}" == true ]] && echo "--keep-salt") \
        ${mw_min:+--mw-min "$mw_min"} \
        ${mw_max:+--mw-max "$mw_max"} \
        ${min_atoms:+--min-atoms "$min_atoms"} \
        ${max_atoms:+--max-atoms "$max_atoms"}

    # ------------------------------------------------------
    # CRITICAL FIX:
    # QC is applied AFTER conversion, not passed as flag
    # ------------------------------------------------------
    if [[ "$run_qc" == true ]]; then
		echo "[INFO] Running ligand QC stage..."

		shopt -s nullglob

		files=("$outdir"/*.sdf)

		if (( ${#files[@]} == 0 )); then
			echo "[WARN] No SDF files found for QC"
		else
			for f in "${files[@]}"; do
				chemical_qc "$f" || {
					echo "[QC FAIL] $f rejected"
				}
			done
		fi

		shopt -u nullglob
	fi

    echo "[INFO] lig_format completed successfully"
}

cmd_lig_prep() {
    load_config

    # Defaults (from prep.sh, but can be overridden)
    local h_flag="yes"
    local gen3d_flag="yes"
    local minimize_flag="yes"
    local addpolarh_flag="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lig_dir)     ligdir="$2"; shift 2 ;;
            --steps)       steps_mmff="$2"; shift 2 ;;
            --ff)          ff="$2"; shift 2 ;;
            --h)           h_flag="$2"; shift 2 ;;          # "yes" or "no"
            --gen3d)       gen3d_flag="$2"; shift 2 ;;
            --minimize)    minimize_flag="$2"; shift 2 ;;
            --addpolarh)   addpolarh_flag="$2"; shift 2 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done

    [[ -z "$ligdir" ]] && {
        echo "ERROR: --lig_dir required"
        exit 1
    }

    # Export the OpenBabel options for prep.sh
    export OBABEL_H="$h_flag"
    export OBABEL_GEN3D="$gen3d_flag"
    export OBABEL_MINIMIZE="$minimize_flag"
    export OBABEL_ADDPOLARH="$addpolarh_flag"

    ensure_docking_env

    echo "[DEBUG] ligdir=$ligdir"
    echo "[DEBUG] out_lig_3d=$out_lig_3d"
    echo "[DEBUG] out_lig_pdbqt=$out_lig_pdbqt"
    echo "[DEBUG] OBABEL_H=$OBABEL_H, OBABEL_GEN3D=$OBABEL_GEN3D, OBABEL_MINIMIZE=$OBABEL_MINIMIZE, OBABEL_ADDPOLARH=$OBABEL_ADDPOLARH"

    ligand_3d_gen
    ligand_pdbqt_convert
}
cmd_rec_prep() {

    load_config

    local recpdb=""
    local USE_MGL=false
    local MGL="${MGL:-}"

    local -a KEEP_LIGANDS=()
    local -a KEEP_CHAINS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in

            --receptor) recpdb="$2"; shift 2 ;;

            --keep_lig)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    KEEP_LIGANDS+=("$1")
                    shift
                done
                ;;

            --chain)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    KEEP_CHAINS+=("$1")
                    shift
                done
                ;;

            --use_mgl)
                USE_MGL=true
                shift
                ;;

            --mgl_path)
                MGL="$2"
                shift 2
                ;;

            *)
                echo "[ERROR] Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    [[ -z "$recpdb" ]] && {
        echo "[ERROR] --receptor is required"
        exit 1
    }

    [[ ! -f "$recpdb" ]] && {
        echo "[ERROR] File not found: $recpdb"
        exit 1
    }

    ensure_docking_env || exit 1

    # ======================================================
    # STEP 1: QC
    # ======================================================
    receptor_qc || {
        echo "[ERROR] Receptor QC failed"
        exit 1
    }

    [[ ! -s "$recpdb" ]] && {
        echo "[ERROR] QC produced empty receptor"
        exit 1
    }

    echo "[INFO] QC complete: $recpdb"

    # ======================================================
    # STEP 2: CHAIN FILTERING
    # ======================================================
    if [[ ${#KEEP_CHAINS[@]} -gt 0 ]]; then

        local chain="${KEEP_CHAINS[0]}"
        local chain_pdb="${recpdb%.pdb}_chain${chain}.pdb"

        awk -v ch="$chain" '
        /^ATOM|^HETATM/ {
            if (substr($0,22,1) != ch) next
        }
        { print }
        ' "$recpdb" > "$chain_pdb"

        [[ ! -s "$chain_pdb" ]] && {
            echo "[ERROR] Chain filtering failed: $chain"
            exit 1
        }

        recpdb="$chain_pdb"
        echo "[INFO] Chain selected: $chain"
    fi

    # ======================================================
    # STEP 3: LIGAND REMOVAL HOOK (reserved)
    # ======================================================
    # KEEP_LIGANDS intentionally preserved for future receptor cleanup stage

    # ======================================================
    # STEP 4: PREP PIPELINE
    # ======================================================
    if [[ "$USE_MGL" == true ]]; then

        echo "[INFO] Using MGLTools pipeline"

        [[ -n "$MGL" ]] && export MGLTOOLS_PATH="$MGL"

        split_alt_mgl || exit 1
        receptor_prep_mgl || exit 1

    else

        echo "[INFO] Using Meeko pipeline"

        receptor_prep_meeko || exit 1

    fi

    echo "[INFO] Receptor preparation completed"
}

