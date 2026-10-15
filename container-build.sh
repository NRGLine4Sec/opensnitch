#!/usr/bin/env bash
#
# Runs inside docker.io/library/golang:1.25-trixie, started by build.sh.
# Patches the source in /src into the "-dev" build (dev-patch.sh), generates
# the Go gRPC bindings, and builds the two "-dev" packages into /out:
#
#   opensnitch-dev_<ver>_amd64.deb             daemon, eBPF modules, service
#   python3-opensnitch-ui-dev_<ver>_all.deb    GUI
#
# Mounts: /src (exported source, rw), /out (rw), /gomod (Go module cache, rw),
# /kit (this directory, ro).
set -euo pipefail
VERSION=${VERSION:?}
# The kernel the eBPF modules of OpenSnitch itself (process monitor, DNS) are
# built for: they read kernel structures, so they follow the kernel's layout.
# The port scan module reads none and works on any 6.6+ kernel.
KVER=${KVER:-7.2.6+deb13-amd64}
# Backports keeps only its latest kernel; the headers of KVER come from this
# snapshot.debian.org timestamp when they are gone from the live archive.
KSNAP=${KSNAP:-20261014T000000Z}
MAINT="NRGLine4Sec <26851996+NRGLine4Sec@users.noreply.github.com>"
B=/build
mkdir -p $B /out

echo "==> build dependencies"
export DEBIAN_FRONTEND=noninteractive
{ echo "deb http://deb.debian.org/debian trixie-backports main"
  echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/$KSNAP trixie-backports main"; } > /etc/apt/sources.list.d/backports.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    libnetfilter-queue-dev libmnl-dev libnfnetlink-dev pkg-config gcc libc6-dev make \
    clang llvm libbpf-dev libelf-dev \
    rsync python3 xz-utils qt6-l10n-tools dpkg-dev file protobuf-compiler >/dev/null
apt-get install -y -qq --no-install-recommends -t trixie-backports "linux-headers-$KVER" >/dev/null

echo "==> -dev patch"
bash /kit/dev-patch.sh /src

echo "==> Go gRPC bindings"
# Generated, and ignored by git; the versions are those of the project's CI.
export GOMODCACHE=/gomod GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=1 PATH=$PATH:/root/go/bin
go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.1
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0
( cd /src/proto && make ../daemon/ui/protocol/ui.pb.go )

echo "==> daemon"
( cd /src/daemon && go build -trimpath -ldflags "-s -w" -o $B/opensnitchd-dev . )
file $B/opensnitchd-dev

echo "==> eBPF modules, against the Debian headers of $KVER"
# The Makefile's Debian path: /lib/modules/$KVER/{build,source} come with the
# headers package, and KERNEL_HEADERS defaults to /usr/src/linux-headers-$KVER.
# Kernel 7.2 headers refuse to be included without CC_USING_FENTRY when
# CONFIG_FUNCTION_TRACER is set (asm/ftrace.h); the kernel's own build defines
# it with -mfentry. It only guards ftrace's call-site macros, which a BPF
# program never uses, so it is defined here (the upstream Makefile predates
# 7.2). EXTRA_FLAGS repeats the Makefile's own x86_64 value, which a command
# line assignment replaces.
EXTRA="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fcf-protection=full -Wno-microsoft-anon-tag -fms-extensions -DCC_USING_FENTRY"
( cd /src/ebpf_prog && make KERNEL_VER=$KVER ARCH=x86 KERNEL_ARCH=x86_64 EXTRA_FLAGS="$EXTRA" 2>&1 | grep -E "^(ARCH|KERNEL_|EXTRA)|error" || true )
test -s /src/ebpf_prog/opensnitch.o -a -s /src/ebpf_prog/opensnitch-procs.o -a -s /src/ebpf_prog/opensnitch-dns.o
( cd /src/ebpf_prog && make -s -f Makefile.scan )
for m in opensnitch opensnitch-dns opensnitch-procs; do llvm-strip -g /src/ebpf_prog/$m.o; done
ls -l /src/ebpf_prog/*.o

echo "==> GUI translations"
QT_LRELEASE=/usr/lib/qt6/bin/lrelease
for d in /src/ui/i18n/locales/*/; do
    lang=$(basename "$d")
    mkdir -p /src/ui/opensnitch/i18n/$lang
    $QT_LRELEASE -silent "$d/opensnitch-$lang.ts" -qm /src/ui/opensnitch/i18n/$lang/opensnitch-$lang.qm
done
find /src/ui/opensnitch/proto -name 'ui_pb2_grpc.py' -exec sed -i 's/^import ui_pb2/from . import ui_pb2/' {} \;

# ------------------------------------------------------------ opensnitch-dev
echo "==> package opensnitch-dev"
R=$B/pkg-daemon
install -D -m 0755 $B/opensnitchd-dev                 $R/usr/bin/opensnitchd-dev
install -d $R/etc/opensnitchd-dev/rules $R/etc/opensnitchd-dev/tasks
install -m 0644 /src/daemon/data/default-config.json  $R/etc/opensnitchd-dev/
install -m 0644 /src/daemon/data/system-fw.json       $R/etc/opensnitchd-dev/
install -m 0644 /src/daemon/data/network_aliases.json $R/etc/opensnitchd-dev/
cp -a /src/daemon/data/rules/. $R/etc/opensnitchd-dev/rules/ 2>/dev/null || true
cp -a /src/daemon/data/tasks/. $R/etc/opensnitchd-dev/tasks/ 2>/dev/null || true
install -d $R/usr/lib/opensnitchd-dev/ebpf
install -m 0644 /src/ebpf_prog/opensnitch.o /src/ebpf_prog/opensnitch-dns.o \
    /src/ebpf_prog/opensnitch-procs.o /src/ebpf_prog/opensnitch-scan.o $R/usr/lib/opensnitchd-dev/ebpf/
install -D -m 0644 /kit/pkg/opensnitch-dev.service        $R/usr/lib/systemd/system/opensnitch-dev.service
install -D -m 0644 /kit/pkg/opensnitch-dev.logrotate      $R/etc/logrotate.d/opensnitch-dev
install -D -m 0644 /src/utils/packaging/daemon/deb/debian/copyright $R/usr/share/doc/opensnitch-dev/copyright
install -m 0644 /kit/pkg/README.Debian $R/usr/share/doc/opensnitch-dev/README.Debian

# Runtime libraries, from the binary itself.
libs=$(ldd $B/opensnitchd-dev | awk '/=>/ {print $3}')
deps=$(for l in $libs; do dpkg -S "$(readlink -f "$l")" 2>/dev/null || dpkg -S "$l" 2>/dev/null; done \
        | cut -d: -f1 | sort -u | tr '\n' ' ')
depends=$(for p in $deps; do echo -n "$p, "; done | sed 's/, $//')
echo "    Depends: $depends"

install -d $R/DEBIAN
find $R/etc -type f | sed "s#^$R##" | sort > $R/DEBIAN/conffiles
install -m 0755 /kit/pkg/daemon.postinst $R/DEBIAN/postinst
install -m 0755 /kit/pkg/daemon.prerm    $R/DEBIAN/prerm
install -m 0755 /kit/pkg/daemon.postrm   $R/DEBIAN/postrm
size=$(du -sk --exclude=DEBIAN $R | cut -f1)
cat > $R/DEBIAN/control <<EOF
Package: opensnitch-dev
Version: $VERSION
Architecture: amd64
Maintainer: $MAINT
Installed-Size: $size
Depends: $depends
Recommends: python3-opensnitch-ui-dev
Section: net
Priority: optional
Homepage: https://github.com/evilsocket/opensnitch
Description: OpenSnitch application firewall, development build with port scan detection
 Development build of the OpenSnitch daemon including inbound port scan
 detection and blocking. Its eBPF modules are built for the Debian kernel
 ${KVER}. It installs beside the official opensnitch package
 without sharing any file: binary opensnitchd-dev, configuration in
 /etc/opensnitchd-dev, eBPF modules in /usr/lib/opensnitchd-dev, service
 opensnitch-dev.service (which conflicts with opensnitch.service, so the two
 daemons never run together) and GUI socket /tmp/osui-dev.sock.
EOF
dpkg-deb --root-owner-group -Zxz --build $R /out/opensnitch-dev_${VERSION}_amd64.deb

# ------------------------------------------------- python3-opensnitch-ui-dev
echo "==> package python3-opensnitch-ui-dev"
U=$B/pkg-ui
install -d $U/usr/lib/opensnitch-ui-dev
rsync -a --exclude tests --exclude '__pycache__' --exclude '*.pyc' \
    /src/ui/opensnitch $U/usr/lib/opensnitch-ui-dev/
install -D -m 0755 /src/ui/bin/opensnitch-ui $U/usr/bin/opensnitch-ui-dev
install -D -m 0644 /kit/pkg/opensnitch_ui_dev.desktop $U/usr/share/applications/opensnitch_ui_dev.desktop
install -D -m 0644 /src/ui/resources/icons/opensnitch-ui.svg \
    $U/usr/share/icons/hicolor/scalable/apps/opensnitch-ui-dev.svg
for s in 48x48 64x64; do
    install -D -m 0644 /src/ui/resources/icons/$s/opensnitch-ui.png \
        $U/usr/share/icons/hicolor/$s/apps/opensnitch-ui-dev.png
done
install -D -m 0644 /src/utils/packaging/ui/deb/debian/copyright \
    $U/usr/share/doc/python3-opensnitch-ui-dev/copyright
install -d $U/DEBIAN
install -m 0755 /kit/pkg/ui.postinst $U/DEBIAN/postinst
install -m 0755 /kit/pkg/ui.prerm    $U/DEBIAN/prerm
install -m 0755 /kit/pkg/ui.postrm   $U/DEBIAN/postrm
size=$(du -sk --exclude=DEBIAN $U | cut -f1)
cat > $U/DEBIAN/control <<EOF
Package: python3-opensnitch-ui-dev
Version: $VERSION
Architecture: all
Maintainer: $MAINT
Installed-Size: $size
Depends: netbase, pyqt6-dev-tools, libqt6sql6, libqt6sql6-sqlite, python3:any,
 python3-six, python3-pyqt6, python3-pyqt6.qtsvg, python3-pyinotify,
 python3-grpcio, python3-protobuf, python3-packaging, python3-slugify,
 python3-notify2, xdg-user-dirs, gtk-update-icon-cache
Recommends: opensnitch-dev, python3-pyasn
Section: net
Priority: optional
Homepage: https://github.com/evilsocket/opensnitch
Description: OpenSnitch GUI, development build with port scan detection
 Development build of the OpenSnitch GUI, with the port scan alerts, block
 prompts and the Port scan Detection tab. It installs beside the official
 python3-opensnitch-ui without sharing any file: command opensnitch-ui-dev,
 Python package in /usr/lib/opensnitch-ui-dev, settings in
 ~/.config/opensnitch-dev, socket /tmp/osui-dev.sock. It is not started
 automatically at login.
EOF
dpkg-deb --root-owner-group -Zxz --build $U /out/python3-opensnitch-ui-dev_${VERSION}_all.deb

echo "==> contents check: no path of the official packages"
for d in /out/*.deb; do
    if dpkg-deb -c "$d" | awk '{print $6}' | grep -E '^\./(usr/bin/opensnitchd$|usr/bin/opensnitch-ui$|etc/opensnitchd/|usr/lib/opensnitchd/|(usr/)?lib/systemd/system/opensnitch\.service$|etc/logrotate\.d/opensnitch$|usr/share/applications/opensnitch_ui\.desktop$|usr/share/icons/.*/opensnitch-ui\.(svg|png)$|usr/lib/python3/dist-packages/opensnitch)' ; then
        echo "COLLISION in $d" >&2; exit 1
    fi
done
ls -l /out
