# SPDX-FileCopyrightText: 2026 spatterlight
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# The container image this role runs. Alpine only packages tinc 1.0.36, so tinc is built from the release tarball,
# with the same configure options as Alpine's own package.
#
# CI publishes it as `ghcr.io/mother-of-all-self-hosting/ansible-role-tinc:<TINC_VERSION>-<release>`
# (see `.github/workflows/release-image.yml`), and the role builds it itself when `tinc_container_image_self_build` is enabled.

FROM docker.io/alpine:3.24.4 AS build

# tinc 1.0.37 is expected to be the last release of tinc 1.0, so nothing tracks it for updates.
# Moving to another release means changing both values, the checksum being the SHA-512 of the release tarball.
ARG TINC_VERSION=1.0.37
ARG TINC_SHA512=916706d32278a4659f1d7da8c58bc5764c1ab5d8f31214dad51e45aae6cf765436f2e9ad55647980b5ba7726d6cfaa1fcf25fbeaffdd95436e77ec3153278237

RUN apk add --no-cache build-base linux-headers lzo-dev openssl-dev zlib-dev

WORKDIR /src

RUN wget -q -O tinc.tar.gz "https://www.tinc-vpn.org/packages/tinc-${TINC_VERSION}.tar.gz" && \
    echo "${TINC_SHA512}  tinc.tar.gz" | sha512sum -c - && \
    tar -xzf tinc.tar.gz --strip-components=1 && \
    ./configure \
      --prefix=/usr \
      --sysconfdir=/etc \
      --localstatedir=/var \
      --runstatedir=/run \
      --enable-jumbograms \
      --enable-lzo \
      --enable-zlib && \
    make && \
    make DESTDIR=/install install

FROM docker.io/alpine:3.24.4

# iproute2 gives the scripts tinc runs (`tinc-up`, `tinc-down`) the full `ip` command instead of BusyBox's.
RUN apk add --no-cache iproute2 libcrypto3 lzo zlib

COPY --from=build /install/usr/sbin/tincd /usr/sbin/tincd

EXPOSE 655/tcp 655/udp

ENTRYPOINT ["/usr/sbin/tincd"]
CMD ["--config=/etc/tinc", "--no-detach"]
