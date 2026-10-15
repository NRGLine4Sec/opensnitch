#!/usr/bin/env bash
#
# Builds the opensnitch-dev and python3-opensnitch-ui-dev packages for
# Debian 13 (trixie, amd64) from the port scan detection branch of OpenSnitch.
#
# Everything is compiled inside a golang:1.25-trixie container; the host needs
# only git, and docker or podman. See README.md.
#
# Usage: ./build.sh [options]
#   --repo URL|DIR    git repository holding the branch
#                     (default: https://github.com/NRGLine4Sec/opensnitch.git)
#   --ref REF         branch or tag to build, or a commit when --repo is a
#                     local clone (default: portscan-upstream)
#   --kernel KVER     Debian kernel the OpenSnitch eBPF modules are built for
#                     (default: 7.2.6+deb13-amd64)
#   --snapshot TS     snapshot.debian.org timestamp holding that kernel's
#                     headers (default: 20261014T000000Z)
#   --version V       package version (default: <base>~dev+portscan.g<commit>)
#   --out DIR         where the packages go (default: ./out)
#
# The engine is docker if its daemon answers, podman otherwise; ENGINE
# overrides it (for instance ENGINE="podman --root /some/storage").
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=https://github.com/NRGLine4Sec/opensnitch.git
REF=portscan-upstream
KVER=7.2.6+deb13-amd64
KSNAP=20261014T000000Z
VERSION=
OUT=$PWD/out
IMAGE=docker.io/library/golang:1.25-trixie

die() { echo "build.sh: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case $1 in
        --repo)     REPO=${2:?}; shift 2 ;;
        --ref)      REF=${2:?}; shift 2 ;;
        --kernel)   KVER=${2:?}; shift 2 ;;
        --snapshot) KSNAP=${2:?}; shift 2 ;;
        --version)  VERSION=${2:?}; shift 2 ;;
        --out)      OUT=${2:?}; shift 2 ;;
        -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *)          die "unknown option $1 (see --help)" ;;
    esac
done

command -v git >/dev/null || die "git is required"
if [ -z "${ENGINE:-}" ]; then
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null; then ENGINE=podman
    else die "docker (with its daemon running) or podman is required"; fi
fi

# The exported source goes to a scratch directory removed on exit; the Go
# module cache is kept between runs, so a rebuild does not download
# everything again.
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/opensnitch-dev-build.XXXXXX")
trap 'rm -rf "$W"' EXIT
CACHE=${GOMODCACHE_DIR:-$HOME/.cache/opensnitch-dev-build/gomod}
mkdir -p "$CACHE" "$W/src"

echo "==> source: $REPO $REF"
if [ -d "$REPO" ]; then
    git -C "$REPO" rev-parse --verify -q "$REF^{commit}" >/dev/null || die "$REF not found in $REPO"
    git -C "$REPO" archive "$REF" | tar -x -C "$W/src"
    rev=$(git -C "$REPO" rev-parse --short=8 "$REF^{commit}")
else
    git clone -q --depth 1 --branch "$REF" "$REPO" "$W/clone" || die "cannot clone $REF from $REPO"
    git -C "$W/clone" archive HEAD | tar -x -C "$W/src"
    rev=$(git -C "$W/clone" rev-parse --short=8 HEAD)
fi
[ -f "$W/src/daemon/portscan/engine.go" ] || die "$REF does not contain the port scan detection feature"

base=$(grep -oE '"[0-9.]+"' "$W/src/daemon/core/version.go" | tr -d '"')
VERSION=${VERSION:-${base}~dev+portscan.g${rev}}
echo "==> commit $rev, package version $VERSION, eBPF modules for $KVER"

# The container runs as root. Under docker that is real root, so what it
# writes is handed back to the caller afterwards; under rootless podman it is
# already the caller, and a chown would give the files to a subordinate uid.
HANDBACK=true
case ${ENGINE%% *} in docker|*/docker) HANDBACK="chown -R $(id -u):$(id -g) /out /gomod" ;; esac
$ENGINE run --rm \
    -e VERSION="$VERSION" -e KVER="$KVER" -e KSNAP="$KSNAP" \
    -v "$W/src:/src" -v "$OUT:/out" -v "$CACHE:/gomod" -v "$HERE:/kit:ro" \
    "$IMAGE" bash -c "bash /kit/container-build.sh && $HANDBACK"

( cd "$OUT" && sha256sum ./*_"$VERSION"_*.deb > "SHA256SUMS-$VERSION" )
echo "==> done:"
ls -l "$OUT"/*_"$VERSION"_*.deb "$OUT/SHA256SUMS-$VERSION"
