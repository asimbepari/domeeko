#!/usr/bin/env bash
#cmd_full_dock.sh
cmd_full() {
    load_config

    # ======================================================
    # INPUTS
    # ======================================================
    local rec="" ligd=""
    local use_mgl=false
    local mgl_path=""

    local steps_val="$steps_mmff"
    local ff_val="$ff"

    local exhaust="$EXHAUSTIVENESS"
    local cpu_cores="$CPU"
    local pad="$PADDING"
    local seed_val="$SEED"

    local out_dir="$OUTDIR"
    local log_dir="$LOGDIR"

    local skip_rank=0

    local manual_box=0
    local cx="" cy="" cz="" sx="" sy="" sz=""

    # ligand + chain retention
    local -a KEEP_LIGANDS=()
    local -a KEEP_CHAINS=()

    # ======================================================
    # ARG PARSING
    # ======================================================
    while [[ $# -gt 0 ]]; do
        case "$1" in

            --receptor)
                rec="$2"
                shift 2
                ;;

            --lig_dir)
                ligd="$2"
                shift 2
                ;;

            # -------------------------
            # Ligand retention
            # -------------------------
            --keep_lig)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    KEEP_LIGANDS+=("$1")
                    shift
                done
                ;;

            # -------------------------
            # NEW: chain selection
            # -------------------------
            --chain)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                    KEEP_CHAINS+=("$1")
                    shift
                done
                ;;

            --steps)
                steps_val="$2"
                shift 2
                ;;

            --ff)
                ff_val="$2"
                shift 2
                ;;

            --use_mgl)
                use_mgl=true
                shift
                ;;

            --mgl_path)
                mgl_path="$2"
                shift 2
                ;;

            --exhaustiveness)
                exhaust="$2"
                shift 2
                ;;

            --cpu)
                cpu_cores="$2"
                shift 2
                ;;

            --padding)
                pad="$2"
                shift 2
                ;;

            --seed)
                seed_val="$2"
                shift 2
                ;;

            --outdir)
                out_dir="$2"
                shift 2
                ;;

            --logdir)
                log_dir="$2"
                shift 2
                ;;

            --no-rank)
                skip_rank=1
                shift
                ;;

            --box)
                manual_box=1
                cx="$2"; cy="$3"; cz="$4"
                sx="$5"; sy="$6"; sz="$7"
                shift 7
                ;;

            *)
                echo "Unknown: $1"
                usage
                exit 1
                ;;
        esac
    done

    # ======================================================
    # VALIDATION
    # ======================================================
    [[ -z "$rec" ]] && { echo "ERROR: --receptor required"; exit 1; }
    [[ -z "$ligd" ]] && { echo "ERROR: --lig_dir required"; exit 1; }

    recpdb="$rec"
    ligdir="$ligd"

    USE_MGL="$use_mgl"
    MGL="$mgl_path"

    steps_mmff="$steps_val"
    ff="$ff_val"

    EXHAUSTIVENESS="$exhaust"
    CPU="$cpu_cores"
    PADDING="$pad"
    SEED="$seed_val"

    OUTDIR="$out_dir"
    LOGDIR="$log_dir"

    if [[ $manual_box -eq 1 ]]; then
        MANUAL_BOX=1
        CENTER_X="$cx"; CENTER_Y="$cy"; CENTER_Z="$cz"
        SIZE_X="$sx"; SIZE_Y="$sy"; SIZE_Z="$sz"
    else
        MANUAL_BOX=0
    fi

    # ======================================================
    # ENVIRONMENT
    # ======================================================
    ensure_docking_env || exit 1

    # ======================================================
    # RECEPTOR QC (CHAIN-AWARE)
    # ======================================================
    if [[ ${#KEEP_CHAINS[@]} -gt 0 ]]; then
        receptor_qc "${KEEP_CHAINS[@]}" || {
            echo "[ERROR] receptor_qc failed"
            exit 1
        }
    else
        receptor_qc || {
            echo "[ERROR] receptor_qc failed"
            exit 1
        }
    fi

    [[ ! -f "$recpdb" || ! -s "$recpdb" ]] && {
        echo "[ERROR] QC did not produce valid receptor"
        exit 1
    }

    echo "[INFO] Active receptor after QC: $recpdb"

    # ======================================================
    # RECEPTOR PREP
    # ======================================================
    if $use_mgl; then
        echo "[INFO] Using MGLTools pipeline"

        split_alt_mgl || exit 1
        receptor_prep_mgl || exit 1

        RECEPTOR="${recpdb%.*}_A.pdbqt"
    else
        echo "[INFO] Using Meeko pipeline"

        receptor_prep_meeko || exit 1

        RECEPTOR="${recpdb%.*}.pdbqt"
    fi

    # ======================================================
    # LIGAND PREP
    # ======================================================
    # ======================================================
	# LIGAND PREP
	# ======================================================
	# Backup and clear previous formatted ligands
	backup_dir_if_nonempty "lig_formatted"
	
	lig_format_main \
		--input "$ligd" \
		--outdir lig_formatted \
		--outtype sdf \
		--remove_salt true \
		--add_h true

	ligdir="lig_formatted"

	ligand_3d_gen || exit 1
	ligand_pdbqt_convert || exit 1

    LIGAND_DIR="$out_pdbqt"

    # ======================================================
    # DOCKING
    # ======================================================
    batch_dock || exit 1

	# ======================================================
	# RANKING
	# ======================================================
	if [[ $skip_rank -eq 0 ]]; then

		echo "[TRACE] calling parse_and_rank"
		parse_and_rank || {
			echo "[ERROR] parse_and_rank failed"
			exit 1
		}

		#echo "[TRACE] ranking completed"

		DOCKED_PDBQT="$OUTDIR"
		TOPLIST="$RANK_OUTPUT"
		TOP_N=10
		OUT_COMPLEX="complexes"

		# echo "[TRACE] calling copy_top_docked"
		copy_top_docked || {
			echo "[ERROR] copy_top_docked failed"
			exit 1
		}

#		echo "[TRACE] calling make_complexes"
		make_complexes || {
			echo "[ERROR] make_complexes failed"
			exit 1
		}

	else
		echo "Ranking skipped (--no-rank)."
	fi

#	echo "[DEBUG] END OF cmd_full REACHED"
}

cmd_get_center() {
    # from center.sh
	fx_center_of_mass "$@"
}

cmd_dock() {

    load_config

    local lig_pdbqt_dir="" rec=""
    local skip_rank=0

    # ---------------------------
    # ARG PARSING
    # ---------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in

            --receptor)
                rec="$2"
                shift 2
                ;;

            --lig_pdbqt)
                lig_pdbqt_dir="$2"
                shift 2
                ;;

            --exhaustiveness)
                EXHAUSTIVENESS="$2"
                shift 2
                ;;

            --cpu)
                CPU="$2"
                shift 2
                ;;

            --padding)
                PADDING="$2"
                shift 2
                ;;

            --seed)
                SEED="$2"
                shift 2
                ;;

            --outdir)
                OUTDIR="$2"
                shift 2
                ;;

            --logdir)
                LOGDIR="$2"
                shift 2
                ;;

            --no-rank)
                skip_rank=1
                shift
                ;;

            --box)
                MANUAL_BOX=1
                CENTER_X="$2"; CENTER_Y="$3"; CENTER_Z="$4"
                SIZE_X="$5"; SIZE_Y="$6"; SIZE_Z="$7"
                shift 7
                ;;

            *)
                echo "[ERROR] Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # ---------------------------
    # VALIDATION
    # ---------------------------
    [[ -z "$rec" ]] && { echo "[ERROR] --receptor required"; exit 1; }
    [[ -z "$lig_pdbqt_dir" ]] && { echo "[ERROR] --lig_pdbqt required"; exit 1; }

    RECEPTOR="$rec"
    LIGAND_DIR="$lig_pdbqt_dir"

    echo "[INFO] Starting docking pipeline"
    echo "[INFO] Receptor   : $RECEPTOR"
    echo "[INFO] Ligands    : $LIGAND_DIR"
    echo "[INFO] Output dir : $OUTDIR"
    echo "[INFO] Log dir    : $LOGDIR"

    # ---------------------------
    # DOCKING
    # ---------------------------
    batch_dock || {
        echo "[ERROR] Docking failed"
        exit 1
    }

    # ---------------------------
    # RANKING + COMPLEX
    # ---------------------------
    if [[ $skip_rank -eq 0 ]]; then

        echo ""
        echo "[INFO] Running ranking..."

        parse_and_rank || {
            echo "[ERROR] Ranking failed"
            exit 1
        }

        echo "[INFO] Ranking completed"

        # ---------------------------
        # Complex generation stage
        # ---------------------------
        DOCKED_PDBQT="$OUTDIR"
        TOPLIST="$RANK_OUTPUT"
        TOP_N=10
        OUT_COMPLEX="complexes"

        echo "[INFO] Generating complexes from top hits..."

        copy_top_docked || {
            echo "[ERROR] copy_top_docked failed"
            exit 1
        }

        make_complexes || {
            echo "[ERROR] make_complexes failed"
            exit 1
        }

    else
        echo "[INFO] Ranking skipped (--no-rank)"
    fi

    echo "[INFO] Dock pipeline completed successfully"
}

cmd_rank() {

    load_config

    local LOGDIR=""
    local RANK_OUTPUT="ranked.csv"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logdir) LOGDIR="$2"; shift 2 ;;
            --output) RANK_OUTPUT="$2"; shift 2 ;;
            *)
                echo "Unknown: $1"
                usage
                exit 1
                ;;
        esac
    done

    [[ -z "$LOGDIR" ]] && {
        echo "ERROR: --logdir required"
        exit 1
    }

    ensure_docking_env || exit 1

    parse_and_rank
}

cmd_make_complex() {

    load_config

    local receptor=""
    local docked_dir=""
    local topn=10
    local toplist=""
    local out_complex="complexes"

    while [[ $# -gt 0 ]]; do
        case "$1" in

            --receptor) receptor="$2"; shift 2 ;;
            --docked_pdbqt) docked_dir="$2"; shift 2 ;;
            --topn) topn="$2"; shift 2 ;;
            --toplist) toplist="$2"; shift 2 ;;
            --out_complex) out_complex="$2"; shift 2 ;;

            *)
                echo "Unknown: $1"
                usage
                exit 1
                ;;
        esac
    done

    # =====================================================
    # VALIDATION (strict)
    # =====================================================
    [[ -z "$receptor" ]] && {
        echo "ERROR: --receptor required"
        exit 1
    }

    [[ -z "$docked_dir" ]] && {
        echo "ERROR: --docked_pdbqt required"
        exit 1
    }

    [[ -z "$toplist" ]] && {
        echo "ERROR: --toplist required"
        exit 1
    }

    [[ ! -f "$receptor" ]] && {
        echo "ERROR: receptor not found"
        exit 1
    }

    [[ ! -d "$docked_dir" ]] && {
        echo "ERROR: docked directory not found"
        exit 1
    }

    [[ ! -f "$toplist" ]] && {
        echo "ERROR: toplist not found"
        exit 1
    }

    ensure_docking_env || exit 1

    # =====================================================
    # STATE EXPORT (pipeline consistency)
    # =====================================================
    RECEPTOR="$receptor"
    DOCKED_PDBQT="$docked_dir"
    TOP_N="$topn"
    TOPLIST="$toplist"
    OUT_COMPLEX="$out_complex"

    echo "[INFO] Starting complex generation pipeline"

    # =====================================================
    # STEP 1: Copy top docked poses
    # =====================================================
    copy_top_docked || {
        echo "[ERROR] copy_top_docked failed"
        exit 1
    }

    # =====================================================
    # STEP 2: Build complexes
    # =====================================================
    make_complexes || {
        echo "[ERROR] make_complexes failed"
        exit 1
    }

    echo "[INFO] Complex generation completed successfully"
}
