FROM mambaorg/micromamba:1.5.6
# We cannot use the -alpine3.19 version of microbamba because then diamond
# segfaults immediately.

### NOTES
#
# * Could not use the alpine image to work, becuase it doesn't include glibc.
# * Use multi-stage build to reduce image size (though this requires re-adding some micromamba stuff - see https://micromamba-docker.readthedocs.io/en/latest/advanced_usage.html#adding-micromamba-to-an-existing-docker-image)
# * Using the ubuntu image was annoying and no conda was annoying because e.g. installing sracat is likely a pain from source

# This dockerfile uses cached mounts, so to build use e.g.
# singlem-wdl-local/dockers/singlem$ DOCKER_BUILDKIT=1 docker build .

ARG MAMBA_USER=root
ARG MAMBA_USER_ID=0
ARG MAMBA_USER_GID=0
ENV MAMBA_USER=$MAMBA_USER
USER root
RUN echo root > "/etc/arg_mamba_user"

# Don't need all of the dependencies of singlem, because only pipe is going to be run.
COPY --chown=$MAMBA_USER:$MAMBA_USER env.yaml /tmp/env.yaml
RUN micromamba install -y -n base -f /tmp/env.yaml && \
    micromamba clean --all --yes

# (otherwise python will not be found)
ARG MAMBA_DOCKERFILE_ACTIVATE=1

# NOTE: The following 2 hashes should be changed in sync.
ENV SINGLEM_COMMIT b27c15b0
ENV SINGLEM_VERSION 0.16.0-dev4
RUN rm -rf singlem && git init singlem && cd singlem && git remote add origin https://github.com/wwood/singlem && git fetch origin && git checkout $SINGLEM_COMMIT
RUN echo '__version__ = "'$SINGLEM_VERSION.${SINGLEM_COMMIT}'"' >singlem/singlem/version.py

# Remove bundled singlem packages
RUN rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

# Install sra-tools from source so it is more likely to work
# RUN curl -o a.tar.gz https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/2.11.3/sratoolkit.2.11.3-centos_linux64.tar.gz
# RUN tar xf a.tar.gz
# RUN rm a.tar.gz
# RUN ln -s `pwd`/sratoolkit.2.11.3-centos_linux64/bin/prefetch /opt/conda/bin/ -v
# RUN mkdir /home/micromamba/.ncbi
# ADD user-settings.mkfg /home/micromamba/.ncbi/

COPY --chown=$MAMBA_USER:$MAMBA_USER plastic3_and_S3.2.1.slimmed.smpkg /mpkg

RUN pip install --no-dependencies graftm

# Install kingfisher via git because there are unreleased fixes
# NOTE: The following 2 hashes should be changed in sync.
ENV KINGFISHER_COMMIT 673d483
ENV KINGFISHER_VERSION 0.3.1-dev2
RUN rm -rf kingfisher && git init kingfisher && cd kingfisher && git remote add origin https://github.com/wwood/kingfisher-download && git fetch origin && git checkout $KINGFISHER_COMMIT
RUN echo '__version__ = "'$KINGFISHER_VERSION.${KINGFISHER_COMMIT}'"' >kingfisher/kingfisher/version.py
RUN cd kingfisher && rm -rf .git docker docs images test
RUN ln -s /tmp/kingfisher/bin/kingfisher /opt/conda/bin/kingfisher

# Diamond - go via direct because conda-forge version is likely slower on
# account of not being compiled appropriately. Also, the conda version installs
# BLAST, which takes up space and we don't need.
RUN cd /tmp && curl -L 'https://github.com/bbuchfink/diamond/releases/download/v2.1.8/diamond-linux64.tar.gz' -O 
RUN cd /tmp && \
    tar xf diamond-linux64.tar.gz && \
    cp diamond /opt/conda/bin/ && \
    rm diamond-linux64.tar.gz diamond

# # debugCOPY --from=0 / /
# COPY --chown=$MAMBA_USER:$MAMBA_USER singlem /tmp/singlem
# RUN cd /tmp && rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

# Effectively add singlem to the PATH
RUN ln -s /tmp/singlem/bin/singlem /opt/conda/bin/singlem

RUN micromamba remove git -y
RUN micromamba clean -afy

# Test it out
COPY --chown=$MAMBA_USER:$MAMBA_USER SRR8653040.sra /tmp/
RUN singlem pipe --sra-files /tmp/SRR8653040.sra --no-assign-taxonomy --metapackage /mpkg --archive-otu-table /tmp/a.json --threads 4
RUN rm /tmp/SRR8653040.sra /tmp/a.json

# DEBUG
# COPY --chown=$MAMBA_USER:$MAMBA_USER singlem_an_sra.py /tmp/singlem/extras/

# CMD /bin/bash

# Remove all the build dependencies / image layers for a smaller image overall
FROM scratch
COPY --from=0 / /

## The following is to add micromamba back into the image, from https://micromamba-docker.readthedocs.io/en/latest/advanced_usage.html#adding-micromamba-to-an-existing-docker-image

# # bring in the micromamba image so we can copy files from it
# FROM mambaorg/micromamba:1.5.6 as micromamba

# # This is the image we are going add micromaba to:
# FROM tomcat:9-jdk17-temurin-focal

USER root

# if your image defaults to a non-root user, then you may want to make the
# next 3 ARG commands match the values in your image. You can get the values
# by running: docker run --rm -it my/image id -a
# ARG MAMBA_USER=mambauser
# ARG MAMBA_USER_ID=57439
# ARG MAMBA_USER_GID=57439
## Make the default user root because otherwise there are permission issues in google batch
ARG MAMBA_USER=root
ARG MAMBA_USER_ID=0
ARG MAMBA_USER_GID=0
ENV MAMBA_USER=$MAMBA_USER
ENV MAMBA_ROOT_PREFIX="/opt/conda"
ENV MAMBA_EXE="/bin/micromamba"

# ## These below are not necessary because the copy from the micromamba image already has them, and doing it just adds to the the image size.
# COPY --from=micromamba "$MAMBA_EXE" "$MAMBA_EXE"
# COPY --from=micromamba /usr/local/bin/_activate_current_env.sh /usr/local/bin/_activate_current_env.sh
# COPY --from=micromamba /usr/local/bin/_dockerfile_shell.sh /usr/local/bin/_dockerfile_shell.sh
# COPY --from=micromamba /usr/local/bin/_entrypoint.sh /usr/local/bin/_entrypoint.sh
# COPY --from=micromamba /usr/local/bin/_dockerfile_initialize_user_accounts.sh /usr/local/bin/_dockerfile_initialize_user_accounts.sh
# COPY --from=micromamba /usr/local/bin/_dockerfile_setup_root_prefix.sh /usr/local/bin/_dockerfile_setup_root_prefix.sh

# RUN /usr/local/bin/_dockerfile_initialize_user_accounts.sh && \
#     /usr/local/bin/_dockerfile_setup_root_prefix.sh

USER $MAMBA_USER

SHELL ["/usr/local/bin/_dockerfile_shell.sh"]

ENTRYPOINT ["/usr/local/bin/_entrypoint.sh"]
# Optional: if you want to customize the ENTRYPOINT and have a conda
# environment activated, then do this:
# ENTRYPOINT ["/usr/local/bin/_entrypoint.sh", "my_entrypoint_program"]

# You can modify the CMD statement as needed....
CMD ["/bin/bash"]

# Optional: you can now populate a conda environment:
# RUN micromamba install --yes --name base --channel conda-forge \
#       jq && \
#     micromamba clean --all --yes

# ADD dust-v0.8.6-x86_64-unknown-linux-gnu/dust /usr/local/bin/
