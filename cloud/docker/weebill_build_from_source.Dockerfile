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
    && mkdir -p /etc/ncbi \
    && printf '/LIBS/IMAGE_GUID = "%s"\n' `uuidgen` > /etc/ncbi/settings.kfg \
    && printf '/libs/cloud/report_instance_identity = "true"\n' >> /etc/ncbi/settings.kfg \
    && rm -rf /var/lib/apt/lists/* /root/.cache \
    && apt-get clean

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
    ls -lh /tmp/SRR8653040.sylspc' \
    && touch /smoke-ok

# ------------------------------------------------------------------ final image
FROM runtime
COPY --from=smoketest /smoke-ok /smoke-ok
