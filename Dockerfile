ARG CUDA_VERSION=12.8.1
ARG BASE_IMAGE=nvcr.io/nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu24.04

FROM ${BASE_IMAGE} AS base

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Zurich

# Install some essential packages
RUN apt-get -qq update && \
    apt-get -qq install -y \
    apt-utils \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    fd-find \
    fzf \
    gettext \
    git \
    g++ \
    htop \
    jq \
    less \
    libtool \
    libtool-bin \
    luarocks \
    ninja-build \
    nodejs \
    npm \
    nvtop \
    openssh-client \
    ripgrep \
    software-properties-common \
    sudo \
    tmux \
    tree \
    tzdata \
    unzip \
    vim \
    wget \
    xclip \
    zip \
    zsh \
    stow \
    && rm -rf /var/lib/apt/lists/*


# From Coreweave
RUN apt-get -qq update && \
    apt-get -qq install -y \
        --allow-change-held-packages \
        --no-install-recommends \
        --allow-downgrades \
        build-essential libtool autoconf automake autotools-dev unzip \
        ca-certificates \
        wget curl openssh-server vim environment-modules \
        iputils-ping net-tools \
        libnuma1 libsubunit0 libpci-dev \
        libpmix-dev \
        datacenter-gpu-manager \
        git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Mellanox OFED (latest)
RUN wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | apt-key add -
RUN cd /etc/apt/sources.list.d/ && wget https://linux.mellanox.com/public/repo/mlnx_ofed/latest/ubuntu24.04/mellanox_mlnx_ofed.list

RUN apt-get -qq update \
    && apt-get -qq install -y --no-install-recommends \
    ibverbs-utils libibverbs-dev libibumad3 libibumad-dev librdmacm-dev rdmacm-utils infiniband-diags ibverbs-utils \
    && rm -rf /var/lib/apt/lists/*
#         mlnx-ofed-hpc-user-only


FROM base AS builder-base
RUN apt-get -qq update && \
    apt-get -qq install -y --no-install-recommends \
      build-essential devscripts debhelper fakeroot pkg-config check && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*


FROM builder-base AS hpcx
# HPC-X
# grep + sed is used as a workaround to update hardcoded pkg-config / libtools archive / CMake prefixes
ARG HPCX_DISTRIBUTION="hpcx-v2.23-gcc-doca_ofed-ubuntu24.04-cuda12"
RUN cd /tmp && \
    DIST_NAME="${HPCX_DISTRIBUTION}-$(uname -m)" && \
    HPCX_DIR="/opt/hpcx" && \
    wget -q -O - "https://storage.googleapis.com/kev-blobs/${DIST_NAME}.tbz" | tar xjf - && \
    grep -IrlF "/build-result/${DIST_NAME}" "${DIST_NAME}" | xargs -rd'\n' sed -i -e "s:/build-result/${DIST_NAME}:${HPCX_DIR}:g" && \
    mv "${DIST_NAME}" "${HPCX_DIR}" && \
    rm -r /opt/hpcx/ompi


FROM base AS final
COPY --link --from=hpcx /opt/hpcx /opt/hpcx

RUN ldconfig

# HPC-X Environment variables
COPY ./printpaths.sh /tmp
SHELL ["/bin/bash", "-c"]
RUN source /opt/hpcx/hpcx-init.sh && \
    hpcx_load && \
    # Uncomment to stop a run early with the ENV definitions for the below section
    # /tmp/printpaths.sh ENV && false && \
    # Preserve environment variables in new login shells \
    alias install='install --owner=0 --group=0' && \
    /tmp/printpaths.sh export \
      | install --mode=644 /dev/stdin /etc/profile.d/hpcx-env.sh && \
    # Preserve environment variables (except *PATH*) when sudoing
    install -d --mode=0755 /etc/sudoers.d && \
    /tmp/printpaths.sh \
      | sed -E -e '{ \
          # Convert NAME=value to just NAME \
          s:^([^=]+)=.*$:\1:g ; \
          # Filter out any variables with PATH in their names \
          /PATH/d ; \
          # Format them into /etc/sudoers env_keep directives \
          s:^.*$:Defaults env_keep += "\0":g \
        }' \
      | install --mode=440 /dev/stdin /etc/sudoers.d/hpcx-env && \
    # Register shared libraries with ld regardless of LD_LIBRARY_PATH
    echo $LD_LIBRARY_PATH | tr ':' '\n' \
      | install --mode=644 /dev/stdin /etc/ld.so.conf.d/hpcx.conf && \
    rm /tmp/printpaths.sh
SHELL ["/bin/sh", "-c"]

# The following envs are from the output of the printpaths ENV script.
# Uncomment "/tmp/printpaths.sh ENV" above to run the script
# as part of a Docker build. Copy-paste the updated output in here.
# These ENVs need to be updated on new HPC-X install, different base image
# or any path related modifications before this stage in the Dockerfile.

# Begin auto-generated paths
ENV HPCX_DIR=/opt/hpcx
ENV HPCX_UCX_DIR=/opt/hpcx/ucx
ENV HPCX_UCC_DIR=/opt/hpcx/ucc
ENV HPCX_SHARP_DIR=/opt/hpcx/sharp
ENV HPCX_NCCL_RDMA_SHARP_PLUGIN_DIR=/opt/hpcx/nccl_rdma_sharp_plugin
ENV HPCX_HCOLL_DIR=/opt/hpcx/hcoll
ENV HPCX_MPI_DIR=/opt/hpcx/ompi
ENV HPCX_OSHMEM_DIR=/opt/hpcx/ompi
ENV HPCX_MPI_TESTS_DIR=/opt/hpcx/ompi/tests
ENV HPCX_OSU_DIR=/opt/hpcx/ompi/tests/osu-micro-benchmarks
ENV HPCX_OSU_CUDA_DIR=/opt/hpcx/ompi/tests/osu-micro-benchmarks-cuda
ENV HPCX_IPM_DIR=""
ENV HPCX_CLUSTERKIT_DIR=/opt/hpcx/clusterkit
ENV OMPI_HOME=/opt/hpcx/ompi
ENV MPI_HOME=/opt/hpcx/ompi
ENV OSHMEM_HOME=/opt/hpcx/ompi
ENV OPAL_PREFIX=/opt/hpcx/ompi
ENV OLD_PATH=/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PATH=/opt/hpcx/sharp/bin:/opt/hpcx/clusterkit/bin:/opt/hpcx/hcoll/bin:/opt/hpcx/ucc/bin:/opt/hpcx/ucx/bin:/opt/hpcx/ompi/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV OLD_LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV LD_LIBRARY_PATH=/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ucc/lib/ucc:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib/ucx:/opt/hpcx/ucx/lib:/opt/hpcx/sharp/lib:/opt/hpcx/hcoll/lib:/opt/hpcx/ompi/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV OLD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs
ENV LIBRARY_PATH=/opt/hpcx/nccl_rdma_sharp_plugin/lib:/opt/hpcx/ompi/lib:/opt/hpcx/sharp/lib:/opt/hpcx/ucc/lib:/opt/hpcx/ucx/lib:/opt/hpcx/hcoll/lib:/opt/hpcx/ompi/lib:/usr/local/cuda/lib64/stubs
ENV OLD_CPATH=""
ENV CPATH=/opt/hpcx/ompi/include:/opt/hpcx/ucc/include:/opt/hpcx/ucx/include:/opt/hpcx/sharp/include:/opt/hpcx/hcoll/include
ENV PKG_CONFIG_PATH=/opt/hpcx/hcoll/lib/pkgconfig:/opt/hpcx/sharp/lib/pkgconfig:/opt/hpcx/ucx/lib/pkgconfig:/opt/hpcx/ompi/lib/pkgconfig
# End of auto-generated paths

# Disable UCX VFS to stop errors about fuse mount failure
ENV UCX_VFS_ENABLE=no

# Install uv
ADD https://astral.sh/uv/install.sh /uv-installer.sh
RUN sh /uv-installer.sh && rm /uv-installer.sh
