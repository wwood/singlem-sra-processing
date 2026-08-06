# Image for running the Wagtail amplicon pipeline over SRA run accessions.
#
# Per accession the `wagtail-sra` wrapper in this image does:
#   kingfisher get -f sra                                   -> $A.sra
#   sracat-rs --qual -1 fwd -2 /dev/null --single-out orph   -> $A.fastq.gz
#   wagtail.py --amplicon 16S --use-conda                    -> $A_condensed.tsv
# Wagtail has no paired-end mode (it uses the forward read only), so sracat-rs
# decodes the reverse read of each pair straight to /dev/null and only R1 plus
# any single/orphan reads are kept. Unlike the weebill image nothing can be
# streamed through a FIFO: Wagtail is a Snakemake workflow whose first step is
# a QIIME2 import that seeks around a real .fastq.gz on disk.
#
# Wagtail itself is a Snakemake workflow with two conda environments (a small
# mappy/polars one and the ~2026.4 QIIME2 amplicon distribution). Both are
# built INTO the image at /opt/wagtail-envs so that a pod never solves or
# downloads an environment at run time; the smoke test below fails the build if
# a run would still create one.
#
# Reference databases are NOT baked in - they are far too big and change more
# often than the image. They are cached once per EC2 instance on a hostPath
# (exactly as the weebill workflow caches its .sylref via a fetch-references
# initContainer) and mounted read-only at /refcache; `wagtail-sra` symlinks them
# into /opt/wagtail/database, where Wagtail globs for {marker}_database* /
# {marker}_taxonomy* / {marker}_deblur*, stripping the "<16 hex>." prefix the
# cache adds. For 16S that is two files: a {16S_database*} FASTA for the mappy
# alignment and a {16S_taxonomy*} TSV for taxonomy extraction (q2-deblur's
# denoise-16S carries its own built-in reference). Auto-detection (--amplicon
# auto) additionally needs all four {marker}_database* files cached.
#
# Multi-stage: the Rust toolchain and the pixi/conda env that provides ncbi-vdb
# stay in the builder stage; the runtime stage carries the sracat-rs binary,
# kingfisher/aws-cli/prefetch, and the conda environments Wagtail runs in.
#
# Build (build context is this directory - it holds vdb-settings.kfg, the
# wagtail-sra wrapper and smoke_test_subset/):
#   docker build -f wagtail_build_from_source.Dockerfile . -t woodcrob/wagtail

# ---------------------------------------------------------------- builder stage
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    curl \
    build-essential \
    cmake \
    unzip

# Rust (minimal profile: no docs, no clippy/rustfmt)
RUN curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf \
      | bash -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# sracat-rs is compiled with `-C target-cpu=native`. This image is built on a
# worker node of the SAME instance type it runs on (see the cloud/argo nodegroup
# templates), so native codegen targets the exact CPU and is faster; it would
# only be unsafe if the image ran on an older CPU. `-C strip=symbols` drops
# debug symbols from the binary (tens of MB).
ENV RUSTFLAGS="-C target-cpu=native -C strip=symbols"

# sracat-rs - built from source (not the prebuilt release) so it gets
# `-C target-cpu=native`. It links ncbi-vdb, a conda-provided C library, so the
# build runs inside the pixi env declared in the sracat-rs repo (which supplies
# ncbi-vdb, a C/C++ compiler and zlib); build.rs needs CONDA_PREFIX, which
# `pixi run` sets. SRACAT_VDB_LINK=static links libncbi-vdb.a so the binary is
# self-contained and relocatable (no libncbi-vdb.so dependency, no conda rpath):
# only the binary is copied into the runtime stage; the pixi env is discarded.
RUN curl -fsSL https://pixi.sh/install.sh | bash
ENV PATH="/root/.pixi/bin:${PATH}"
ENV SRACAT_RS_COMMIT=v0.2.1
RUN git clone https://github.com/wwood/sracat-rs /tmp/sracat-rs \
    && cd /tmp/sracat-rs \
    && git checkout ${SRACAT_RS_COMMIT} \
    && pixi run -- env SRACAT_VDB_LINK=static cargo install --path . --root /usr/local

# The runtime stage has none of the conda/pixi libraries used here, so fail now
# if the binary still needs one: every resolved DSO must come from the base
# system (the Miniforge install in the runtime stage is NOT on its rpath).
RUN ldd /usr/local/bin/sracat-rs \
    && ! ldd /usr/local/bin/sracat-rs | grep -E '=> */(root|opt)/'

# Wagtail source, pinned. The checkout is copied into the runtime stage rather
# than cloned there, so the runtime image needs no git. b99a7ae is the head of
# the `development` branch (Wagtail v1.2) - `main` lags behind it.
ENV WAGTAIL_COMMIT=b99a7ae682febdc6aafdde6dfc68002371751327
RUN git clone https://github.com/R-Nurdiansyah/Wagtail /opt/wagtail \
    && cd /opt/wagtail \
    && git checkout ${WAGTAIL_COMMIT} \
    && rm -rf .git

# AWS CLI (kingfisher aws-http/aws-cp download and, in the workflow, artifact
# upload). Unpacked here so the runtime stage needs neither wget nor unzip.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && cd /tmp && unzip -q awscliv2.zip \
    && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# NCBI SRA Toolkit `prefetch` (kingfisher `-m prefetch` download method) staged
# into /opt/sratoolkit for copy into the runtime stage. Only the prefetch
# driver-dispatch set is kept rather than the ~200 MB toolkit: modern sra-tools
# ships `prefetch` as a symlink chain to `sratools` (a driver that inspects
# argv[0] and execs the real `<tool>-orig` binary), so the minimal working set is
#   sratools[.3][.<ver>]  - the argv[0] driver
#   prefetch[.3][.<ver>]  - symlinks resolving to sratools
#   prefetch-orig.<ver>   - the real prefetch binary the driver execs
#   ncbi/*.kfg            - config (SDL resolver URLs, cert store) the tools load
#                           relative to their own path; without it prefetch cannot
#                           resolve accessions
# cp -P preserves the symlinks (their targets are relative, so they stay valid).
# Both sratools and prefetch-orig link only glibc, so they run as-is at runtime.
ENV SRATOOLKIT_VERSION=3.4.1
RUN curl -fsSL "https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/${SRATOOLKIT_VERSION}/sratoolkit.${SRATOOLKIT_VERSION}-ubuntu64.tar.gz" -o /tmp/sratoolkit.tar.gz \
    && tar xzf /tmp/sratoolkit.tar.gz -C /tmp \
    && SRC=/tmp/sratoolkit.${SRATOOLKIT_VERSION}-ubuntu64/bin \
    && mkdir -p /opt/sratoolkit/bin/ncbi \
    && cp -P "$SRC/sratools.${SRATOOLKIT_VERSION}" "$SRC/sratools.3" "$SRC/sratools" \
             "$SRC/prefetch-orig.${SRATOOLKIT_VERSION}" \
             "$SRC/prefetch.${SRATOOLKIT_VERSION}" "$SRC/prefetch.3" "$SRC/prefetch" \
             /opt/sratoolkit/bin/ \
    && cp "$SRC"/ncbi/*.kfg /opt/sratoolkit/bin/ncbi/ \
    && /opt/sratoolkit/bin/prefetch --help > /dev/null \
    && rm -rf /tmp/sratoolkit.tar.gz /tmp/sratoolkit.${SRATOOLKIT_VERSION}-ubuntu64

# ---------------------------------------------------------------- runtime stage
FROM ubuntu:24.04 AS runtime

# aria2 + pigz for kingfisher downloads/compression, uuid-runtime for the vdb
# IMAGE_GUID below. bzip2/tar are needed by the Miniforge installer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        bzip2 \
        aria2 \
        pigz \
        procps \
        uuid-runtime \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Miniforge, NOT just micromamba: Snakemake's --use-conda shells out to a
# `conda` executable to activate each rule's environment, so conda itself has to
# be present at run time. This is the main structural difference from the
# weebill image, whose runtime stage carries no conda at all.
ENV MINIFORGE_VERSION=26.3.2-3
RUN curl -fsSL "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-x86_64.sh" -o /tmp/miniforge.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm -f /tmp/miniforge.sh
ENV PATH="/opt/conda/envs/wagtail/bin:/opt/conda/condabin:/opt/conda/bin:${PATH}"

# The launcher environment: Wagtail's own dependencies (pixi.toml: python
# >=3.9,<3.12 - so 3.11, which Snakemake 9 also requires - polars, mappy,
# snakemake 9.x and the cluster-generic executor plugin) plus kingfisher and the
# libraries it imports at startup. graphviz, which pixi.toml pulls in only for
# `snakemake --dag` rendering, is deliberately left out.
#
# kingfisher is installed from a pinned git commit (not PyPI) via GitHub's
# archive tarball, so no git is needed. Like its pip-installed deps it goes in
# with --no-dependencies, so its imports (pandas among them, imported at
# startup) are provided by conda above rather than resolved by pip.
RUN mamba create -y -n wagtail -c conda-forge -c bioconda \
        python=3.11 \
        'polars>=0.20.0' \
        'mappy>=2.24' \
        'snakemake>=9.5.0,<10' \
        #'snakemake-executor-plugin-cluster-generic>=1.0.9,<2' \
        pandas requests tqdm pip \
    && /opt/conda/envs/wagtail/bin/pip install --no-cache-dir --no-dependencies \
        bird_tool_utils argparse-manpage-birdtools extern \
        https://github.com/wwood/kingfisher-download/archive/9e4571ef002b03a92b6d8b81a48e3228e07a1554.tar.gz \
    && mamba clean -afy

# Wagtail itself (pinned commit, checked out in the builder stage). database/ is
# populated at run time by symlinking the node-local cache into it; run/ is
# where Wagtail writes every output, since it derives both paths from the
# location of this checkout rather than from the working directory.
COPY --from=builder /opt/wagtail /opt/wagtail
RUN mkdir -p /opt/wagtail/database /opt/wagtail/run

# Build BOTH of Wagtail's Snakemake conda environments into the image. Snakemake
# names an environment directory by hashing the env YAML together with the
# --conda-prefix path, so a run at run time reuses these only if it passes the
# same prefix - hence SNAKEMAKE_CONDA_PREFIX below, which both `wagtail-sra` and
# a bare `snakemake` pick up. The smoke test asserts no new environment appears,
# which is what catches a hash mismatch (a pod has no time, and may have no
# route, to solve the QIIME2 environment).
#
# --conda-create-envs-only still needs a parsable workflow, so a throwaway
# config with a one-sample list is used. The sample's FASTQ is never opened:
# Wagtail's rules declare the file_map as their input, not the reads. Forcing
# --amplicon 16S also skips the parse-time glob for the four identification
# databases, which are not in the image. The throwaway config is named
# config.yaml and run from its own directory because wagtail.smk carries a
# `configfile: "config.yaml"` directive that errors out if the file is missing:
# whether Snakemake resolves that name against the working directory or against
# the Snakefile, a file exists either way, and the explicit --configfile still
# wins. `wagtail-sra` lays its run out the same way for the same reason.
ENV SNAKEMAKE_CONDA_PREFIX=/opt/wagtail-envs
RUN mkdir -p /tmp/envbuild \
    && printf 'BUILDSAMPLE\n' > /tmp/envbuild/sample_list.txt \
    && printf 'BUILDSAMPLE\t/tmp/envbuild/BUILDSAMPLE.fastq.gz\n' > /tmp/envbuild/file_map.tsv \
    && printf 'run_name: "envbuild"\nsample_list: "/tmp/envbuild/sample_list.txt"\nfile_map: "/tmp/envbuild/file_map.tsv"\n' > /tmp/envbuild/config.yaml \
    && cd /tmp/envbuild \
    && python /opt/wagtail/wagtail.py --amplicon 16S \
        --use-conda --conda-prefix ${SNAKEMAKE_CONDA_PREFIX} --conda-create-envs-only \
        --cores 1 --configfile /tmp/envbuild/config.yaml \
    && rm -rf /tmp/envbuild /opt/wagtail/run/envbuild \
    && mamba clean -afy \
    && du -sh ${SNAKEMAKE_CONDA_PREFIX}

# ncbi-vdb configuration so sracat-rs can read reference-compressed (cSRA) runs -
# those submitted as aligned CRAM/BAM, whose READ bases are stored as differences
# against a reference genome. Reading them requires fetching the REFSEQ objects
# from NCBI into a writable cache; without this config that fetch never happens
# and the read dies on the first row with "row 1: reading READ failed", so
# sracat-rs emits nothing and the accession yields an empty FASTQ. See
# vdb-settings.kfg for the full rationale. The reference cache is POD-LOCAL
# (/root/ncbi/public on ephemeral disk, per vdb-settings.kfg), created here so
# the first read can write into it. IMAGE_GUID is a per-image identifier appended
# at build time (kept out of the committed file so each build is unique).
COPY vdb-settings.kfg /etc/ncbi/settings.kfg
RUN printf '/LIBS/IMAGE_GUID = "%s"\n' "$(uuidgen)" >> /etc/ncbi/settings.kfg \
    && mkdir -p /root/ncbi/public

COPY --from=builder /usr/local/bin/sracat-rs /usr/local/bin/sracat-rs
# The aws-cli install dir is copied wholesale (symlinks inside it are preserved),
# but /usr/local/bin/aws must be re-made here rather than COPYed: it is a symlink,
# and COPY dereferences a symlink given as its source, which would put the
# PyInstaller executable itself in /usr/local/bin, away from its bundled libpython.
COPY --from=builder /usr/local/aws-cli /usr/local/aws-cli
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws

# NCBI SRA Toolkit `prefetch` for kingfisher's `-m prefetch` download method. The
# minimal driver-dispatch set staged in the builder (see there); put its bin on
# PATH so kingfisher's plain `prefetch ...` invocation resolves it.
COPY --from=builder /opt/sratoolkit /opt/sratoolkit
ENV PATH="/opt/sratoolkit/bin:${PATH}"

# The download -> extract -> Wagtail driver. See its header for the contract.
COPY wagtail-sra /usr/local/bin/wagtail-sra
RUN chmod +x /usr/local/bin/wagtail-sra

ENV WAGTAIL_HOME=/opt/wagtail
# Node-local reference cache, mounted read-only by the workflow (hostPath).
ENV WAGTAIL_DB_CACHE=/refcache
# Default marker. "auto" (per-sample marker_id) instead requires all four
# {marker}_database* files in the cache.
ENV WAGTAIL_AMPLICON=16S
WORKDIR /work

# ------------------------------------------------------------------ smoke tests
# Exercise the exact download -> extract -> Wagtail path the workflow uses, so a
# broken image fails the build rather than the queue. This runs in a throwaway
# stage on top of the runtime image: the test's downloads, outputs and layers are
# never part of the shipped image, but the final stage COPYs from it, so the test
# must pass for the build to succeed.
FROM runtime AS smoketest
RUN sracat-rs --help > /dev/null
RUN aws --version
RUN prefetch --help > /dev/null
RUN kingfisher get --help > /dev/null
RUN snakemake --version && python /opt/wagtail/wagtail.py --version
RUN wagtail-sra --help > /dev/null

# A tiny 16S reference pair (a subset of the MFD database plus its taxonomy),
# staged the way the node-local cache stages the real thing. Enough to run the
# whole pipeline end to end on one amplicon run without a multi-GB download.
COPY smoke_test_subset /smoke-db

# ERR1519989 is a 16S amplicon run. This is the full pipeline: kingfisher ->
# sracat-rs -> QIIME2 import/quality-filter -> deblur denoise-16S -> mappy
# against 16S_database.tiny -> taxonomy extraction. --strict makes the wrapper
# exit non-zero if the sample soft-failed anywhere (Wagtail itself exits 0 and
# records FAILED in its SQLite log, which would otherwise pass silently).
#
# The env listing either side of the run is the guard that both conda
# environments really were reused from /opt/wagtail-envs: if Snakemake's env
# hash ever stops matching what the build created, it silently solves and
# installs a new environment here, and `diff` fails the build instead of every
# pod paying for (and needing network access for) a QIIME2 install.
RUN ls /opt/wagtail-envs > /tmp/envs.before \
    && wagtail-sra --db-cache /smoke-db --amplicon 16S --strict \
        --outdir /tmp/smoke ERR1519989 \
    && ls /opt/wagtail-envs > /tmp/envs.after \
    && diff /tmp/envs.before /tmp/envs.after \
    && head -3 /tmp/smoke/condensed/ERR1519989_condensed.tsv \
    && test "$(wc -l < /tmp/smoke/condensed/ERR1519989_condensed.tsv)" -gt 1 \
    && test -s /tmp/smoke/metadata/ERR1519989_metadata.tsv

# Reference-compressed (cSRA) read path. Runs submitted as aligned CRAM/BAM store
# READ bases relative to a reference genome that ncbi-vdb must fetch remotely to
# reconstruct the reads. Without the vdb config baked into the runtime image (the
# `COPY vdb-settings.kfg` above), that fetch never happens: reading dies on the
# first row with "row 1: reading READ failed" and sracat-rs emits nothing, so the
# accession would silently produce an empty FASTQ - exactly how ERR12086224 and
# other cSRA runs failed in production while plain runs succeeded. ERR12909594 is
# a tiny (~200 KB .sra) member of PRJEB44545, aligned to a small bacterial
# reference (FM211187.1 ~3 Mb), so this exercises remote reference resolution end
# to end for a trivial download. It is not run through Wagtail (it is not an
# amplicon run); extraction yielding reads is the property under test.
RUN cd /tmp && kingfisher get -r ERR12909594 -m aws-http \
        --output-format-possibilities sra --guess-aws-location --hide-download-progress \
    && sracat-rs --qual -1 /tmp/csra_1.fastq -2 /dev/null \
        --single-out /tmp/csra_single.fastq /tmp/ERR12909594.sra \
    && test -s /tmp/csra_1.fastq -o -s /tmp/csra_single.fastq \
    && rm -f /tmp/ERR12909594.sra /tmp/csra_*.fastq \
    && touch /smoke-ok

# ------------------------------------------------------------------ final image
FROM runtime
COPY --from=smoketest /smoke-ok /smoke-ok
