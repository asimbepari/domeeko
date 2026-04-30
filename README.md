# domeeko – CLI Toolkit for Molecular Docking Workflows

**domeeko** is a modular command‑line tool that automates the entire molecular docking pipeline:  
receptor and ligand preparation, AutoDock Vina docking, and result ranking. It integrates modern tools like **Meeko**, **Open Babel**, **RDKit**, and **pdbfixer**, while also offering a legacy **MGLTools** mode.

---

## For Beginners (Quick Summary)

**What is molecular docking?**  
Docking tries to predict how a small molecule (ligand) binds to a protein (receptor).  
It requires:

1. **Receptor preparation** – clean the protein (add hydrogens, fix residues, remove water).
2. **Ligand preparation** – convert ligands to 3D, add hydrogens, assign charges.
3. **Docking** – search for the best binding pose using AutoDock Vina.
4. **Ranking** – sort all docked ligands by binding affinity.

**What domeeko does for you:**  
- Prepares receptors **without** MGLTools (using Meeko + pdbfixer) – *faster, more reliable*.
- Prepares ligands (SDF → 3D → PDBQT) with RDKit and Open Babel.
- Automatically computes the docking box around your ligand (or a specific residue).
- Runs multiple docking jobs in parallel, using all CPU cores.
- Parses all results and creates a ranked CSV file.

**You only need to provide:**  
- A receptor PDB file.  
- A directory with ligand SDF or PDB files.  

Then run `domeeko full --receptor protein.pdb --lig_dir ligands/` – and you get a sorted list of best binders.

---

## Requirements

- Linux / macOS (bash environment)
- Conda (recommended for installation) – [Miniconda](https://docs.conda.io/en/latest/miniconda.html) or [Anaconda](https://www.anaconda.com/download)
- Python ≥3.10 (handled automatically by conda)
- The following tools are installed as conda dependencies:
  - [RDKit](https://www.rdkit.org/) ≥2023.09
  - [Open Babel](https://openbabel.org/) ≥3.1.1
  - [AutoDock Vina](https://vina.scripps.edu/) ≥1.2.5
  - [Meeko](https://github.com/forlilab/meeko) ≥0.7
  - [pdbfixer](https://github.com/openmm/pdbfixer)

---

## Installation

### From Anaconda (recommended)

`domeeko` is available as a conda package on the `asimbepari` channel.  
Install it directly into any conda environment (e.g., base or a fresh one).

Create a dedicated environment:

```bash
conda create -n docking -c asimbepari domeeko
conda activate docking
conda install -c asimbepari domeeko
```

### From GitHub (manual setup)

If you don’t want to use conda, you can run domeeko directly from the source:

```bash
git clone https://github.com/asimbepari/domeeko.git
cd domeeko
export PATH="$PWD/bin:$PATH"          # add bin/ to your PATH
```
All dependencies must be installed manually (see Requirements above).
The script expects the helper scripts in share/domeeko/scripts, which are automatically sourced from the cloned directory.

#### Uninstall
If installed via conda:

```bash
conda remove domeeko
```
If installed manually, remove the repository folder and edit your PATH accordingly.

## Usage

### General Syntax
 
`domeeko` <command> [options]

Available commands:

| Command      | Description                                                         |
| ------------ | ------------------------------------------------------------------- |
| `lig_prep`   | Prepare ligands: generate 3D structures and convert to PDBQT        |
| `rec_prep`   | Prepare receptor PDB: clean structure, add hydrogens, output PDBQT  |
| `full`       | Run full pipeline (receptor + ligand prep + docking + ranking)      |
| `dock`       | Perform docking using pre-prepared PDBQT files                      |
| `rank`       | Parse docking logs and generate ranked CSV                          |
| `get_center` | Compute docking box center and size from ligand or residue          |


## Examples

1. **Prepare only ligands**  
   Convert all SDF/PDB files in `ligands/` to PDBQT (3D + MMFF minimization):  
   `domeeko lig_prep --lig_dir ligands/ --steps 5000 --ff MMFF94`  
   Output is written to `pdbqt_out/` by default.

2. **Prepare only receptor**  
   `domeeko rec_prep --receptor protein.pdb`  
   If you prefer the legacy MGLTools pipeline (requires MGLTools installed separately):  
   `domeeko rec_prep --receptor protein.pdb --use_mgl --mgl_path /opt/mgltools/bin`

3. **Full pipeline (receptor + ligands + docking + ranking)**  
   `domeeko full --receptor protein.pdb --lig_dir ligands/ --exhaustiveness 16 --cpu 8`  
   Output:  
   - `docking_results/` – PDBQT poses and Vina logs for each ligand.  
   - `logs/` – detailed log files.  
   - `ranked_results.csv` – summary of all ligands sorted by affinity.

4. **Manual docking box**  
   If the automatic box (based on ligand center) is not suitable, specify it explicitly:  
   `domeeko dock --receptor protein.pdbqt --lig_pdbqt pdbqt_out/ --box 12.3 5.6 9.1 20 20 20`  
   Here `cx cy cz sx sy sz` = center coordinates (Å) and box size (Å).

5. **Rank existing docking logs**  
   After running many docking jobs, gather and rank all results:  
   `domeeko rank --logdir logs/ --output best_ligands.csv`

6. **Compute box center from a specific residue**  
   `domeeko get_center --pdb_file protein.pdb --res_num 45 --chain A --padding 8`  
   This prints the box center and size that encloses residue 45 with 8Å padding.
   

## Command Reference

| Option / Argument | Description |
|------------------|-------------|
| `--lig_dir DIR` | Directory containing ligand SDF/PDB files (`lig_prep`, `full`). |
| `--receptor FILE` | Receptor PDB file (`rec_prep`, `full`, `dock`). |
| `--lig_pdbqt DIR` | Directory with PDBQT files for docking (`dock`). |
| `--steps N` | MMFF minimization steps (default: 5000). |
| `--ff NAME` | Force field: MMFF94 or UFF (default: MMFF94). |
| `--use_mgl` | Use MGLTools for receptor prep (legacy). |
| `--mgl_path PATH` | Path to MGLTools installation (required with `--use_mgl`). |
| `--exhaustiveness N` | Vina exhaustiveness (default: 8). |
| `--cpu N` | Number of CPU cores (default: 4). |
| `--padding N` | Padding around ligand/residue (Å, default: 5). |
| `--seed N` | Random seed for Vina (default: 42). |
| `--outdir DIR` | Directory for docking results (default: `docking_results`). |
| `--logdir DIR` | Directory for logs (default: `logs`). |
| `--box CX CY CZ SX SY SZ` | Manual docking box (center + size in Å). |
| `--no-rank` | Skip ranking after docking. |
| `--pdb_file FILE` (`get_center`) | PDB file to analyse. |
| `--ligname NAME` / `--res_num NUM` | Select ligand by name or residue by number. |
| `--chain LETTER` | Chain identifier (default: A). |
| `--list-ligands` | List all ligands found in PDB. |
| `--write-ligands` | Write each ligand to a separate PDB file. |
| `--out FILE` | Output file for box coordinates. |

## Troubleshooting
command not found: domeeko – Make sure the conda environment is activated or the bin/ folder is in your PATH.

Missing dependencies – Run conda install rdkit openbabel vina meeko pdbfixer.

MGLTools not found – Install MGLTools separately or use the default Meeko pipeline (no --use_mgl).

Vina fails with “can’t find receptor” – Ensure the receptor PDBQT file exists (run rec_prep first).

## License
domeeko is released under the MIT License. See the LICENSE file in the repository.

## Maintainer
Bepari, Asim Kumar – for issues, feature requests, or contributions.
asimbepari@gmail.com, asim.bepari@northsouth.edu

## Citation information

Bepari, Asim Kumar. (2026). domeeko: CLI Toolkit for Molecular Docking Workflows (Version 0.1.0) [Computer software]. GitHub. https://github.com/asimbepari/domeeko

OR

Bepari, Asim Kumar, "domeeko: CLI Toolkit for Molecular Docking Workflows", version 0.1.0, GitHub, 2026. [Online]. Available: https://github.com/asimbepari/domeeko

### 
@software{domeeko_2026,
  author       = {Bepari, Asim Kumar},
  title        = {domeeko: CLI Toolkit for Molecular Docking Workflows},
  year         = {2026},
  version      = {0.1.0},
  publisher    = {GitHub},
  url          = {https://github.com/asimbepari/domeeko}
}