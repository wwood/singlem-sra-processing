"""
File-discovery workflow.

Scans /mnt/hpccs01/datasets/deepocean for FASTQ files, skipping any
directory whose name ends with '_qc'.  Handles both flat layouts:
  <dir>/<ACC>_1.fastq.gz
and one-level-nested layouts:
  <dir>/<ACC>/<ACC>_1.fastq.gz

Some accessions have three files: a paired _1/_2 plus a single-end file
(e.g. SRR6403623).  The extra single-end file is captured in the 'r0' column.

Produces a CSV with columns: acc, r1, r2, r0, reads_r1, reads_r2, reads_r0
(r2, r0, and their counts are empty for single-end-only samples).

Requires a config entry 'samples_csv' specifying the output path, supplied via:
  --configfile myconfig.yaml   (YAML must contain  samples_csv: path/to/out.csv)
  --config samples_csv=path/to/out.csv
"""

import os
import re
import shlex
import subprocess
from collections import defaultdict
from pathlib import Path


# ── config ────────────────────────────────────────────────────────────────────
if "samples_csv" not in config:
    raise SystemExit(
        "ERROR: 'samples_csv' must be set in config.\n"
        "  Use --configfile myconfig.yaml  or  --config samples_csv=path/to/out.csv"
    )

DEEPOCEAN_DIR = "/mnt/hpccs01/datasets/deepocean"
SAMPLES_CSV   = config["samples_csv"]

_csv_path  = Path(SAMPLES_CSV)
BASE_CSV   = str(_csv_path.parent / (_csv_path.stem + ".base.csv"))
COUNTS_DIR = str(_csv_path.parent / (_csv_path.stem + "_line_counts"))

# ── blacklist ─────────────────────────────────────────────────────────────────
BLACKLIST = set()
for _bl_file in Path("blacklists").glob("*"):
    if _bl_file.is_file():
        BLACKLIST.update(
            line.strip()
            for line in _bl_file.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        )


# ── aggregation helper ────────────────────────────────────────────────────────
def _count_path(acc):
    return os.path.join(COUNTS_DIR, acc[:7], f"{acc}.txt")

def _all_count_files(wildcards):
    """Return paths to all per-acc count files (resolved after checkpoint runs)."""
    import pandas as pd
    import random
    base_csv = BASE_CSV
    df = pd.read_csv(base_csv)
    accs = df["acc"].tolist()
    random.seed(42)
    random.shuffle(accs)
    return [_count_path(acc) for acc in accs]


localrules: all
    

# ── rules ─────────────────────────────────────────────────────────────────────
rule all:
    input: SAMPLES_CSV


checkpoint find_samples:
    """Scan deepocean, build base CSV (acc, r1, r2, r0) without read counts."""
    output: temp(BASE_CSV)
    resources:
        runtime = '1h',
    run:
        deepocean = Path(DEEPOCEAN_DIR)
        samples = defaultdict(dict)   # acc -> {r1, r2, r0}

        # Collect all FASTQ paths first so we can do two passes
        all_files = []
        for top in sorted(deepocean.iterdir()):
            if not top.is_dir() or top.name.endswith("_qc"):
                continue
            for f in sorted(top.glob("*.fastq.gz")):
                all_files.append(f)
            for sub in sorted(top.iterdir()):
                if not sub.is_dir():
                    continue
                for f in sorted(sub.glob("*.fastq.gz")):
                    all_files.append(f)

        # First pass: paired files (_1 / _2 suffixes take priority)
        for f in all_files:
            name = f.name
            m = re.fullmatch(r"(.+)_1\.fastq\.gz", name)
            if m:
                samples[m.group(1)]["r1"] = str(f)
                continue
            m = re.fullmatch(r"(.+)_2\.fastq\.gz", name)
            if m:
                samples[m.group(1)]["r2"] = str(f)

        # Second pass: single-end files (no _1 / _2 suffix)
        for f in all_files:
            name = f.name
            if re.fullmatch(r".+_(1|2)\.fastq\.gz", name):
                continue
            m = re.fullmatch(r"(.+)\.fastq\.gz", name)
            if m:
                acc = m.group(1)
                if "r1" not in samples[acc]:
                    samples[acc]["r1"] = str(f)
                else:
                    # Paired already registered; store as companion single-end
                    samples[acc]["r0"] = str(f)

        kept = {acc: v for acc, v in samples.items() if acc not in BLACKLIST}

        os.makedirs(str(_csv_path.parent), exist_ok=True)
        with open(output[0], "w") as fh:
            fh.write("acc,r1,r2,r0\n")
            for acc in sorted(kept):
                r1 = kept[acc].get("r1", "")
                r2 = kept[acc].get("r2", "")
                r0 = kept[acc].get("r0", "")
                fh.write(f"{acc},{r1},{r2},{r0}\n")

        n_paired = sum(1 for v in kept.values() if v.get("r2"))
        n_triple = sum(1 for v in kept.values() if v.get("r0"))
        n_single = sum(1 for v in kept.values() if not v.get("r2"))
        n_blacklisted = len(samples) - len(kept)
        print(
            f"Found {len(kept)} samples "
            f"({n_paired} paired, {n_single} single-end, {n_triple} with companion single) "
            f"→ {output[0]} "
            f"(skipped {n_blacklisted} of {len(BLACKLIST)} blacklisted)"
        )


rule count_lines_acc:
    """Count lines via 'pigz -cd | wc -l' for a single accession."""
    input:
        BASE_CSV,
    output:
        temp(os.path.join(COUNTS_DIR, "{prefix}", "{acc}.txt")),
    group: "count_lines_acc"
    resources:
        runtime = '4h',
    run:
        import pandas as pd
        df = pd.read_csv(input[0])
        row = df.loc[df["acc"] == wildcards.acc]
        if row.empty:
            raise SystemExit(f"ERROR: accession not found in base CSV: {wildcards.acc}")
        row = row.iloc[0]

        os.makedirs(os.path.dirname(output[0]), exist_ok=True)
        with open(output[0], "w") as fh:
            fh.write("acc\tcol\tlines\n")
            for col in ("r1", "r2", "r0"):
                path = row[col]
                if not isinstance(path, str) or not path:
                    continue
                proc = subprocess.run(
                    f"pigz -cd {shlex.quote(path)} | wc -l",
                    shell=True, capture_output=True, text=True, check=True,
                )
                n_lines = proc.stdout.strip()
                fh.write(f"{row['acc']}\t{col}\t{n_lines}\n")


rule build_final_csv:
    """Merge line counts into the samples CSV and add reads_{r1,r2,r0} columns."""
    input:
        base   = BASE_CSV,
        chunks = _all_count_files,
    output:
        SAMPLES_CSV,
    resources:
        runtime = '1h',
    run:
        import pandas as pd
        df = pd.read_csv(input.base)

        # Aggregate line counts from all chunk files
        counts = {}   # (acc, col) -> int(lines)
        for chunk_file in input.chunks:
            with open(chunk_file) as fh:
                try:
                    next(fh)  # skip header
                except StopIteration:
                    raise ValueError(f"Empty line count file: {chunk_file}")
                for line in fh:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 3:
                        acc, col, n = parts
                        counts[(acc, col)] = int(n)

        # Add reads_{col} columns (FASTQ: 4 lines per read)
        for col in ("r1", "r2", "r0"):
            reads_col = f"reads_{col}"
            def get_reads(row, _col=col):
                path = row[_col]
                if not isinstance(path, str) or not path:
                    return ""
                n = counts.get((row["acc"], _col))
                return n // 4 if n is not None else ""
            df[reads_col] = df.apply(get_reads, axis=1)

        df.to_csv(output[0], index=False)
        print(f"Written {len(df)} samples with read counts → {output[0]}")
