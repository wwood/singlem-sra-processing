FROM python:3.11

RUN useradd sandpiper -d /sandpiper \
 && mkdir /sandpiper \
 && chown sandpiper:sandpiper /sandpiper

WORKDIR /sandpiper
USER sandpiper
ENV PATH="/sandpiper/.local/bin:${PATH}"

# RUN pip install --user --no-cache-dir \


# This dockerfile uses cached mounts, so to build use e.g.
# singlem-wdl-local/dockers/singlem$ DOCKER_BUILDKIT=1 docker build .

# RUN apt install python3-pip -y
# RUN apk add --no-cache python3 py3-pip bash git curl

# RUN apk install cargo
# RUN pip install polars

# RUN pip3 install --no-dependencies kingfisher graftm

# # Don't need all of the dependencies of singlem, because only pipe is going to be run.
# COPY --chown=$MAMBA_USER:$MAMBA_USER env.yaml /tmp/env.yaml
# RUN micromamba install -y -n base -f /tmp/env.yaml && \
#     micromamba clean --all --yes

# # (otherwise python will not be found)
# ARG MAMBA_DOCKERFILE_ACTIVATE=1

# # NOTE: The following 2 hashes should be changed in sync.
# ENV SINGLEM_COMMIT 730b4e57
# ENV SINGLEM_VERSION 0.16.0-dev3
# RUN rm -rf singlem && git init singlem && cd singlem && git remote add origin https://github.com/wwood/singlem && git fetch origin && git checkout $SINGLEM_COMMIT
# # git clone https://github.com/wwood/singlem && cd singlem && git checkout 730b4e57
# RUN echo '__version__ = "'$SINGLEM_VERSION.${SINGLEM_COMMIT}'"' >singlem/singlem/version.py

# # Remove bundled singlem packages
# RUN rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

# # Install sra-tools from source so it is more likely to work
# # RUN curl -o a.tar.gz https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/2.11.3/sratoolkit.2.11.3-centos_linux64.tar.gz
# # RUN tar xf a.tar.gz
# # RUN rm a.tar.gz
# # RUN ln -s `pwd`/sratoolkit.2.11.3-centos_linux64/bin/prefetch /opt/conda/bin/ -v
# # RUN mkdir /home/micromamba/.ncbi
# # ADD user-settings.mkfg /home/micromamba/.ncbi/

# COPY --chown=$MAMBA_USER:$MAMBA_USER plastic3_and_S3.2.1.slimmed.smpkg /mpkg

# RUN pip install --no-dependencies kingfisher graftm

# # Diamond - go via direct because conda-forge version is likely slower on
# # account of not being compiled appropriately
# RUN cd /tmp && curl -L 'https://github.com/bbuchfink/diamond/releases/download/v2.1.8/diamond-linux64.tar.gz' -O 
# RUN cd /tmp && \
#     tar xf diamond-linux64.tar.gz && \
#     cp diamond /opt/conda/bin/ && \
#     rm diamond-linux64.tar.gz diamond

# # Effectively add singlem to the PATH
# RUN ln -s /tmp/singlem/bin/singlem /opt/conda/bin/singlem

# # Test it out
# COPY --chown=$MAMBA_USER:$MAMBA_USER SRR8653040.sra /tmp/
# RUN singlem pipe --sra-files /tmp/SRR8653040.sra --no-assign-taxonomy --metapackage /mpkg --archive-otu-table /tmp/a.json --threads 4
# RUN rm /tmp/SRR8653040.sra

# DEBUG
# COPY --chown=$MAMBA_USER:$MAMBA_USER singlem_an_sra.py /tmp/singlem/extras/

# CMD /bin/bash
