FROM ubuntu:24.04

RUN apt-get update 
RUN apt-get install -y git \
    python3 \
    python3-pip

RUN apt-get install -y \
    build-essential \
    curl

# Update new packages
RUN apt-get update

# Rust
RUN curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | bash -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN apt-get install -y cmake gcc make wget

# Sylph
RUN git clone --depth 1 --branch add-merge-subcommand https://github.com/wwood/sylph /tmp/sylph
RUN cd /tmp/sylph && cargo install --path . --root ~/.cargo
RUN sylph profile /tmp/sylph/test_files/*

# # Compile diamond from source for speed
# RUN apt-get install -y cmake g++ make wget libpthread-stubs0-dev zlib1g-dev
# # 2.1.11 is newest. Seems to have issues with some fastq files, but singlem always pipes in fasta so should be fine? Doesn't appear to be fine in practice, so downgrading.
# ENV DIAMOND_VERSION 2.1.10
# RUN cd /tmp && wget http://github.com/bbuchfink/diamond/archive/v$DIAMOND_VERSION.tar.gz
# RUN cd /tmp && tar xzf v$DIAMOND_VERSION.tar.gz
# RUN cd /tmp/diamond-$DIAMOND_VERSION && mkdir bin
# RUN cd /tmp/diamond-$DIAMOND_VERSION/bin && cmake .. && make -j4
# RUN cd /tmp/diamond-$DIAMOND_VERSION/bin && cp diamond /usr/local/bin/
# RUN rm -rf /tmp/diamond-$DIAMOND_VERSION /tmp/v$DIAMOND_VERSION.tar.gz

# # OrfM
# RUN cd /tmp && wget https://github.com/wwood/OrfM/releases/download/v0.7.1/orfm-0.7.1.tar.gz
# RUN cd /tmp && tar xzf orfm-0.7.1.tar.gz
# RUN cd /tmp/orfm-0.7.1 && ./configure && make && cp orfm /usr/local/bin/
# RUN rm -rf /tmp/orfm-0.7.1 /tmp/orfm-0.7.1.tar.gz

# # hmmer
# RUN cd /tmp && wget http://eddylab.org/software/hmmer/hmmer-3.4.tar.gz
# RUN cd /tmp && tar xzf hmmer-3.4.tar.gz
# RUN cd /tmp/hmmer-3.4 && ./configure && make
# #make check && make install
# RUN cd /tmp/hmmer-3.4 && make check && make install
# RUN rm -rf /tmp/hmmer-3.4 /tmp/hmmer-3.4.tar.gz

# # install further deps
RUN apt-get install -y python3-numpy python3-pandas
RUN pip install --no-dependencies --break-system-packages bird_tool_utils argparse-manpage-birdtools extern zenodo_backpack
RUN apt-get install -y python3-requests
RUN apt-get install -y python3-tqdm
# RUN apt-get install -y python3-biopython # Brings kitchen sink, maybe not available on ARM?
# RUN pip install --no-dependencies --break-system-packages biopython
# RUN apt-get install -y python3-sqlalchemy
# # above, the symlink that is created is wrong. But we can just use the pypi version anyway.
RUN pip install --no-dependencies --break-system-packages kingfisher
# RUN pip install --no-dependencies --break-system-packages graftm

RUN cd /tmp && wget https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/3.2.0/setup-apt.sh
RUN cd /tmp && bash setup-apt.sh
# RUN ls -l /tmp/sratoolkit.3.2.0-ubuntu64/bin && fail
# what do these next to do?
RUN mkdir -p /etc/ncbi
RUN printf '/LIBS/IMAGE_GUID = "%s"\n' `uuidgen` > /etc/ncbi/settings.kfg && \
    printf '/libs/cloud/report_instance_identity = "true"\n' >> /etc/ncbi/settings.kfg
    
WORKDIR /

# Get sracat. Bit of a hack here but gets it done.
RUN cd /tmp && git clone --depth 1 https://github.com/lanl/sracat
RUN cd /tmp/sracat && cp Makefile Makefile.orig
RUN cd /tmp && wget https://ftp-trace.ncbi.nlm.nih.gov/sra/ngs/3.2.0/ngs-sdk.3.2.0-linux.tar.gz && tar xzf ngs-sdk.3.2.0-linux.tar.gz
RUN cp -r /tmp/ngs-sdk.3.2.0-linux/lib64/* /usr/lib/
RUN cd /tmp/sracat && sed 's= SRA= /tmp/ngs-sdk.3.2.0-linux=' Makefile.orig |sed 's/-lncbi-vdb-static//' > Makefile && make
RUN cd /tmp/sracat && cp sracat /usr/local/bin/
RUN sracat -h
RUN rm -rf /tmp/sracat

# # singlem dependencies and data
# COPY plastic3_and_S4.3.0.slimmed.smpkg /mpkg

# # NOTE: The following 2 hashes should be changed in sync. Note that the version must comply with PEP440 otherwise pip will not install it below (but now we aren't using pip?).
# ENV SINGLEM_COMMIT 2a3f1f1b
# ENV SINGLEM_VERSION 0.18.3.post3
# RUN rm -rf singlem && git init singlem && cd singlem && git remote add origin https://github.com/wwood/singlem && git fetch origin && git checkout $SINGLEM_COMMIT
# # __version__ = {"singlem": "0.18.3", "lyrebird": "0.2.0"}
# RUN echo '__version__ = {"singlem": "'$SINGLEM_VERSION.${SINGLEM_COMMIT}'"}' >singlem/singlem/version.py
# RUN ln -s /singlem/bin/singlem /usr/local/bin/singlem

# # Remove bundled singlem packages
# RUN rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

# AWS cli
RUN apt install -y unzip
RUN cd /tmp && wget "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip" && unzip awscliv2.zip && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && rm -rf /tmp/awscliv2.zip /tmp/aws
RUN cd /tmp && kingfisher get -r SRR8653040 -m aws-cp -f sra --guess-aws-location

# Check ENA downloading works
RUN apt install -y curl aria2 pigz
# extern.run(f'kingfisher get -r {run} --output-format-possibilities fastq.gz --hide-download-progress -m ena-ftp')
RUN cd /tmp && kingfisher get -r SRR8653040 -m ena-ftp -f fastq.gz --hide-download-progress

# sra-tools incl. fasterq-dump
RUN cd /tmp && wget --output-document sratoolkit.tar.gz https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/3.3.0/sratoolkit.3.3.0-ubuntu64.tar.gz
RUN cd /tmp && tar xzf sratoolkit.tar.gz
RUN mv /tmp/sratoolkit.3.3.0-ubuntu64/ .
ENV PATH="/sratoolkit.3.3.0-ubuntu64/bin:${PATH}"
RUN which fastq-dump
RUN rm /tmp/sratoolkit.tar.gz

# # RUN apt remove python3-tqdm -y
# # RUN cd singlem && pip install -e . --break-system-packages
RUN mkfifo /tmp/SRR8653040_interleaved.fasta && \
    (kingfisher extract --sra /tmp/SRR8653040.sra -t 8 -f fasta --unsorted --stdout >/tmp/SRR8653040_interleaved.fasta &) && \
    sylph sketch --interleaved /tmp/SRR8653040_interleaved.fasta -t 50 -d /tmp && \
    wait && \
    rm /tmp/SRR8653040.sra /tmp/SRR8653040_interleaved.fasta

# Clean apt-get files to try to make it smaller
RUN rm -rf /var/lib/apt/lists/*
RUN apt-get clean

# Look for space savings. There are some things e.g. AWS bundles python, and gcc
# probably isn't needed any more, but not worth the effort of debugging

# COPY dust-v0.8.6-x86_64-unknown-linux-gnu/dust /usr/local/bin/dust
# RUN chmod +x /usr/local/bin/dust
# RUN dust -n 60 / && fail

# Attempt to reduce image size
FROM scratch
COPY --from=0 / /
