# arm64
FROM ubuntu:24.04

RUN apt-get update 
RUN apt-get install -y git python3 python3-pip

# Compile diamond from source for speed
RUN apt-get install -y cmake g++ make wget libpthread-stubs0-dev zlib1g-dev
RUN cd /tmp && wget http://github.com/bbuchfink/diamond/archive/v2.1.9.tar.gz
RUN cd /tmp && tar xzf v2.1.9.tar.gz
RUN cd /tmp/diamond-2.1.9 && mkdir bin
RUN cd /tmp/diamond-2.1.9/bin && cmake .. && make -j4
RUN cd /tmp/diamond-2.1.9/bin && cp diamond /usr/local/bin/
RUN rm -rf /tmp/diamond-2.1.9 /tmp/v2.1.9.tar.gz

# OrfM
RUN cd /tmp && wget https://github.com/wwood/OrfM/releases/download/v0.7.1/orfm-0.7.1.tar.gz
RUN cd /tmp && tar xzf orfm-0.7.1.tar.gz
RUN cd /tmp/orfm-0.7.1 && ./configure && make && cp orfm /usr/local/bin/
RUN rm -rf /tmp/orfm-0.7.1 /tmp/orfm-0.7.1.tar.gz

# hmmer
RUN cd /tmp && wget http://eddylab.org/software/hmmer/hmmer-3.4.tar.gz
RUN cd /tmp && tar xzf hmmer-3.4.tar.gz
RUN cd /tmp/hmmer-3.4 && ./configure && make
#make check && make install
RUN cd /tmp/hmmer-3.4 && make check && make install
RUN rm -rf /tmp/hmmer-3.4 /tmp/hmmer-3.4.tar.gz

# install further deps
RUN apt-get install -y python3-numpy python3-pandas
RUN pip install --no-dependencies --break-system-packages bird_tool_utils argparse-manpage-birdtools extern zenodo_backpack
RUN apt-get install -y python3-requests
RUN apt-get install -y python3-tqdm
# RUN apt-get install -y python3-biopython # Brings kitchen sink, maybe not available on ARM?
RUN pip install --no-dependencies --break-system-packages biopython
RUN apt-get install -y python3-sqlalchemy
# above, the symlink that is created is wrong. But we can just use the pypi version anyway.
RUN pip install --no-dependencies --break-system-packages kingfisher
RUN pip install --no-dependencies --break-system-packages graftm

## fasterq-dump --fasta-unsorted seems to give strange read names, which are non-unique so break singlem, so we install sracat from mamba
# RUN fasterq-dump --fasta-unsorted --stdout --split-files --seq-defline '>$ac.$si.$ri' /tmp/SRR8653040.sra > /tmp/SRR8653040.fasta
# RUN head /tmp/SRR8653040.fasta && fail
# RUN /singlem/bin/singlem pipe --forward /tmp/SRR8653040.fasta --no-assign-taxonomy --metapackage /mpkg --archive-otu-table /tmp/a.json --threads 4
RUN apt-get install -y curl
RUN curl -L micro.mamba.pm/install.sh |bash
# >>> mamba initialize >>>
# !! Contents within this block are managed by 'mamba init' !!
# export MAMBA_EXE='/root/.local/bin/micromamba';
# export MAMBA_ROOT_PREFIX='/root/micromamba';
# __mamba_setup="$("$MAMBA_EXE" shell hook --shell bash --root-prefix "$MAMBA_ROOT_PREFIX" 2> /dev/null)"
# if [ $? -eq 0 ]; then
#     eval "$__mamba_setup"
# else
#     alias micromamba="$MAMBA_EXE"  # Fallback on help from mamba activate
# fi
# unset __mamba_setup
# # <<< mamba initialize <<<
ENV MAMBA_EXE '/root/.local/bin/micromamba'
ENV MAMBA_ROOT_PREFIX '/root/micromamba'
# RUN ln -s /root/.local/bin/micromamba /usr/local/bin/micromamba
RUN bash -c '/root/.local/bin/micromamba create -y -c bioconda -p /conda_env sracat'
RUN ln -s /conda_env/bin/sracat /usr/local/bin/sracat

# singlem dependencies and data
COPY plastic3_and_S3.2.1.slimmed.smpkg /mpkg

# NOTE: The following 2 hashes should be changed in sync.
ENV SINGLEM_COMMIT 43c58769
ENV SINGLEM_VERSION 0.17.0-dev1
RUN rm -rf singlem && git init singlem && cd singlem && git remote add origin https://github.com/wwood/singlem && git fetch origin && git checkout $SINGLEM_COMMIT
RUN echo '__version__ = "'$SINGLEM_VERSION.${SINGLEM_COMMIT}'"' >singlem/singlem/version.py
RUN ln -s /singlem/bin/singlem /usr/local/bin/singlem

# Remove bundled singlem packages
RUN rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

COPY SRR8653040.sra /tmp/
RUN /singlem/bin/singlem pipe --sra-files /tmp/SRR8653040.sra --no-assign-taxonomy --metapackage /mpkg --archive-otu-table /tmp/a.json --threads 4

RUN rm /tmp/SRR8653040.sra /tmp/a.json

# Clean apt-get files to try to make it smaller
RUN rm -rf /var/lib/apt/lists/*
RUN apt-get clean

# Attempt to reduce image size
FROM scratch
COPY --from=0 / /