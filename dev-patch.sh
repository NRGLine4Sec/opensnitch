#!/usr/bin/env bash
#
# Turns an exported copy of portscan-upstream into the "-dev" build, which
# installs beside the official Debian packages without touching anything of
# theirs. Applied to a throwaway copy only: nothing here is meant upstream.
#
#   binary        opensnitchd            -> opensnitchd-dev
#   configuration /etc/opensnitchd       -> /etc/opensnitchd-dev
#   eBPF modules  /usr/lib/opensnitchd   -> /usr/lib/opensnitchd-dev
#   log           /var/log/opensnitchd.log -> /var/log/opensnitchd-dev.log
#   GUI socket    .../osui.sock          -> .../osui-dev.sock
#   GUI settings  QSettings("opensnitch") and ~/.config/opensnitch/ -> opensnitch-dev
#   GUI instance  io.github.evilsocket.opensnitch -> ...opensnitch-dev
#   desktop file  opensnitch_ui.desktop  -> opensnitch_ui_dev.desktop
#                 (and the "opensnitch_ui" desktop name it announces)
#   GUI plugins   os.path.join(..., "opensnitch", "actions"|"list_subscriptions")
#                 -> "opensnitch-dev"
#
# Usage: dev-patch.sh <exported source tree>   (run once per fresh export)
set -euo pipefail
SRC=${1:?usage: dev-patch.sh <source tree>}
cd "$SRC"

if [ -e .dev-patched ]; then
    echo "dev-patch: $SRC is already patched" >&2
    exit 1
fi

# --- daemon: every non-test Go file and the shipped data files
mapfile -t daemon_files < <(find daemon -name '*.go' ! -name '*_test.go' ! -path '*/testdata/*'; \
                            find daemon/data -type f -name '*.json')
# Paths are also built by concatenation ("/usr/lib" + "/opensnitchd/ebpf"),
# so every "opensnitchd/" is renamed, then the bare directory names.
DIRS='s#opensnitchd/#opensnitchd-dev/#g; s#\(/etc\|/usr/lib\|/usr/local/lib\)/opensnitchd\([^-/]\|$\)#\1/opensnitchd-dev\2#g'
sed -i \
    -e "$DIRS" \
    -e 's#/var/log/opensnitchd\.log#/var/log/opensnitchd-dev.log#g' \
    -e 's#osui\.sock#osui-dev.sock#g' \
    "${daemon_files[@]}"

# The feature is what this build is for: switch detection on, policy "ask".
python3 - daemon/data/default-config.json <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["PortScan"] = {"Enabled": True}
json.dump(c, open(p, "w"), indent=4)
open(p, "a").write("\n")
EOF

# --- GUI: Python sources, the launcher and the Qt forms
mapfile -t ui_files < <(find ui/opensnitch -type f \( -name '*.py' -o -name '*.ui' \) ! -path '*/tests/*'; \
                        echo ui/bin/opensnitch-ui)
sed -i \
    -e "$DIRS" \
    -e 's#osui\.sock#osui-dev.sock#g' \
    -e 's#QSettings("opensnitch",#QSettings("opensnitch-dev",#g' \
    -e 's#\.config/opensnitch/#.config/opensnitch-dev/#g' \
    -e 's#"/opensnitch/actions/#"/opensnitch-dev/actions/#g' \
    -e 's#opensnitch_ui\.desktop#opensnitch_ui_dev.desktop#g' \
    -e 's#"opensnitch_ui"#"opensnitch_ui_dev"#g' \
    -e 's#"opensnitch", "\(actions\|list_subscriptions\)"#"opensnitch-dev", "\1"#g' \
    -e 's#/var/log/opensnitchd\.log#/var/log/opensnitchd-dev.log#g' \
    -e 's#"io\.github\.evilsocket\.opensnitch"#"io.github.evilsocket.opensnitch-dev"#g' \
    "${ui_files[@]}"

# The launcher imports its package from /usr/lib/opensnitch-ui-dev, ahead of
# the official python3-opensnitch-ui in dist-packages.
python3 - ui/bin/opensnitch-ui <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "import sys\n"
assert anchor in s, "no 'import sys' line in the launcher"
s = s.replace(anchor, anchor + "sys.path.insert(0, '/usr/lib/opensnitch-ui-dev')\n", 1)
open(p, "w").write(s)
EOF

# Checks: nothing of the official paths may remain in what gets installed.
left=$(grep -rnE 'opensnitchd/|/opensnitchd("|$)|[^-]osui\.sock|QSettings\("opensnitch",|"/opensnitch/actions|\.config/opensnitch/|"opensnitch", *"(actions|list_subscriptions)"|opensnitchd\.log|"opensnitch_ui"' \
        "${daemon_files[@]}" "${ui_files[@]}" | grep -v '^\s*//' || true)
if [ -n "$left" ]; then
    echo "dev-patch: official paths left:" >&2
    echo "$left" >&2
    exit 1
fi
touch .dev-patched
echo "dev-patch: $SRC patched (${#daemon_files[@]} daemon files, ${#ui_files[@]} GUI files)"
