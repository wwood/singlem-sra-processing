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
# Build:
#   docker build -f weebill_build_from_source.Dockerfile . -t woodcrob/weebill
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git \
    python3 \
    python3-pip \
    build-essential \
    curl \
    cmake \
    gcc \
    make \
    wget \
    unzip

# Rust
RUN curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | bash -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Both weebill and sracat-rs are compiled with `-C target-cpu=native`. This image
# is built on a worker node of the SAME instance type it runs on (see the
# cloud/argo nodegroup templates, c7a.*), so native codegen targets the exact CPU
# and is faster; it would only be unsafe if the image ran on an older CPU.

# weebill is developed as a branch of the sylph fork at github.com/wwood/sylph;
# it builds a binary named `weebill` and provides `weebill sketch --merge`, which
# this workflow depends on. NOTE: `main` (both bluenote-1577/sylph and the
# wwood/weebill mirror) does NOT have `sketch --merge`, so pin the commit on the
# add-merge-single-paired branch that does. (Mirrors sylph_build_from_source
# .Dockerfile, which likewise builds from a wwood/sylph feature branch.)
ENV WEEBILL_COMMIT c7f780947c762aebf82245557578ce9ff0ca413b
RUN git clone https://github.com/wwood/sylph /tmp/weebill \
    && cd /tmp/weebill \
    && git checkout ${WEEBILL_COMMIT} \
    && RUSTFLAGS="-C target-cpu=native" cargo install --path . --root /usr/local \
    && rm -rf /tmp/weebill /root/.cargo/registry /root/.cargo/git
RUN weebill --help
# Fail the build early if this ref lacks `sketch --merge` (the workflow needs it).
RUN weebill sketch --help | grep -q -- --merge

# sracat-rs - built from source (not the prebuilt release) so it too gets
# `-C target-cpu=native`. It links ncbi-vdb, a conda-provided C library, so the
# build runs inside the pixi env declared in the sracat-rs repo (which supplies
# ncbi-vdb, a C/C++ compiler and zlib); build.rs needs CONDA_PREFIX, which
# `pixi run` sets. SRACAT_VDB_LINK=static links libncbi-vdb.a so the binary is
# self-contained and relocatable (no libncbi-vdb.so dependency, no conda rpath):
# we copy just the binary onto the system PATH and discard the pixi env.
RUN curl -fsSL https://pixi.sh/install.sh | bash
ENV PATH="/root/.pixi/bin:${PATH}"
ENV SRACAT_RS_COMMIT main
RUN git clone https://github.com/wwood/sracat-rs /tmp/sracat-rs \
    && cd /tmp/sracat-rs \
    && git checkout ${SRACAT_RS_COMMIT} \
    && pixi run -- env SRACAT_VDB_LINK=static RUSTFLAGS="-C target-cpu=native" \
         cargo install --path . --root /usr/local \
    && rm -rf /tmp/sracat-rs /root/.cache/rattler
RUN sracat-rs --help

# NCBI VDB config (cloud location reporting) - harmless for local .sra reads,
# useful if a tool ever resolves an accession directly.
RUN apt-get install -y uuid-runtime \
    && mkdir -p /etc/ncbi \
    && printf '/LIBS/IMAGE_GUID = "%s"\n' `uuidgen` > /etc/ncbi/settings.kfg \
    && printf '/libs/cloud/report_instance_identity = "true"\n' >> /etc/ncbi/settings.kfg

# kingfisher (SRA/ENA downloader) and its runtime deps. kingfisher is installed
# with --no-dependencies, so its imports (incl. pandas, imported at startup) must
# be provided here explicitly, otherwise `kingfisher get` fails with ModuleNotFoundError.
RUN apt-get install -y python3-requests python3-tqdm python3-pandas python3-numpy aria2 pigz
RUN pip install --no-dependencies --break-system-packages \
    bird_tool_utils argparse-manpage-birdtools extern
RUN pip install --no-dependencies --break-system-packages kingfisher

# AWS CLI (kingfisher aws-http/aws-cp download and, in the workflow, artifact upload)
RUN cd /tmp && wget "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Smoke test: exercise the exact download -> sracat-rs -> weebill FIFO pipeline
# used by the workflow, so a broken image fails the build rather than the queue.
# The pipeline runs inside `bash -c` so that `&` backgrounds ONLY sracat-rs (the
# single writer) while weebill reads both FIFOs in the foreground.
RUN cd /tmp && kingfisher get -r SRR8653040 -m aws-http -f sra --guess-aws-location --hide-download-progress
RUN cd /tmp && bash -e -o pipefail -c '\
    mkfifo pairs.fifo singles.fifo; \
    sracat-rs --single-out singles.fifo SRR8653040.sra > pairs.fifo & \
    weebill sketch --merge --interleaved pairs.fifo --reads singles.fifo -S SRR8653040 --compressed-database /tmp/SRR8653040 -t 4; \
    wait; \
    ls -lh /tmp/SRR8653040.sylspc' \
    && rm -f /tmp/SRR8653040* /tmp/pairs.fifo /tmp/singles.fifo

# Clean apt to shrink the image
RUN rm -rf /var/lib/apt/lists/* && apt-get clean

# Flatten to reduce image size
FROM scratch
COPY --from=0 / /
ENV PATH="/usr/local/bin:/root/.cargo/bin:/usr/bin:/bin"
