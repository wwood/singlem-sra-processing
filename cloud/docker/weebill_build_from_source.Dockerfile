# Image for the multi-SRA-per-pod weebill workflow (sra_multi_workflow_template.yaml).
#
# Per accession the workflow does, with NO intermediate fastq on disk:
#   kingfisher get -> $A.sra
#   sracat-rs --single-out singles.fifo $A.sra > pairs.fifo   (one writer, two FIFOs)
#   weebill sketch --merge --interleaved pairs.fifo --reads singles.fifo
# sracat-rs streams interleaved pairs to one FIFO and single/orphan reads to the
# other; weebill's --merge sketches every raw input on its own thread (so both
# FIFOs are drained at once) and merges them into one sample sketch.
#
# Multi-stage: the Rust toolchain, the pixi/conda env that provides ncbi-vdb, and
# the C/C++ build tooling all stay in the builder stage. The runtime stage carries
# only the two statically-usable binaries plus kingfisher/aws-cli and their deps.
#
# Build:
#   docker build -f weebill_build_from_source.Dockerfile . -t woodcrob/weebill

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

# Both weebill and sracat-rs are compiled with `-C target-cpu=native`. This image
# is built on a worker node of the SAME instance type it runs on (see the
# cloud/argo nodegroup templates, c7a.*), so native codegen targets the exact CPU
# and is faster; it would only be unsafe if the image ran on an older CPU.
# `-C strip=symbols` drops debug symbols from the binaries (tens of MB each).
ENV RUSTFLAGS="-C target-cpu=native -C strip=symbols"

# weebill is developed as a branch of the sylph fork at github.com/wwood/sylph;
# it builds a binary named `weebill` and provides `weebill sketch --merge`, which
# this workflow depends on. NOTE: `main` (both bluenote-1577/sylph and the
# wwood/weebill mirror) does NOT have `sketch --merge`, so pin the commit on the
# add-merge-single-paired branch that does. (Mirrors sylph_build_from_source
# .Dockerfile, which likewise builds from a wwood/sylph feature branch.)
ENV WEEBILL_COMMIT f852ec5301625aac02a4719c8f9e7a10d3e8196c
RUN git clone https://github.com/wwood/sylph /tmp/weebill \
    && cd /tmp/weebill \
    && git checkout ${WEEBILL_COMMIT} \
    && cargo install --path . --root /usr/local

# sracat-rs - built from source (not the prebuilt release) so it too gets
# `-C target-cpu=native`. It links ncbi-vdb, a conda-provided C library, so the
# build runs inside the pixi env declared in the sracat-rs repo (which supplies
# ncbi-vdb, a C/C++ compiler and zlib); build.rs needs CONDA_PREFIX, which
# `pixi run` sets. SRACAT_VDB_LINK=static links libncbi-vdb.a so the binary is
# self-contained and relocatable (no libncbi-vdb.so dependency, no conda rpath):
# only the binary is copied into the runtime stage; the pixi env is discarded.
RUN curl -fsSL https://pixi.sh/install.sh | bash
ENV PATH="/root/.pixi/bin:${PATH}"
ENV SRACAT_RS_COMMIT v0.2.0
RUN git clone https://github.com/wwood/sracat-rs /tmp/sracat-rs \
    && cd /tmp/sracat-rs \
    && git checkout ${SRACAT_RS_COMMIT} \
    && pixi run -- env SRACAT_VDB_LINK=static cargo install --path . --root /usr/local

# The runtime stage has none of the conda/pixi libraries, so fail here if either
# binary still needs one: every resolved DSO must come from the base system.
RUN for b in /usr/local/bin/weebill /usr/local/bin/sracat-rs; do \
      ldd $b; \
      ldd $b | grep -E '=> */(root|opt)/' && { echo "$b links a build-env library"; exit 1; }; \
    done; true

# AWS CLI (kingfisher aws-http/aws-cp download and, in the workflow, artifact
# upload). Unpacked here so the runtime stage needs neither wget nor unzip.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && cd /tmp && unzip -q awscliv2.zip \
    && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ---------------------------------------------------------------- runtime stage
FROM ubuntu:24.04 AS runtime

# kingfisher (SRA/ENA downloader) and its runtime deps. kingfisher is installed
# with --no-dependencies, so its imports (incl. pandas, imported at startup) must
# be provided here explicitly, otherwise `kingfisher get` fails with ModuleNotFoundError.
# python3-pip is removed again after use; the packages it installs are pure python.
#
# NCBI VDB config (cloud location reporting) - harmless for local .sra reads,
# useful if a tool ever resolves an accession directly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-requests \
        python3-tqdm \
        python3-pandas \
        python3-numpy \
        aria2 \
        pigz \
        curl \
        uuid-runtime \
    && apt-get install -y --no-install-recommends python3-pip \
    && pip install --no-cache-dir --no-dependencies --break-system-packages \
        bird_tool_utils argparse-manpage-birdtools extern kingfisher \
    && apt-get purge -y python3-pip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /root/.cache \
    && apt-get clean

# ncbi-vdb configuration so sracat-rs can read reference-compressed (cSRA) runs -
# those submitted as aligned CRAM/BAM, whose READ bases are stored as differences
# against a reference genome. Reading them requires fetching the REFSEQ objects
# from NCBI into a writable cache; without this config that fetch never happens
# and the read dies on the first row with "row 1: reading READ failed", so
# sracat-rs emits nothing and weebill reports "No reads were sketched". See
# vdb-settings.kfg for the full rationale. The reference cache is POD-LOCAL
# (/root/ncbi/public on ephemeral disk, per vdb-settings.kfg), created here so
# the first read can write into it. IMAGE_GUID is a per-image identifier appended
# at build time (kept out of the committed file so each build is unique).
COPY vdb-settings.kfg /etc/ncbi/settings.kfg
RUN printf '/LIBS/IMAGE_GUID = "%s"\n' "$(uuidgen)" >> /etc/ncbi/settings.kfg \
    && mkdir -p /root/ncbi/public

COPY --from=builder /usr/local/bin/weebill /usr/local/bin/weebill
COPY --from=builder /usr/local/bin/sracat-rs /usr/local/bin/sracat-rs
# The aws-cli install dir is copied wholesale (symlinks inside it are preserved),
# but /usr/local/bin/aws must be re-made here rather than COPYed: it is a symlink,
# and COPY dereferences a symlink given as its source, which would put the
# PyInstaller executable itself in /usr/local/bin, away from its bundled libpython.
COPY --from=builder /usr/local/aws-cli /usr/local/aws-cli
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws

# ------------------------------------------------------------------ smoke tests
# Exercise the exact download -> sracat-rs -> weebill FIFO pipeline used by the
# workflow, so a broken image fails the build rather than the queue. This runs in
# a throwaway stage on top of the runtime image: the test's downloads and layers
# are never part of the shipped image, but the final stage COPYs from it, so the
# test must pass for the build to succeed.
FROM runtime AS smoketest
RUN weebill --help
# Fail the build early if this ref lacks `sketch --merge` (the workflow needs it).
RUN weebill sketch --help | grep -q -- --merge
RUN sracat-rs --help
RUN aws --version
# The pipeline runs inside `bash -c` so that `&` backgrounds ONLY sracat-rs (the
# single writer) while weebill reads both FIFOs in the foreground.
RUN cd /tmp && kingfisher get -r SRR8653040 -m aws-http -f sra --guess-aws-location --hide-download-progress
RUN cd /tmp && bash -e -o pipefail -c '\
    mkfifo pairs.fifo singles.fifo; \
    sracat-rs --eager-open-output --single-out singles.fifo SRR8653040.sra > pairs.fifo & \
    weebill sketch --merge --tolerate-empty-inputs --interleaved pairs.fifo --reads singles.fifo -S SRR8653040 --compressed-database /tmp/SRR8653040 -t 1; \
    wait; \
    ls -lh /tmp/SRR8653040.sylspc'

# Reference-compressed (cSRA) read path. Runs submitted as aligned CRAM/BAM store
# READ bases relative to a reference genome that ncbi-vdb must fetch remotely to
# reconstruct the reads. Without the vdb config baked into the runtime image (the
# `COPY vdb-settings.kfg` above), that fetch never happens: reading dies on the
# first row with "row 1: reading READ failed", sracat-rs emits nothing, and
# weebill exits non-zero with "No reads were sketched" - exactly how ERR12086224
# and other cSRA runs failed in production while plain runs succeeded. ERR12909594
# is a tiny (~200 KB .sra) member of the same study (PRJEB44545), aligned to a
# small bacterial reference (FM211187.1 ~3 Mb), so this exercises remote reference
# resolution end to end for a trivial download. It MUST yield a sketch; if the vdb
# config ever regresses, weebill exits non-zero here and the build fails instead
# of the failure only surfacing on the queue.
RUN cd /tmp && kingfisher get -r ERR12909594 -m aws-http -f sra --guess-aws-location --hide-download-progress
RUN cd /tmp && bash -e -o pipefail -c '\
    mkfifo cpairs.fifo csingles.fifo; \
    sracat-rs --eager-open-output --single-out csingles.fifo ERR12909594.sra > cpairs.fifo & \
    weebill sketch --merge --tolerate-empty-inputs --interleaved cpairs.fifo --reads csingles.fifo -S ERR12909594 --compressed-database /tmp/ERR12909594 -t 1; \
    wait; \
    ls -lh /tmp/ERR12909594.sylspc' \
    && touch /smoke-ok

# ------------------------------------------------------------------ final image
FROM runtime
COPY --from=smoketest /smoke-ok /smoke-ok
