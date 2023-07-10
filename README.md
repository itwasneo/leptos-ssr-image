# leptos-ssr-image

- This dockerfile is configured specifically for SSR applications using Leptos with actix.
- It installs all the necessarry rust toolchain and cargo packages installed.
- It uses static linking for some common libraries (openssl, zstd, libz etc.)
- It uses mold as linker for musl targets.
