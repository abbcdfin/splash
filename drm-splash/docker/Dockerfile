FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# archive.ubuntu.com only carries amd64/i386; armhf lives on ports.ubuntu.com.
# Restrict the default sources to amd64, then add ports for armhf.
RUN dpkg --add-architecture armhf && \
    sed -i 's/^deb /deb [arch=amd64] /' /etc/apt/sources.list && \
    echo "deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports focal-security main restricted universe multiverse" >> /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc \
        libc-dev \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        cmake \
        make \
        ninja-build \
        pkg-config \
        python3 \
        python3-pip \
        xz-utils \
        bzip2 \
        bc \
        perl && \
    rm -rf /var/lib/apt/lists/*

# Install a recent meson via pip (focal ships 0.53 which is too old for libdrm 2.4.123+)
RUN pip3 install meson==0.63.3

ENV CROSS_TRIPLE=arm-linux-gnueabihf
ENV CC=arm-linux-gnueabihf-gcc
ENV CXX=arm-linux-gnueabihf-g++
ENV AR=arm-linux-gnueabihf-ar

# Meson cross-file for ARM
RUN printf '[binaries]\n\
c = '"'"'arm-linux-gnueabihf-gcc'"'"'\n\
ar = '"'"'arm-linux-gnueabihf-ar'"'"'\n\
strip = '"'"'arm-linux-gnueabihf-strip'"'"'\n\
pkgconfig = '"'"'pkg-config'"'"'\n\
[host_machine]\n\
system = '"'"'linux'"'"'\n\
cpu_family = '"'"'arm'"'"'\n\
cpu = '"'"'cortex-a7'"'"'\n\
endian = '"'"'little'"'"'\n' > /arm-cross.ini

# Build static libdrm for ARM from source (Ubuntu focal packages only ship .so)
COPY libdrm-2.4.123.tar.xz /tmp/
ENV PKG_CONFIG_PATH=/opt/libdrm-arm/lib/pkgconfig
RUN tar xJ -C /tmp -f /tmp/libdrm-2.4.123.tar.xz && \
    cd /tmp/libdrm-2.4.123 && \
    meson setup build \
        --cross-file /arm-cross.ini \
        --default-library=static \
        --prefix=/opt/libdrm-arm \
        -Dintel=disabled \
        -Damdgpu=disabled \
        -Dradeon=disabled \
        -Dnouveau=disabled \
        -Dvmwgfx=disabled \
        -Dtests=false \
        -Dman-pages=disabled && \
    ninja -C build install && \
    rm -rf /tmp/libdrm-2.4.123 /tmp/libdrm-2.4.123.tar.xz

# Build static busybox for ARM from source.
# Tarballs are pre-downloaded into the docker/ build context to avoid
# network access during image build.
ARG BUSYBOX_VERSION=1.36.1
COPY busybox-${BUSYBOX_VERSION}.tar.bz2 /tmp/
RUN tar xj -C /tmp -f /tmp/busybox-${BUSYBOX_VERSION}.tar.bz2 && \
    cd /tmp/busybox-${BUSYBOX_VERSION} && \
    # defconfig with stdin from /dev/null to accept all new-option defaults silently
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- defconfig </dev/null && \
    # Enable fully static linking
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config && \
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) && \
    cp busybox /opt/busybox-arm && \
    rm -rf /tmp/busybox-${BUSYBOX_VERSION} /tmp/busybox-${BUSYBOX_VERSION}.tar.bz2
