# OpenSnitch with inbound port scan detection: Debian packages

Ready-to-install Debian 13 (trixie, amd64) packages of the OpenSnitch port
scan detection branch, and the script that builds them. They are meant for
trying the feature before it is reviewed upstream; they are not an official
OpenSnitch release.

The feature itself is described in the project wiki pages
"Port Scan Detection" (what it does, how to turn it on), "Settings",
"Limits" and "Internals".

## What gets installed

Two packages, which install **beside** the official `opensnitch` and
`python3-opensnitch-ui` packages without sharing a single file with them:

| | official | this build |
|---|---|---|
| daemon | `opensnitchd` | `opensnitchd-dev` |
| configuration | `/etc/opensnitchd/` | `/etc/opensnitchd-dev/` (port scan detection on, policy `ask`) |
| eBPF modules | `/usr/lib/opensnitchd/ebpf/` | `/usr/lib/opensnitchd-dev/ebpf/` |
| service | `opensnitch.service` | `opensnitch-dev.service` |
| log | `/var/log/opensnitchd.log` | `/var/log/opensnitchd-dev.log` |
| GUI | `opensnitch-ui`, `~/.config/opensnitch/` | `opensnitch-ui-dev`, `~/.config/opensnitch-dev/` |
| GUI socket | `/tmp/osui.sock` | `/tmp/osui-dev.sock` |

The two daemons drive the same netfilter queue, so `opensnitch-dev.service`
conflicts with `opensnitch.service`: starting one stops the other. Your
official configuration and rules are never read or modified.

## Installing the prebuilt packages

Download the two `.deb` files and the `SHA256SUMS-*` file of a release, then
(the file names on a release use dots where the package version has `~` and
`+`, which GitHub renames; apt shows the real version):

```sh
sha256sum -c SHA256SUMS-*
sudo apt install ./opensnitch-dev_*_amd64.deb ./python3-opensnitch-ui-dev_*_all.deb
```

The service is neither enabled nor started on install. To use this build:

```sh
sudo systemctl disable --now opensnitch.service   # if the official one runs
sudo systemctl enable --now opensnitch-dev.service
opensnitch-ui-dev &
```

The **Port scan Detection** tab of the main window lists the detected and
blocked sources.

To go back to the official packages:

```sh
sudo systemctl disable --now opensnitch-dev.service
sudo systemctl enable --now opensnitch.service
sudo apt purge opensnitch-dev python3-opensnitch-ui-dev   # optional
```

Removing the packages stops `opensnitch-dev`, which deletes its port scan
nftables table as it stops, and leaves the official installation as it is.
Rules you created in `/etc/opensnitchd-dev/rules` survive a purge, since they
are your data.

These packages are not signed, and the daemon runs as root. Check the
checksums against the release page, or build them yourself (below) from the
tagged commit the release names.

## Checking that detection works on your machine

The `portscan-upstream` branch of the fork ships
`utils/scripts/portscan-real-condition-test.sh`, which runs
real nmap scans against this machine from a throwaway network namespace,
without sending anything on your network, and compares what the daemon
reports with what the documentation expects. It reads
`/var/log/opensnitchd-dev.log` when it is the most recently written log.

```sh
sudo apt install nmap
sudo ./portscan-real-condition-test.sh -m quick 10.99.0.1
```

See `--help` and the "Verifying" wiki page for the choice of target address
and the other modes.

## Kernels

* The port scan detection eBPF program reads no kernel-internal structure:
  one object works on every kernel from 6.6 on (TCX attachment). On an older
  kernel the daemon falls back to its AF_PACKET source, says so, and still
  detects, at a higher CPU cost.
* OpenSnitch's own eBPF modules (process monitor, DNS) read kernel structures
  and are built against the headers of one Debian kernel, 7.2.6 from
  trixie-backports by default.

The packages, with OpenSnitch's modules built for 7.2.6, were installed and
exercised in a Debian 13 virtual machine. The installation test covers
coexistence with the official packages, detection of a real nmap scan,
blocking, the details and history of the GUI, and purge; the attribution
test requires the eBPF process monitor itself to attribute TCP and UDP,
IPv4 and IPv6 connections to the right process and program.

| kernel | installation | attribution | upgrade from the previous build |
|---|---|---|---|
| 7.2.6 (trixie-backports, the build target) | passed | passed | passed |
| 7.0.13 (trixie-backports) | passed | passed | not run |
| 6.12.107 (trixie) | passed | passed | not run |

## Building the packages yourself

Requirements on the host: `git`, and `docker` (with its daemon running) or
`podman`. Everything else happens in a `golang:1.25-trixie` container, which
needs network access (Debian packages, Go modules, and the kernel headers
from snapshot.debian.org).

```sh
./build.sh                                    # the portscan-upstream branch of the fork
./build.sh --ref <tag>                         # a given release
./build.sh --repo /path/to/opensnitch --ref portscan-upstream   # a local clone
```

`--kernel` is the Debian kernel OpenSnitch's own eBPF modules are built for
(its `linux-headers-<kernel>` package is installed from trixie-backports, or
from trixie when backports does not have it), and `--snapshot` a
snapshot.debian.org timestamp at which those headers were published:
trixie-backports keeps only its latest kernel. Only 7.2.6 has been tested. The packages go to
`./out`, with a `SHA256SUMS-<version>` file. Given the same commit, kernel and
snapshot, the build is reproducible: the package contents come out identical.

What the build does, in the container:

1. applies `dev-patch.sh` to an exported copy of the source: it renames
   every path, socket, setting and desktop entry so the packages install
   beside the official ones, and switches port scan detection on in the
   shipped configuration. The repository itself is never modified;
2. generates the Go gRPC bindings, which git does not track;
3. builds the daemon, OpenSnitch's eBPF modules for the chosen kernel, the
   port scan eBPF module, and the GUI translations;
4. assembles the two packages from `pkg/` (maintainer scripts, service,
   logrotate, desktop entry) and checks that none of their paths belongs to
   the official packages.

The headers of kernel 7.2 refuse to be included without `CC_USING_FENTRY`
when the function tracer is configured, and OpenSnitch's eBPF Makefile does
not define it yet; the build defines it for those modules. It only guards the
ftrace call-site macros, which an eBPF program does not use.

## License

OpenSnitch is distributed under the GNU General Public License v3. The source
of every prebuilt package is the commit its version names
(`...~dev+portscan.<n>.g<commit>`), published in the fork.
