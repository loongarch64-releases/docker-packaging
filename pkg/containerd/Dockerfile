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

# 构建 containerd 软件包（containerd.io 的 deb/rpm + static tar 包）。
# 由 docker-bake.hcl 驱动：pkg-<pkg>-<distro> 目标注入下面的构建参数，
# 并把构建写入 /out 的内容导出成产物。
#
# 流水线：
#   scripts/xx/go*            : 命名上下文、交叉编译辅助、Go 工具链
#   src*                      : 拉取 containerd、runc、hcsshim、libseccomp 源码
#   metadata                  : 计算要写进包里的版本/commit
#   builder-{deb,rpm,static}  : 按 DISTRO_TYPE 选中构建器，产出软件包
#   build-pkg/pkg             : 选中匹配的构建器并导出 /out
#
# loong64：本 fork 在 loongarch64 上原生构建；平台列表与发行版列表已在
# docker-bake.hcl 中收敛，基础镜像统一取自龙芯镜像仓库 lcr.loongnix.cn。

# tonistiigi/xx 交叉编译辅助工具的版本（见下面的 xx 阶段）
ARG XX_VERSION="1.9.0"

# loong64：基础镜像统一来自龙芯镜像仓库（lcr.loongnix.cn）
ARG ALPINE_IMAGE="lcr.loongnix.cn/library/alpine"
ARG ALPINE_VERSION="3.23"

# go-md2man 用于生成 deb/rpm 包内带的 containerd man pages
# https://github.com/containerd/containerd/blob/main/.github/workflows/ci.yml#L111
ARG MD2MAN_VERSION="v2.0.2"

# 源码仓库；RUNC_REF/RUNHCS_REF 为空时取 containerd 自己钉住的版本
# （containerd 的 script/setup/{runc,runhcs}-version）
ARG RUNC_REPO="https://github.com/opencontainers/runc.git"
ARG RUNHCS_REPO="https://github.com/Microsoft/hcsshim.git"

# 目标发行版：DISTRO_IMAGE 是构建环境镜像，DISTRO_TYPE 决定用哪个构建器阶段
# （deb/rpm/static），DISTRO_RELEASE/DISTRO_SUITE 用于产物路径与包元数据
# （例如 debian13 → .../debian/trixie/loong64/）
ARG DISTRO_NAME="debian13"
ARG DISTRO_TYPE="deb"
ARG DISTRO_RELEASE="debian"
ARG DISTRO_ID="13"
ARG DISTRO_SUITE="trixie"
ARG DISTRO_IMAGE="lcr.loongnix.cn/library/debian:trixie"

# 要构建的包（containerd 包内含 containerd、ctr、shim-runc-v2 和 runc）
ARG PKG_NAME="containerd"
ARG PKG_REPO="https://github.com/containerd/containerd.git"
ARG PKG_REF="main"

# Go 工具链镜像，按 ${GO_IMAGE}:${GO_VERSION}-${GO_IMAGE_VARIANT} 使用
ARG GO_IMAGE="lcr.loongnix.cn/library/golang"
ARG GO_VERSION="1.27.1"
ARG GO_IMAGE_VARIANT="forky"

# 空阶段，仅作为命名上下文使用，用来挂载 hack/scripts
# 见 docker-bake.hcl 里的 pkg 目标
FROM scratch AS scripts

# 交叉编译辅助工具。下面各构建器里的 `COPY --from=xx / /` 会提供 xx-* 包装脚本
# （xx-info、xx-go、xx-apt-get、xx-verify 等）供构建脚本调用。该阶段跑在构建平台，
# loong64 原生构建时这些包装脚本就指向宿主机工具链。
FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

# Go 基础镜像，用来取 /usr/local/go：go 跑在目标平台，gocross 跑在构建平台。
# deb/rpm 构建器从 go 阶段挂载工具链，static 构建器（构建平台）从 gocross 挂载。
FROM ${GO_IMAGE}:${GO_VERSION}-${GO_IMAGE_VARIANT} AS go
FROM --platform=$BUILDPLATFORM ${GO_IMAGE}:${GO_VERSION}-${GO_IMAGE_VARIANT} AS gocross

# md2man：编译 go-md2man，供 deb/rpm 构建里的 `make man` 使用；
# 产物会被拷进各构建器的 $GOPATH/bin。
FROM go AS go-md2man
ENV GOPROXY="https://proxy.golang.org|direct"
ENV GOTOOLCHAIN="local"
ENV GO111MODULE="on"
ARG MD2MAN_VERSION
RUN go install github.com/cpuguy83/go-md2man/v2@${MD2MAN_VERSION}

# src：下面各源码拉取阶段的公共基础镜像（只需要 git/curl/tar）
FROM --platform=$BUILDPLATFORM ${ALPINE_IMAGE}:${ALPINE_VERSION} AS src-base
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

# runhcs-src：按 RUNHCS_REF 克隆 hcsshim；该值为空时用
# script/setup/runhcs-version 钉住的版本。它只用于构建 Windows 的
# containerd-shim-runhcs-v1，loong64（linux）构建不会用到。
FROM src-base AS runhcs-src
WORKDIR /src
ARG RUNHCS_REPO
ARG RUNHCS_REF
RUN git init . && git remote add origin "${RUNHCS_REPO}"
RUN --mount=from=src,source=/src,target=/containerd <<EOT
  set -e
  [ -z "$RUNHCS_REF" ] && RUNHCS_REF=$(cat /containerd/script/setup/runhcs-version)
  set -x
  git fetch origin "$RUNHCS_REF" +refs/heads/*:refs/remotes/origin/* +refs/tags/*:refs/tags/*
  git checkout -q FETCH_HEAD
EOT

# libseccomp-src：下载 runc 在其 Dockerfile 里钉住的 libseccomp 源码版本。
# 只有 static 构建会自己编译并静态链接它；deb/rpm 用的是发行版自带的
# libseccomp(-dev/-devel) 包。
FROM src-base AS libseccomp-src
WORKDIR /src
RUN --mount=from=runc-src,source=/src,target=/runc <<EOT
  set -e
  LIBSECCOMP_VERSION=$(grep '^ARG LIBSECCOMP_VERSION=' /runc/Dockerfile | cut -d'=' -f2)
  set -x
  curl -sSL "https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" | tar -xz --strip-components=1
EOT

# metadata：对 containerd/runc/runhcs 的源码树执行 hack/scripts/gen-ver，
# 把 repo/ref/version/commit 写入 /out/metadata.env
# （CI 用它给 release 镜像打 tag、生成 release 说明）
FROM src-base AS metadata-builder
ARG PKG_REPO
ARG PKG_REF
ARG RUNC_REPO
ARG RUNC_REF
ARG RUNHCS_REPO
ARG RUNHCS_REF
ARG NIGHTLY_BUILD
RUN --mount=type=bind,from=scripts,source=gen-ver.sh,target=/usr/local/bin/gen-ver \
    --mount=type=bind,from=src,source=/src,target=/src \
    --mount=type=bind,from=runc-src,source=/src,target=/runc-src \
    --mount=type=bind,from=runhcs-src,source=/src,target=/runhcs-src <<EOT
  set -e
  mkdir -p /out
  for l in $(gen-ver "/src"); do
    export "${l?}"
  done
  cat > "/out/metadata.env" <<-EOF
REPO=${PKG_REPO%.*}
REF=${PKG_REF}
VERSION=${GENVER_VERSION}
COMMIT=${GENVER_COMMIT}
EOF
  [ -z "$RUNC_REF" ] && RUNC_REF=$(cat /src/script/setup/runc-version)
  for l in $(gen-ver "/runc-src"); do
    export "${l?}"
  done
  cat >> "/out/metadata.env" <<-EOF
RUNC_REPO=${RUNC_REPO%.*}
RUNC_REF=${RUNC_REF}
RUNC_VERSION=${GENVER_VERSION}
RUNC_COMMIT=${GENVER_COMMIT}
EOF
  [ -z "$RUNHCS_REF" ] && RUNHCS_REF=$(cat /src/script/setup/runhcs-version)
  for l in $(gen-ver "/runhcs-src"); do
    export "${l?}"
  done
  cat >> "/out/metadata.env" <<-EOF
RUNHCS_REPO=${RUNHCS_REPO%.*}
RUNHCS_REF=${RUNHCS_REF}
RUNHCS_VERSION=${GENVER_VERSION}
RUNHCS_COMMIT=${GENVER_COMMIT}
EOF
EOT

# metadata：导出 metadata.env（供 CI 的 release job 读取）
FROM scratch AS metadata
COPY --from=metadata-builder /out /

# deb：构建 containerd.io 的 .deb 包。
#  1. 装构建工具（mk-build-deps 等）
#  2. 按 deb/control 里的 Build-Depends 装依赖
#  3. 执行 pkg-deb-build（走 debian/rules），从挂载进来的源码树
#     （外加 /usr/local/go）编译 containerd/runc，并调用 dpkg-buildpackage
# 这里的挂载是可读写的：构建过程会在源码树里生成临时构建目录。
FROM ${DISTRO_IMAGE} AS builder-deb
COPY --from=xx / /
ENV GOPROXY="https://proxy.golang.org|direct"
ENV GOPATH="/go"
ENV GOTOOLCHAIN="local"
ENV GO111MODULE="on"
ENV PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
COPY --from=go-md2man /go/bin/go-md2man $GOPATH/bin/go-md2man
ARG DISTRO_NAME
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils bash ca-certificates curl devscripts equivs git lsb-release
COPY deb /root/package/debian
ARG TARGETPLATFORM
RUN mk-build-deps -t "xx-apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y" -i /root/package/debian/control
WORKDIR /root/package
ARG NIGHTLY_BUILD
ARG DISTRO_RELEASE
ARG DISTRO_ID
ARG DISTRO_SUITE
ARG PKG_NAME
ARG PKG_REF
ARG PKG_PACKAGER
ARG PKG_DEB_BUILDFLAGS
ARG PKG_DEB_REVISION
ARG PKG_DEB_EPOCH
ARG SOURCE_DATE_EPOCH
RUN --mount=type=bind,source=scripts/pkg-deb-build.sh,target=/usr/local/bin/pkg-deb-build \
    --mount=type=bind,from=scripts,source=gen-ver.sh,target=/usr/local/bin/gen-ver \
    --mount=type=bind,from=scripts,source=gen-deb-changelog.sh,target=/usr/local/bin/gen-deb-changelog \
    --mount=type=bind,from=scripts,source=fix-cc.sh,target=/usr/local/bin/fix-cc \
    --mount=type=bind,source=common,target=/common,rw \
    --mount=type=bind,from=src,source=/src,target=/go/src/github.com/containerd/containerd,rw \
    --mount=type=bind,from=runc-src,source=/src,target=/go/src/github.com/opencontainers/runc,rw \
    --mount=type=bind,from=go,source=/usr/local/go,target=/usr/local/go \
    OUTDIR=/out SRCDIR=/go/src/github.com/containerd/containerd pkg-deb-build

# rpm：构建 containerd.io 的 .rpm 包。
#  1. rpm-init 按发行版配置 dnf/repo（RH_USER/RH_PASS 只有订阅制 RHEL 需要）
#  2. rpm-builddep 安装 rpm/containerd.spec 的 BuildRequires
#  3. pkg-rpm-build 跑 rpmbuild：spec + 源码 tar 包（SOURCES）+ 挂载的源码树
#     （外加 /usr/local/go）
FROM ${DISTRO_IMAGE} AS builder-rpm
COPY --from=xx / /
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
# 注意：loongarch64 上 rpm/setarch 用的架构名是 "loongarch64"（xx-info 报的是
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
ARG PKG_RPM_BUILDFLAGS
ARG PKG_RPM_RELEASE
ARG SOURCE_DATE_EPOCH
RUN --mount=type=bind,source=scripts/pkg-rpm-build.sh,target=/usr/local/bin/pkg-rpm-build \
    --mount=type=bind,from=scripts,source=gen-ver.sh,target=/usr/local/bin/gen-ver \
    --mount=type=bind,from=scripts,source=fix-cc.sh,target=/usr/local/bin/fix-cc \
    --mount=type=bind,source=common/containerd.toml,target=/root/rpmbuild/SOURCES/containerd.toml \
    --mount=type=bind,from=src-tgz,source=/out/containerd.tgz,target=/root/rpmbuild/SOURCES/containerd.tgz \
    --mount=type=bind,from=runc-src-tgz,source=/out/runc.tgz,target=/root/rpmbuild/SOURCES/runc.tgz \
    --mount=type=bind,from=src,source=/src,target=/go/src/github.com/containerd/containerd,rw \
    --mount=type=bind,from=runc-src,source=/src,target=/go/src/github.com/opencontainers/runc,rw \
    --mount=type=bind,from=go,source=/usr/local/go,target=/usr/local/go \
    OUTDIR=/out SRCDIR=/go/src/github.com/containerd/containerd pkg-rpm-build

# static：为 static 发行版构建静态 tar 包（containerd、ctr、
# containerd-shim-runc-v2 和 runc）。与 deb/rpm 不同，这个阶段跑在构建平台上，
# 不使用发行版的 Go/libseccomp 包：
#  - libseccomp 由源码编译并静态链接
#  - runc 以 "-libpathrs" 构建（走 pathrs-lite 后端）
#  - 全部启用 CGO 编译，编译后用 xx-verify --static 校验
#  - pkg-static-build 逐个打成 tar 包，并在旁边写 .sha256
FROM --platform=$BUILDPLATFORM ${DISTRO_IMAGE} AS builder-static
COPY --from=xx / /
RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates file git gperf zip tar \
  dpkg-dev clang make pkg-config
ENV GOPROXY="https://proxy.golang.org|direct"
ENV GOPATH="/go"
ENV PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
ENV GOTOOLCHAIN="local"
ENV GO111MODULE="on"
ENV CGO_ENABLED="1"
ARG PKG_NAME
ARG PKG_REF
ARG NIGHTLY_BUILD
ARG RUNC_REF
WORKDIR /build
ARG TARGETPLATFORM
# 目标架构的 gcc（目标平台 == 构建平台时就是本机 gcc）
RUN xx-apt-get install -y gcc
RUN --mount=type=bind,source=scripts/pkg-static-build.sh,target=/usr/local/bin/pkg-static-build \
    --mount=type=bind,from=scripts,source=gen-ver.sh,target=/usr/local/bin/gen-ver \
    --mount=type=bind,from=scripts,source=fix-cc.sh,target=/usr/local/bin/fix-cc \
    --mount=type=bind,from=scripts,source=write-sha256sum.sh,target=/usr/local/bin/write-sha256sum \
    --mount=type=bind,from=src,source=/src,target=/go/src/github.com/containerd/containerd,rw \
    --mount=type=bind,from=runc-src,source=/src,target=/go/src/github.com/opencontainers/runc,rw \
    --mount=type=bind,from=runhcs-src,source=/src,target=/go/src/github.com/Microsoft/hcsshim,rw \
    --mount=type=bind,from=libseccomp-src,source=/src,target=/usr/local/src/libseccomp,rw \
    --mount=type=bind,from=gocross,source=/usr/local/go,target=/usr/local/go,rw \
    OUTDIR=/out BUILDDIR=/build SRCDIR=/go/src/github.com/containerd/containerd RUNC_SRCDIR=/go/src/github.com/opencontainers/runc RUNHCS_SRCDIR=/go/src/github.com/Microsoft/hcsshim LIBSECCOMP_SRCDIR=/usr/local/src/libseccomp pkg-static-build

# build-pkg：按 DISTRO_TYPE（deb/rpm/static）选中对应的构建器。
# 该阶段同时也是 BuildKit 做 SBOM 扫描的阶段（BUILDKIT_SBOM_SCAN_STAGE）。
FROM builder-${DISTRO_TYPE} AS build-pkg
ARG BUILDKIT_SBOM_SCAN_STAGE=true

# pkg：最终阶段；导出上面构建器写入 /out 的软件包
# （用 local exporter 时落在 ./bin/pkg/<pkg>/<distro>/<os>_<arch>/...）
FROM scratch AS pkg
COPY --from=build-pkg /out /
