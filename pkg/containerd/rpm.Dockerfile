# syntax=docker/dockerfile:1

# Copyright 2022 Docker Packaging authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 从 Dockerfile 抽出的 rpm 专用版本：只构建 containerd.io 的 .rpm 包。
# 与 Dockerfile 的差别：去掉 deb/static 两个构建器、去掉 runhcs（Windows）源码
# 阶段、去掉 metadata 阶段和 libseccomp 源码阶段，只留 rpm 需要的最小阶段链。
#
# 无交叉编译：只做 loong64 原生构建，不使用 tonistiigi/xx，因此没有 xx 阶段、
# 没有 gocross 阶段，也没有 --platform=$BUILDPLATFORM 覆盖。
#
# 阶段链：
#   scripts        : 空阶段，仅作命名上下文，用来挂载 hack/scripts
#   go             : Go 工具链镜像（提供 /usr/local/go）
#   go-md2man      : 编译 go-md2man，供 rpm 构建里的 `make man` 使用
#   src-base       : 源码拉取阶段的公共基础镜像（alpine）
#   src / src-tgz  : containerd 源码及其 tar 包（rpm 的 Source0）
#   runc-src / runc-src-tgz : runc 源码及其 tar 包（rpm 的 Source3）
#   builder-rpm    : 在 DISTRO_IMAGE 里 rpm-init → rpm-builddep → pkg-rpm-build
#   build-pkg/pkg  : 选中构建器并导出 /out
#
# 用法（直接 buildx build；scripts 通过命名构建上下文传入）：
#   cd pkg/containerd
#   docker buildx build -f rpm.Dockerfile --target pkg \
#     --build-context scripts=../../hack/scripts \
#     --build-arg PKG_REF=v2.4.1 \
#     -o type=local,dest=../../bin/pkg/containerd/anolis23 .

# loong64：基础镜像统一来自龙芯镜像仓库（lcr.loongnix.cn）
ARG ALPINE_IMAGE="lcr.loongnix.cn/library/alpine"
ARG ALPINE_VERSION="3.23"

# go-md2man 用于生成包里带的 containerd man pages
# https://github.com/containerd/containerd/blob/main/.github/workflows/ci.yml#L111
ARG MD2MAN_VERSION="v2.0.2"

# runc 源码仓库；RUNC_REF 为空时取 containerd 自己钉住的版本
# （containerd 的 script/setup/runc-version）
ARG RUNC_REPO="https://github.com/opencontainers/runc.git"

# 目标发行版（rpm 场景即 anolis23）：DISTRO_IMAGE 是构建环境镜像，
# DISTRO_RELEASE/DISTRO_SUITE 用于产物路径（anolis/23/loong64）
ARG DISTRO_NAME="anolis23"
ARG DISTRO_RELEASE="anolis"
ARG DISTRO_ID="23"
ARG DISTRO_SUITE="23"
ARG DISTRO_IMAGE="lcr.loongnix.cn/openanolis/anolisos:23"

# 要构建的包（containerd 包内含 containerd、ctr、shim-runc-v2 和 runc）
ARG PKG_NAME="containerd"
ARG PKG_REPO="https://github.com/containerd/containerd.git"
ARG PKG_REF="main"

# Go 工具链镜像，按 ${GO_IMAGE}:${GO_VERSION}-${GO_IMAGE_VARIANT} 使用
ARG GO_IMAGE="lcr.loongnix.cn/library/golang"
ARG GO_VERSION="1.27.1"
ARG GO_IMAGE_VARIANT="forky"

# 空阶段，仅作为命名上下文使用，用来挂载 hack/scripts
# （bake 由 docker-bake.hcl 的 contexts 提供；buildx build 用 --build-context scripts=）
FROM scratch AS scripts

# Go 基础镜像，用来取 /usr/local/go（builder-rpm 从这里挂载工具链）
FROM ${GO_IMAGE}:${GO_VERSION}-${GO_IMAGE_VARIANT} AS go

# md2man：编译 go-md2man，产物会拷进 builder-rpm 的 $GOPATH/bin
FROM go AS go-md2man
ENV GOPROXY="https://proxy.golang.org|direct"
ENV GOTOOLCHAIN="local"
ENV GO111MODULE="on"
ARG MD2MAN_VERSION
RUN go install github.com/cpuguy83/go-md2man/v2@${MD2MAN_VERSION}

# src：下面各源码拉取阶段的公共基础镜像（只需要 git/curl/tar）
FROM ${ALPINE_IMAGE}:${ALPINE_VERSION} AS src-base
RUN apk add --no-cache bash curl file git zip tar

# src：按 PKG_REF（分支、tag 或 commit）克隆 containerd 到 /src
FROM src-base AS src
WORKDIR /src
ARG PKG_REPO
RUN git init . && git remote add origin "${PKG_REPO}"
ARG PKG_REF
RUN  <<EOT
  set -ex
  git fetch origin "${PKG_REF}" +refs/heads/*:refs/remotes/origin/* +refs/tags/*:refs/tags/*
  git checkout -q FETCH_HEAD
EOT

# src-tgz：containerd 源码的 tar 包，作为 rpm 的 Source0
FROM src-base AS src-tgz
RUN --mount=from=src,source=/src,target=/containerd \
    mkdir /out && tar -C / -zcf /out/containerd.tgz --exclude .git containerd

# runc-src：按 RUNC_REF 克隆 runc；该值为空时用 containerd 的
# script/setup/runc-version 钉住的版本
FROM src-base AS runc-src
WORKDIR /src
ARG RUNC_REPO
ARG RUNC_REF
RUN git init . && git remote add origin "${RUNC_REPO}"
RUN --mount=from=src,source=/src,target=/containerd <<EOT
  set -e
  [ -z "$RUNC_REF" ] && RUNC_REF=$(cat /containerd/script/setup/runc-version)
  set -x
  git fetch origin "$RUNC_REF" +refs/heads/*:refs/remotes/origin/* +refs/tags/*:refs/tags/*
  git checkout -q FETCH_HEAD
EOT

# runc-src-tgz：runc 源码的 tar 包，作为 rpm 的 Source3
FROM src-base AS runc-src-tgz
RUN --mount=from=runc-src,source=/src,target=/runc \
    mkdir /out && tar -C / -zcf /out/runc.tgz --exclude .git runc

# rpm：构建 containerd.io 的 .rpm 包。
#  1. rpm-init 按发行版配置 dnf/repo（上游实现会额外挂 RH_USER/RH_PASS 两个 secret 给
#     订阅制 RHEL 用：本 fork 只建 anolis，且当前 Dockerfile 前端版本不支持 secret 的
#     env= 写法, 故这里不再挂载）
#  2. rpm-builddep 安装 rpm/containerd.spec 的 BuildRequires
#  3. pkg-rpm-build 跑 rpmbuild：spec + 源码 tar 包（SOURCES）+ 挂载的源码树
#     （外加 /usr/local/go）
FROM ${DISTRO_IMAGE} AS builder-rpm
ENV GOPROXY="https://proxy.golang.org|direct"
ENV GOPATH="/go"
ENV GOTOOLCHAIN="local"
ENV GO111MODULE="on"
ENV PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
COPY --from=go-md2man /go/bin/go-md2man $GOPATH/bin/go-md2man
ARG DISTRO_NAME
RUN --mount=type=bind,from=scripts,source=rpm-init.sh,target=/usr/local/bin/rpm-init \
    rpm-init $DISTRO_NAME
COPY rpm /root/rpmbuild/SPECS
ARG TARGETPLATFORM
# 注意：loongarch64 上 rpm/setarch 用的架构名是 "loongarch64"（不是 Go 风格的
# "loong64"），所以这里显式传 loongarch64。
RUN --mount=type=bind,from=scripts,source=rpm-builddep.sh,target=/usr/local/bin/rpm-builddep \
    rpm-builddep loongarch64 /root/rpmbuild/SPECS
WORKDIR /root/rpmbuild
ARG NIGHTLY_BUILD
ARG DISTRO_RELEASE
ARG DISTRO_ID
ARG DISTRO_SUITE
ARG PKG_NAME
ARG PKG_REF
ARG PKG_PACKAGER
ARG PKG_RPM_BUILDFLAGS="-bb"
ARG PKG_RPM_RELEASE
ARG SOURCE_DATE_EPOCH
RUN --mount=type=bind,source=scripts/pkg-rpm-build.sh,target=/usr/local/bin/pkg-rpm-build \
    --mount=type=bind,from=scripts,source=gen-ver.sh,target=/usr/local/bin/gen-ver \
    --mount=type=bind,source=common/containerd.toml,target=/root/rpmbuild/SOURCES/containerd.toml \
    --mount=type=bind,from=src-tgz,source=/out/containerd.tgz,target=/root/rpmbuild/SOURCES/containerd.tgz \
    --mount=type=bind,from=runc-src-tgz,source=/out/runc.tgz,target=/root/rpmbuild/SOURCES/runc.tgz \
    --mount=type=bind,from=src,source=/src,target=/go/src/github.com/containerd/containerd,rw \
    --mount=type=bind,from=runc-src,source=/src,target=/go/src/github.com/opencontainers/runc,rw \
    --mount=type=bind,from=go,source=/usr/local/go,target=/usr/local/go \
    OUTDIR=/out SRCDIR=/go/src/github.com/containerd/containerd pkg-rpm-build

# build-pkg：本文件只做 rpm，直接接上 builder-rpm。
# 该阶段同时也是 BuildKit 做 SBOM 扫描的阶段（BUILDKIT_SBOM_SCAN_STAGE）。
FROM builder-rpm AS build-pkg
ARG BUILDKIT_SBOM_SCAN_STAGE=true

# pkg：最终阶段；导出 builder-rpm 写入 /out 的 .rpm 包
# （用 local exporter 时落在 ./bin/pkg/<pkg>/<distro>/<os>_<arch>/...）
FROM scratch AS pkg
COPY --from=build-pkg /out /
