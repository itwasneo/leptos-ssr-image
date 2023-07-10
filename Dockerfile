# This dockerfile is configured specifically for Leptos + actix with SSR applications.
# It installs all the necessarry rust toolchain and cargo packages installed.
# It uses static linking for some common libraries (openssl, zstd, libz etc.)
# It uses mold as linker for musl targets.

FROM ubuntu:jammy as builder
LABEL maintainer="itwasneo"

RUN apt-get update && apt-get install -y \
    musl-dev \
    musl-tools \
    clang \
    curl \
    g++ \
    pkgconf \
    xutils-dev \
    libssl-dev \
    ca-certificates \
    zstd \
    libzstd-dev \
    git \
    binaryen \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

ARG CHANNEL
ENV RUSTUP_VER="1.26.0" \
    RUST_ARCH="x86_64-unknow-linux-gnu"

ENV RUSTUP_VER="1.26.0" \
    RUST_ARCH="x86_64-unknown-linux-gnu" \
    CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

# Installing rust toolchain, x86_64-unknown-linux-musl and wasm32 targets
RUN curl "https://static.rust-lang.org/rustup/archive/${RUSTUP_VER}/${RUST_ARCH}/rustup-init" -o rustup-init && \
    chmod +x rustup-init && \
    ./rustup-init -y --default-toolchain ${CHANNEL} --profile minimal --no-modify-path && \
    rm rustup-init && \
    ~/.cargo/bin/rustup target add x86_64-unknown-linux-musl && \
    ~/.cargo/bin/rustup target add wasm32-unknown-unknown

# Configuring default linker to be mold for musl targets (Slight compile time optimization)
RUN echo "[target.x86_64-unknown-linux-musl]\nrustflags=[\"-C\", \"link-arg=-fuse-ld=mold\"]" >> /root/.cargo/config.toml && \
    cat /root/.cargo/config.toml

# Cloning and compiling mold (better performing linker)
RUN git clone https://github.com/rui314/mold.git && \
    mkdir mold/build && \
    cd mold/build && \
    git checkout v1.11.0 && \
    ../install-build-deps.sh && \
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=c++ .. && \
    cmake --build . -j $(nproc) && \
    cmake --install . && \
    cd ../../ && \
    rm -rf mold

# Setting up some environment variables
ENV SSL_VER="1.1.1q" \
    CURL_VER="8.1.2" \
    ZLIB_VER="1.2.13" \
    CC=musl-gcc \
    PREFIX=/musl \
    PATH=/usr/local/bin:/root/.cargo/bin:$PATH \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=$PREFIX

# Creating some symlinks for pkg-config
RUN mkdir $PREFIX && \
    echo "$PREFIX/lib" >> /etc/ld-musl-x86_64.path && \
    ln -s /usr/include/x86_64-linux-gnu/asm /usr/include/x86_64-linux-musl/asm && \
    ln -s /usr/include/asm-generic /usr/include/x86_64-linux-musl/asm-generic && \
    ln -s /usr/include/linux /usr/include/x86_64-linux-musl/linux

# zlib
RUN curl -sSL https://zlib.net/zlib-$ZLIB_VER.tar.gz | tar xz && \
    cd zlib-$ZLIB_VER && \
    CC="musl-gcc -fPIC -pie" LDFLAGS="-L$PREFIX/lib" CFLAGS="-I$PREFIX/include" ./configure --static --prefix=$PREFIX && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf zlib-$ZLIB_VER

# openssl
RUN curl -sSL https://www.openssl.org/source/openssl-$SSL_VER.tar.gz | tar xz && \
    cd openssl-$SSL_VER && \
    ./Configure no-zlib no-shared -fPIC --prefix=$PREFIX --openssldir=$PREFIX/ssl linux-x86_64 && \
    env C_INCLUDE_PATH=$PREFIX/include make depend 2> /dev/null && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf openssl-$SSL_VER

# Setting up some environment variables for mostly statically linkable libraries(openssl, zstd, libz)
ENV PATH=/root/.cargo/bin:$PREFIX/bin:$PATH \
    RUSTUP_HOME=/root/.rustup \
    CARGO_BUILD_TARGET=x86_64-unknown-linux-musl \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    OPENSSL_STATIC=true \
    OPENSSL_DIR=$PREFIX \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    LIBZ_SYS_STATIC=1 \
    TZ=Etc/UTC \
    CC_aarch64_unknown_linux_musl=clang \
    CC_x86_unknown_linux_musl=clang \
    ZSTD_SYS_USE_PKG_CONFIG=1 \
    OPENSSL_SYS_USE_PKG_CONFIG=1

# Installing cargo leptos
RUN cargo install --locked cargo-leptos

WORKDIR /build

COPY . .
RUN LEPTOS_BIN_TARGET_TRIPLE="$(uname -m)-unknown-linux-musl" cargo leptos build --release
RUN mv "./target/server/$(uname -m)-unknown-linux-musl/release/leptos_start" "./target/server/release/leptos_start"

# RUNTIME
FROM alpine:latest as runtime
WORKDIR /app

RUN addgroup --system --gid 1001 server
RUN adduser --system --uid 1001 www-data

COPY --chown=www-data:server --from=builder /build/target/server/release/leptos_start ./server/leptos_start
COPY --chown=www-data:server --from=builder /build/target/front/wasm32-unknown-unknown/wasm-release/leptos_start.wasm ./front/leptos_start.wasm
COPY --chown=www-data:server --from=builder /build/target/site ./site

USER www-data

ENV LEPTOS_OUTPUT_NAME "leptos_start"
ENV LEPTOS_SITE_ROOT "/app/site"
ENV LEPTOS_ENV "PROD"
ENV LEPTOS_SITE_ADDR "0.0.0.0:3000"

EXPOSE 3000

CMD ["./server/leptos_start"]

