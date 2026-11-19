#!/bin/sh
# Terminus: add your own machine as a node (v0.33.2). Version 0.33.2.
#
# The app's line downloads this script by its versioned URL, checks its SHA-256 and runs it:
#   TERMINUS_JOIN=<code> sh terminus-install.sh --instance <https://your.instance> [--yes] [--model <value>] [-- <model flags>]
# (`--join <code>` is accepted too, for a code typed by hand, but other local users can read a process's arguments.)
# `terminus-node update` runs it as `sh install.sh --update`: the saved instance, credential, settings and key are kept.
# Compare that SHA-256 with the public README of ProjectTerminusOrg/get.projectterminus.org: it is the one check that
# does not come from the instance.
#
# What it does: checks this machine; asks before using sudo and before installing Apptainer or dbus-user-session (the
# user's session bus); creates the user terminus-node (lingering on, its session bus started) and
# /opt/terminus-node/<version> with a `current` link; installs uv, Python, the node's
# requirements (--require-hashes) and its wheel, every download checked by the SHA-256 pinned below before it is used;
# then, as terminus-node, runs `terminus-node setup` (the checks and the join), installs and starts the node's system
# unit, and runs `terminus-node setup --model`. Run again with the same version, it resumes: what is done is skipped.
#
# The join code is used once, never printed or written to a file, and never in a process's arguments (when it comes
# from the environment or the prompt): setup reads it on its standard input. Every command as terminus-node runs in a
# session of its own, without the caller's terminal as its controlling terminal. A model key never passes through
# this script: give setup a key file's path (after `--`), never the key.
#
# This file is rendered by scripts/render_install.py from deploy/get/install.sh.in; edit the template, not a copy.
set -eu
set +x
# The app's line gives the join code in the environment (TERMINUS_JOIN), where other local users cannot read it as
# they can a process's arguments: kept in a variable of this shell's own (never exported) and unset at once, so no
# command this script runs inherits it.
unset JOIN
JOIN=${TERMINUS_JOIN:-}
unset TERMINUS_JOIN
umask 022
# uv runs as root here; no variable of the caller's may change what it trusts (UV_PYTHON_DOWNLOADS_JSON_URL would
# replace the table of Python's digests). sudo drops them; a run as root would not.
for uv_variable in $(env | sed -n 's/^\(UV_[A-Za-z0-9_]*\)=.*/\1/p'); do
    printf 'Note: %s is set in this environment and is ignored.\n' "$uv_variable"
    unset "$uv_variable"
done

# --- pinned by the release (rendered) ---------------------------------------------------------------------------------
VERSION='0.33.2'
WHEEL_NAME='terminus_node-0.33.2-py3-none-any.whl'
WHEEL_SHA256='328378d0c828093c09ae30faa2ced9ca0173218ff5cb9cf87e228da25fff6cd8'
REQUIREMENTS_NAME='terminus_node-0.33.2-requirements.txt'
REQUIREMENTS_SHA256='6fb9d19c37f7e30b540fb6d91e733393df164c7f27a76892ba74afcf6534d7b9'
IMAGE_PREFLIGHT='96d7d71313486dc303c8c42518f8fe5c5af4bcb69e3b36ed40d081e08529022f'
IMAGE_COMPUTE='f5dc23de51880c4090f896c305348d1dae373cd44f16eb200c6650904e645800'
IMAGE_AGENT='1729ade7af36f9cc6949ef87362d86e7c242b274b7cda8e8e78ce81b1b321e22'
REGISTRY_HOST='ghcr.io'
REPOSITORY='projectterminusorg/terminus-node'
REGISTRY_PREFIX='projectterminusorg'
UV_VERSION='0.12.5'
UV_URL='https://github.com/astral-sh/uv/releases/download/0.12.5/uv-x86_64-unknown-linux-gnu.tar.gz'
UV_SHA256='68a509da24b06b4223a1c0175fb5eb5bc79342b76cbeff0cfe51ac3f5b17b6b2'
PYTHON_VERSION='3.12.14'
APPTAINER_VERSION='1.4.5'
APPTAINER_UBUNTU_2204_URL='https://github.com/apptainer/apptainer/releases/download/v1.4.5/apptainer_1.4.5_amd64.deb'
APPTAINER_UBUNTU_2204_SHA256='70f19af846501acfbc2e42e7cfeee9ee11ddbbfa1c3502d0d99cde34e8e0af05'
APPTAINER_UBUNTU_2404_URL='https://github.com/apptainer/apptainer/releases/download/v1.4.5/apptainer_1.4.5_amd64.deb'
APPTAINER_UBUNTU_2404_SHA256='70f19af846501acfbc2e42e7cfeee9ee11ddbbfa1c3502d0d99cde34e8e0af05'
APPTAINER_DEBIAN_12_URL='https://github.com/apptainer/apptainer/releases/download/v1.4.5/apptainer_1.4.5_amd64.deb'
APPTAINER_DEBIAN_12_SHA256='70f19af846501acfbc2e42e7cfeee9ee11ddbbfa1c3502d0d99cde34e8e0af05'
# --- end of the pins --------------------------------------------------------------------------------------------------

DEFAULT_INDEX='https://pypi.org/simple/'
NODE_USER='terminus-node'
# Free space on the filesystem of the node's home (final review L8): 20 GiB while any of this version's three runtime
# images is not held yet (they live there); 4 GiB once every one is (uv, Python, the node's environment, its staging).
MIN_DISK_KIB=20971520
MIN_HELD_DISK_KIB=4194304
EXIT_USAGE=2
EXIT_CODE_REFUSED=3

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
fail() {
    printf 'terminus-install: %s\n' "$*" >&2
    exit 1
}
usage_fail() {
    printf 'terminus-install: %s\n' "$*" >&2
    printf 'Usage: TERMINUS_JOIN=<code> sh terminus-install.sh --instance <https://instance> [--yes] [--model <value>] [-- <model flags>]\n' >&2
    exit "$EXIT_USAGE"
}

# --- arguments --------------------------------------------------------------------------------------------------------
# Everything after `--` is passed unchanged to `terminus-node setup --model` (after --model's value, when given).
# JOIN holds TERMINUS_JOIN's code (above); `--join` replaces it.
INSTANCE=''
ASSUME_YES=0
MODEL=''
MODEL_SET=0
UPDATE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --join)
        [ "$#" -ge 2 ] || usage_fail "--join needs the code from the app"
        JOIN=$2
        shift 2
        ;;
    --join=*)
        JOIN=${1#--join=}
        shift
        ;;
    --instance)
        [ "$#" -ge 2 ] || usage_fail "--instance needs the instance's address"
        INSTANCE=$2
        shift 2
        ;;
    --instance=*)
        INSTANCE=${1#--instance=}
        shift
        ;;
    --yes | -y)
        ASSUME_YES=1
        shift
        ;;
    --update)
        UPDATE=1
        shift
        ;;
    --model)
        [ "$#" -ge 2 ] || usage_fail "--model needs a value (none, a preset or a URL)"
        MODEL=$2
        MODEL_SET=1
        shift 2
        ;;
    --model=*)
        MODEL=${1#--model=}
        MODEL_SET=1
        shift
        ;;
    -h | --help)
        say "Usage: TERMINUS_JOIN=<code> sh terminus-install.sh --instance <https://instance> [--yes] [--model <value>] [-- <model flags>]"
        say "  --join <code>  the code by hand (other local users can see a process's arguments; the app's form or the prompt is safer)"
        say "  --yes      answer yes to every question (a run without a terminal)"
        say "  --update   install this version over this machine's node, keeping its instance, credential and key"
        say "  --model    passed to 'terminus-node setup --model' (none, or the model's preset or URL)"
        say "  -- ...     every later argument is passed unchanged to 'terminus-node setup --model'"
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        # An unknown argument is never printed: it may be a misplaced code.
        case "$1" in
        --[a-z]*) usage_fail "unknown option ${1%%=*}" ;;
        *) usage_fail "unexpected argument (not shown)" ;;
        esac
        ;;
    esac
done
# "$@" now holds the model's pass-through arguments; it is not touched again until the model step.

# --- where things go (the tests' root prefix) -------------------------------------------------------------------------
# TERMINUS_INSTALL_TEST_ROOT is for the tests only: every system path is under it. It is refused unless it is a
# directory of the (non-root) caller's own, never a system directory, and each command that acts on the system is a
# stub in its stubs/ directory, so the script can never act on the real system with it.
ROOT=${TERMINUS_INSTALL_TEST_ROOT:-}
ROOT_UID=0
if [ -n "$ROOT" ]; then
    case "$ROOT" in
    /*) ;;
    *) fail "TERMINUS_INSTALL_TEST_ROOT must be an absolute path" ;;
    esac
    case "$ROOT" in
    */./* | */../* | */. | */.. | *//*) fail "TERMINUS_INSTALL_TEST_ROOT must be a plain absolute path" ;;
    esac
    while :; do
        case "$ROOT" in
        */) ROOT=${ROOT%/} ;;
        *) break ;;
        esac
    done
    case "$ROOT" in
    '' | /bin | /boot | /dev | /etc | /etc/* | /home | /lib | /lib32 | /lib64 | /media | /mnt | /opt | /opt/* | /proc \
        | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /usr/* | /var | /var/lib | /var/lib/*)
        fail "TERMINUS_INSTALL_TEST_ROOT is a test's own directory, never a system directory"
        ;;
    esac
    if [ -O / ]; then
        fail "TERMINUS_INSTALL_TEST_ROOT is for the tests, never for root"
    fi
    if [ ! -d "$ROOT" ] || [ -L "$ROOT" ] || [ ! -O "$ROOT" ]; then
        fail "TERMINUS_INSTALL_TEST_ROOT must be a directory of the caller's own"
    fi
    for stubbed in sudo runuser id uname getent systemctl loginctl useradd usermod dpkg dpkg-query apt-get df; do
        found=$(command -v "$stubbed" 2>/dev/null || true)
        case "$found" in
        "$ROOT"/stubs/*) ;;
        *) fail "TERMINUS_INSTALL_TEST_ROOT is for the tests only, and '$stubbed' is not a test stub under it" ;;
        esac
    done
    # The tests' stand-in for root's uid (their files belong to the caller).
    ROOT_UID=$(id -u root)
    NODE_PATH=$PATH
    ROOT_PATH=$PATH
else
    NODE_PATH=/usr/local/bin:/usr/bin:/bin
    ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fi
OPT="$ROOT/opt/terminus-node"
VENV="$OPT/$VERSION"
NODE_BIN="$OPT/current/bin/terminus-node"
UV_DIR="$OPT/uv/$UV_VERSION"
UNIT_PATH="$ROOT/etc/systemd/system/terminus-node.service"
APPTAINER="$ROOT/usr/bin/apptainer"
EVENT_NODE_STATE="$ROOT/var/lib/terminus-node"

IS_ROOT=0
run_root() {
    # As root, a fixed environment of its own (as sudo's env_reset gives): no variable of the caller's reaches root's
    # commands; each command adds what it needs (env NAME=value ...).
    if [ "$IS_ROOT" = 1 ]; then
        env -i PATH="$ROOT_PATH" LANG=C.UTF-8 HOME="$ROOT/root" "$@"
    else
        sudo -- "$@"
    fi
}
WORK=''
STAGE=''
cleanup() {
    stty echo 2>/dev/null || true
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
    if [ -n "$STAGE" ]; then run_root rm -rf "$STAGE" || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# The caller's own private directory: every download, the unit and the CA's copy are checked here before root uses them.
WORK=$(mktemp -d)

pem_certificates_only() {
    # pem_certificates_only <file>: one or more PEM certificates, and no other PEM block (no private key).
    LC_ALL=C awk '
        /^-----BEGIN CERTIFICATE-----$/ { if (inside) bad = 1; inside = 1; count++; next }
        /^-----END CERTIFICATE-----$/ { if (!inside) bad = 1; inside = 0; next }
        inside { if ($0 !~ /^[A-Za-z0-9+\/=]*$/) bad = 1; next }
        /^-----/ { bad = 1 }
        END { exit (bad || inside || count == 0) }
    ' "$1"
}

# --- the live session's overrides (the digests never change with them) ------------------------------------------------
REGISTRY=$REGISTRY_HOST
INDEX=$DEFAULT_INDEX
CA_BUNDLE=''
if [ -n "${TERMINUS_INSTALL_REGISTRY:-}" ]; then
    case "$TERMINUS_INSTALL_REGISTRY" in
    *[!A-Za-z0-9.:-]* | '' | :* | *: ) fail "TERMINUS_INSTALL_REGISTRY is a registry host (host or host:port)" ;;
    esac
    REGISTRY=$TERMINUS_INSTALL_REGISTRY
    say "Note: TERMINUS_INSTALL_REGISTRY is set: the node's files and images come from $REGISTRY (the digests are unchanged)."
fi
if [ -n "${TERMINUS_INSTALL_INDEX:-}" ]; then
    case "$TERMINUS_INSTALL_INDEX" in
    https://*) ;;
    *) fail "TERMINUS_INSTALL_INDEX must be an https:// address" ;;
    esac
    case "$TERMINUS_INSTALL_INDEX" in
    *[!A-Za-z0-9.:/_~%+-]*) fail "TERMINUS_INSTALL_INDEX holds a character an index address does not" ;;
    esac
    INDEX=$TERMINUS_INSTALL_INDEX
    say "Note: TERMINUS_INSTALL_INDEX is set: the requirements come from $INDEX (their hashes are unchanged)."
fi
if [ -n "${TERMINUS_INSTALL_CA_BUNDLE:-}" ]; then
    case "$TERMINUS_INSTALL_CA_BUNDLE" in
    /*) ;;
    *) fail "TERMINUS_INSTALL_CA_BUNDLE must be an absolute path" ;;
    esac
    # Copied once, as the caller, and checked: root later copies this private copy, never the caller's path.
    if [ ! -f "$TERMINUS_INSTALL_CA_BUNDLE" ] || ! cp -- "$TERMINUS_INSTALL_CA_BUNDLE" "$WORK/ca.pem" 2>/dev/null; then
        fail "TERMINUS_INSTALL_CA_BUNDLE names no readable file"
    fi
    pem_certificates_only "$WORK/ca.pem" \
        || fail "TERMINUS_INSTALL_CA_BUNDLE must hold PEM certificates only (no private key, no other block)"
    CA_BUNDLE="$WORK/ca.pem"
    say "Note: TERMINUS_INSTALL_CA_BUNDLE is set: the instance, the registry and an overridden index are checked against it."
fi

# --- the instance and the code ----------------------------------------------------------------------------------------
check_instance() {
    case "$INSTANCE" in
    https://*) ;;
    *) usage_fail "--instance must be the instance's https:// address" ;;
    esac
    case "$INSTANCE" in
    *[!A-Za-z0-9.:/_-]*) usage_fail "--instance holds a character an instance's address does not" ;;
    esac
    while :; do
        case "$INSTANCE" in
        */) INSTANCE=${INSTANCE%/} ;;
        *) break ;;
        esac
    done
}
if [ "$UPDATE" = 1 ]; then
    # Update mode reads the saved instance itself and keeps the credential: no code, no instance, no model step.
    [ -z "$JOIN" ] || usage_fail "--update takes no join code: the node keeps its credential"
    [ -z "$INSTANCE" ] || usage_fail "--update takes no --instance: it reads the node's saved instance"
    [ "$MODEL_SET" = 0 ] && [ "$#" = 0 ] || usage_fail "--update keeps the node's model: run terminus-node setup --model for another"
else
    [ -n "$INSTANCE" ] || usage_fail "--instance is required (the app's line names it)"
    check_instance
fi
if [ -n "$JOIN" ]; then
    case "$JOIN" in
    *[!A-Za-z0-9._~-]*) usage_fail "the join code is malformed (it is not shown); copy the app's line again" ;;
    esac
    [ "${#JOIN}" -le 256 ] || usage_fail "the join code is malformed (it is not shown); copy the app's line again"
fi

ask() {
    # ask <question>: yes with --yes; otherwise the terminal's answer; without a terminal, stop.
    if [ "$ASSUME_YES" = 1 ]; then
        say "$1 yes (--yes)"
        return 0
    fi
    [ -t 0 ] || fail "$1 There is no terminal to answer on: run again with --yes."
    printf '%s [y/N] ' "$1"
    answer=''
    read -r answer || answer=''
    case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
    esac
}

# --- helpers ----------------------------------------------------------------------------------------------------------
as_node_reading() {
    # The node's user, with a clean environment of its own (no variable of the caller's leaks into it), in a session of
    # its own (setsid -w: no controlling terminal, so it can neither open /dev/tty nor push keys into the caller's
    # terminal with TIOCSTI; -w keeps its exit status). Leading NAME=value arguments are added to that environment (env
    # reads them). Its standard input is the caller's: the code's pipe, or the person's terminal for the model step.
    if [ "$IS_ROOT" = 1 ]; then
        runuser -u "$NODE_USER" -- setsid -w env -i HOME="$NODE_HOME" XDG_RUNTIME_DIR="/run/user/$NODE_UID" \
            PATH="$NODE_PATH" LANG=C.UTF-8 TERM="${TERM:-dumb}" "$@"
    else
        sudo -u "$NODE_USER" -- setsid -w env -i HOME="$NODE_HOME" XDG_RUNTIME_DIR="/run/user/$NODE_UID" \
            PATH="$NODE_PATH" LANG=C.UTF-8 TERM="${TERM:-dumb}" "$@"
    fi
}
as_node() {
    # as_node_reading, reading nothing: its standard input is /dev/null.
    as_node_reading "$@" </dev/null
}
sha256_of() { sha256sum "$1" | cut -d ' ' -f 1; }
check_digest() {
    # check_digest <file> <pinned sha256> <what>: stop on a mismatch (the file is removed; nothing falls back).
    actual=$(sha256_of "$1")
    if [ "$actual" != "$2" ]; then
        rm -f "$1"
        fail "$3 does not match its pinned SHA-256 (pinned $2, got $actual). Nothing more is installed; nothing falls back to an unchecked download."
    fi
}
fetch_pinned() {
    # fetch_pinned <url> <file> <sha256> <what>: a GitHub release file, checked against the system's CAs.
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 --retry 3 -o "$2" "$1" \
        || fail "could not download $4 from $1"
    check_digest "$2" "$3" "$4"
}
curl_overridable() {
    # curl for the instance, the registry and an overridden index: the live session's CA when one is set.
    if [ -n "$CA_BUNDLE" ]; then
        curl --cacert "$CA_BUNDLE" "$@"
    else
        curl "$@"
    fi
}
REGISTRY_HEADER=''
registry_token() {
    # The registry's anonymous bearer token for pulling the node's repository, always from its fixed /token (never
    # from a realm a challenge names).
    token_json="$WORK/token.json"
    curl_overridable -fsS --proto '=https' --tlsv1.2 --max-time 60 -o "$token_json" \
        "https://$REGISTRY/token?scope=repository:$REPOSITORY:pull&service=$REGISTRY" \
        || fail "the registry $REGISTRY gave no token for $REPOSITORY"
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$token_json" | head -n 1)
    rm -f "$token_json"
    [ -n "$token" ] || fail "the registry $REGISTRY's token answer holds no token"
    # The header goes in a file (curl -H @file), so the token is never in an argument.
    REGISTRY_HEADER="$WORK/authorization"
    (
        umask 077
        printf 'Authorization: Bearer %s\n' "$token" >"$REGISTRY_HEADER"
    )
    token=''
}
fetch_blob() {
    # fetch_blob <sha256> <file> <what>: a blob of the node's ORAS artifact (its digest is its file's SHA-256),
    # following the registry's redirect. First without a token: a registry that issues none (the live session's)
    # serves it; GHCR answers 401 with a Bearer challenge, and the blob is fetched again with its token.
    blob_url="https://$REGISTRY/v2/$REPOSITORY/blobs/sha256:$1"
    if [ -z "$REGISTRY_HEADER" ]; then
        code=$(curl_overridable -sSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 --retry 3 \
            -D "$WORK/headers" -o "$2" -w '%{http_code}' "$blob_url") \
            || fail "could not download $3 from $REGISTRY"
        case "$code" in
        200)
            rm -f "$WORK/headers"
            check_digest "$2" "$1" "$3"
            return 0
            ;;
        401)
            LC_ALL=C grep -qi '^www-authenticate:[[:space:]]*bearer' "$WORK/headers" \
                || fail "the registry $REGISTRY refused $3 without a bearer challenge (HTTP 401)"
            rm -f "$2" "$WORK/headers"
            registry_token
            ;;
        *)
            rm -f "$2" "$WORK/headers"
            fail "the registry $REGISTRY answered HTTP $code for $3"
            ;;
        esac
    fi
    curl_overridable -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 --retry 3 \
        -H "@$REGISTRY_HEADER" -o "$2" "$blob_url" \
        || fail "could not download $3 from $REGISTRY"
    check_digest "$2" "$1" "$3"
}
reachable() {
    # reachable <url> <name> [overridable]: any HTTP answer counts. A HEAD request, so no body is read: the package
    # index's /simple/ is PyPI's whole list of projects (about 49 MB), past 20 seconds on a slower line.
    if [ "${3:-}" = overridable ]; then
        curl_overridable -sS --proto '=https' --head --max-time 20 -o /dev/null "$1" 2>/dev/null \
            || fail "this machine cannot reach $2 ($1); check its network and proxy"
    else
        curl -sS --proto '=https' --head --max-time 20 -o /dev/null "$1" 2>/dev/null \
            || fail "this machine cannot reach $2 ($1); check its network and proxy"
    fi
}
url_origin() { printf '%s\n' "$1" | sed -n 's#^\(https://[^/]*\).*#\1/#p'; }
os_field() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$ROOT/etc/os-release" | head -n 1; }
dbus_user_session_ok() {
    # The package that gives a user's systemd its session bus (dbus.socket, /run/user/<uid>/bus).
    [ "$(dpkg-query -W -f='${Status}' dbus-user-session 2>/dev/null || true)" = 'install ok installed' ]
}
apptainer_ok() {
    [ -x "$APPTAINER" ] || return 1
    found_version=$("$APPTAINER" --version 2>/dev/null | awk '{ print $NF }')
    printf '%s\n' "$found_version" | awk -F. '{ exit !($1 > 1 || ($1 == 1 && $2 + 0 >= 3)) }'
}
untrusted_in() {
    # untrusted_in <dir> [shallow]: the first path under <dir> (or <dir> itself) that root does not own or that a user
    # other than root may write (links aside: their mode means nothing), or the reason <dir> is no real directory;
    # empty when root alone controls it. Root runs find, so no directory is hidden from it.
    if [ -L "$1" ] || [ ! -d "$1" ]; then
        printf '%s is not a directory (a link?)\n' "$1"
        return 0
    fi
    if [ "${2:-}" = shallow ]; then
        run_root find "$1" -maxdepth 0 \( ! -user "$ROOT_UID" -o ! -type l -perm /022 \) -print -quit \
            || printf '%s could not be read\n' "$1"
    else
        run_root find "$1" \( ! -user "$ROOT_UID" -o ! -type l -perm /022 \) -print -quit \
            || printf '%s could not be read\n' "$1"
    fi
}
MODEL_LOCK_DIRECTORY=/run/lock
expected_unit() {
    # The system unit backend/node/setup.py's unit_text writes for this node (hardened, as the node's user, this
    # version's node), rebuilt from what root knows: the node's uid and home, its settings file and $VENV. Comments and
    # blank lines are left out. The bare ReadWritePaths= stands alone: its paths are the one part the node's settings
    # shape; the one before it, the node user's runtime directory (cgroup limits), is fixed by the uid and exact.
    printf '%s\n' '[Unit]' 'Description=Terminus node' \
        "Wants=network-online.target user@$NODE_UID.service" "After=network-online.target user@$NODE_UID.service" \
        '[Service]' 'Type=simple' "User=$NODE_USER" "Group=$NODE_USER" "Environment=HOME=$NODE_HOME" \
        "Environment=XDG_RUNTIME_DIR=/run/user/$NODE_UID" \
        "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$NODE_UID/bus" \
        'Environment=LANG=C.UTF-8' 'Environment=PATH=/usr/local/bin:/usr/bin:/bin' \
        "Environment=TERMINUS_NODE_SETTINGS_FILE=$PERSONAL_SETTINGS" "ExecStart=$VENV/bin/terminus-node run" \
        'KillMode=process' 'TimeoutStopSec=60' 'Restart=on-failure' 'RestartSec=10' \
        'RestartPreventExitStatus=1 2 3 5' 'UMask=0077' 'NoNewPrivileges=yes' 'Delegate=yes' 'PrivateTmp=yes' \
        'ProtectSystem=strict' 'ProtectHome=read-only' "ReadWritePaths=-/run/user/$NODE_UID" 'ReadWritePaths=' \
        '[Install]' 'WantedBy=multi-user.target'
}
check_unit() {
    # check_unit <file>: the unit root installs, checked as the caller. The node's user shapes part of this text
    # through its own settings, and PID 1 reads it as root, so it must be exactly the unit expected_unit rebuilds, line
    # for line (comments and blank lines aside), with no control character and no backslash (a continuation) anywhere.
    # Only ReadWritePaths='s values may differ (the node's state directory, executor root and image directory, and the
    # model-server lock's directory: the settings' paths): each is "-" and an absolute path of plain characters (no
    # "%" specifier, no "." or ".." component) under the node's home, or the default lock's directory, /run/lock.
    expected_unit >"$WORK/terminus-node.expected" || return 1
    CHECK_HOME="$NODE_HOME" CHECK_LOCK="$MODEL_LOCK_DIRECTORY" LC_ALL=C awk '
        function refuse(why) { if (bad == "") bad = why; exit 1 }
        function plain_path(path) {
            if (path !~ /^\/[A-Za-z0-9._@+\/-]*$/ || path ~ /\/\// || path ~ /\/\.\.?(\/|$)/ || path ~ /\/$/) return 0
            return path == ENVIRON["CHECK_LOCK"] || index(path, ENVIRON["CHECK_HOME"] "/") == 1
        }
        FNR == NR { wanted[++wants] = $0; next }
        /[[:cntrl:]]/ { refuse("a control character on line " FNR) }
        /\\/ { refuse("a backslash on line " FNR) }
        /^$/ || /^[#;]/ { next }
        {
            if (++n > wants) refuse("line " FNR " is a line more than the node writes")
            if (wanted[n] == "ReadWritePaths=") {
                if (index($0, "ReadWritePaths=") != 1) refuse("line " FNR " is not the node'\''s ReadWritePaths=")
                count = split(substr($0, 16), paths, " ")
                if (count < 1 || $0 ~ /= | $|  /) refuse("line " FNR " is not a plain list of paths")
                for (i = 1; i <= count; i++)
                    if (substr(paths[i], 1, 1) != "-" || !plain_path(substr(paths[i], 2)))
                        refuse("ReadWritePaths= on line " FNR " names a path outside the node'\''s home")
                next
            }
            if ($0 != wanted[n]) refuse("line " FNR " is not the node'\''s own (it writes \"" wanted[n] "\" there)")
        }
        END {
            if (bad == "" && n != wants) bad = "the unit lacks the node'\''s line \"" wanted[n + 1] "\""
            if (bad != "") { print bad; exit 1 }
        }
    ' "$WORK/terminus-node.expected" "$1"
}

# --- 1. this machine --------------------------------------------------------------------------------------------------
step "1. Checking this machine"
if [ "$UPDATE" = 1 ]; then
    say "This updates this machine's Terminus node to $VERSION, keeping its instance, credential, settings and key."
else
    say "This installs Terminus's node $VERSION for $INSTANCE: Apptainer if needed, the user $NODE_USER, the node in"
    say "/opt/terminus-node/$VERSION, and its system service. Every download is checked by a pinned SHA-256."
fi
[ "$(uname -s)" = Linux ] || fail "the node runs on Linux only"
[ "$(uname -m)" = x86_64 ] || fail "the runtime images are for x86_64 only; this machine is $(uname -m)"
[ -r "$ROOT/etc/os-release" ] || fail "cannot read /etc/os-release to tell the distribution"
DISTRO="$(os_field ID)-$(os_field VERSION_ID)"
case "$DISTRO" in
ubuntu-22.04)
    APPTAINER_URL=$APPTAINER_UBUNTU_2204_URL
    APPTAINER_SHA256=$APPTAINER_UBUNTU_2204_SHA256
    ;;
ubuntu-24.04)
    APPTAINER_URL=$APPTAINER_UBUNTU_2404_URL
    APPTAINER_SHA256=$APPTAINER_UBUNTU_2404_SHA256
    ;;
debian-12)
    APPTAINER_URL=$APPTAINER_DEBIAN_12_URL
    APPTAINER_SHA256=$APPTAINER_DEBIAN_12_SHA256
    ;;
*) fail "this script supports Ubuntu 22.04 and 24.04 and Debian 12; this machine is $DISTRO" ;;
esac
say "Linux x86_64, $DISTRO."
[ -d "$ROOT/run/systemd/system" ] || fail "the node runs as a systemd service, and systemd is not running here"
# Another kind of Terminus node (an instance's own event node) keeps its state here; this script never installs over it.
if [ -e "$EVENT_NODE_STATE" ] || [ -L "$EVENT_NODE_STATE" ]; then
    fail "this machine runs another kind of Terminus node (an instance's event node: /var/lib/terminus-node), and this script does not install over it."
fi
if [ "$UPDATE" = 0 ]; then
    reachable "$INSTANCE/" "the instance" overridable
fi
reachable "https://$REGISTRY/v2/" "the registry" overridable
reachable "$(url_origin "$UV_URL")" "GitHub (uv)"
if [ "$INDEX" = "$DEFAULT_INDEX" ]; then
    reachable "$INDEX" "the Python package index"
else
    reachable "$INDEX" "the Python package index" overridable
fi
say "Network: the registry, GitHub and the package index answer."

# --- 2. sudo ----------------------------------------------------------------------------------------------------------
step "2. Permissions"
if [ "$(id -u)" = 0 ]; then
    IS_ROOT=1
    say "Running as root."
else
    if ! command -v sudo >/dev/null 2>&1; then
        fail "this script needs sudo for Apptainer, the user $NODE_USER, /opt/terminus-node and the system unit, and sudo is missing. Without sudo, an administrator must install Apptainer $APPTAINER_VERSION or newer, create the user $NODE_USER with lingering, and run this script once with sudo; a node installed wholly without sudo is not built in this version."
    fi
    ask "Use sudo for Apptainer, the user $NODE_USER, /opt/terminus-node and the system unit?" \
        || fail "stopped: no sudo. Without it, an administrator must install Apptainer $APPTAINER_VERSION or newer, create the user $NODE_USER with lingering, and run this script once with sudo."
fi

NODE_HOME=''
NODE_UID=''
STATE=''
ENROLLED=0
saved=''
saved_from=''
PERSONAL_SETTINGS=''
if id "$NODE_USER" >/dev/null 2>&1; then
    NODE_HOME=$(getent passwd "$NODE_USER" | cut -d: -f6)
    NODE_UID=$(id -u "$NODE_USER")
    [ -n "$NODE_HOME" ] || fail "the user $NODE_USER has no home directory"
    STATE="$NODE_HOME/.local/state/terminus-node"
    PERSONAL_SETTINGS="$NODE_HOME/.config/terminus-node/node.env"
    # No group but its own: sudo, docker, lxd, disk and the like would make an escape to its uid an escape to root.
    node_groups=$(id -nG "$NODE_USER")
    if [ "$node_groups" != "$NODE_USER" ]; then
        fail "the user $NODE_USER exists and is in other groups than its own ($node_groups). The node's user is in no other group: remove it from each (gpasswd -d $NODE_USER <group>) and run again."
    fi
    # A sudo that cannot run commands as the node's user would read as "no install here" below.
    as_node true || fail "cannot run commands as $NODE_USER (through sudo -u $NODE_USER); allow it and run again"
    # Another instance's install is never overwritten: the saved instance comes from the node's identity (written at
    # the join) or, before it, from its settings file.
    if as_node test -f "$STATE/node.json"; then
        saved=$(as_node cat "$STATE/node.json" \
            | sed -n 's/.*"control_plane_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        saved_from="$STATE/node.json"
    elif as_node test -f "$PERSONAL_SETTINGS"; then
        saved=$(as_node cat "$PERSONAL_SETTINGS" \
            | sed -n 's/^TERMINUS_NODE_CONTROL_PLANE_URL=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' | head -n 1)
        saved_from=$PERSONAL_SETTINGS
    fi
    while :; do
        case "$saved" in
        */) saved=${saved%/} ;;
        *) break ;;
        esac
    done
    if as_node test -f "$STATE/credential"; then
        ENROLLED=1
    fi
fi
# The system unit, when there is one, must be this personal install's: another kind of node names another settings file.
if [ -f "$UNIT_PATH" ] || [ -L "$UNIT_PATH" ]; then
    unit_settings=$(sed -n 's/^Environment=TERMINUS_NODE_SETTINGS_FILE=//p' "$UNIT_PATH" | head -n 1)
    if [ -z "$PERSONAL_SETTINGS" ] || [ "$unit_settings" != "$PERSONAL_SETTINGS" ]; then
        fail "this machine runs another kind of Terminus node: $UNIT_PATH names the settings file ${unit_settings:-(none)}, not this personal install's. This script does not install over it."
    fi
fi
if [ "$UPDATE" = 1 ]; then
    if [ -z "$saved_from" ] || [ -z "$saved" ] || [ "$ENROLLED" != 1 ]; then
        fail "there is no joined node on this machine to update (no saved instance and credential for $NODE_USER). Add the machine with the app's line instead."
    fi
    INSTANCE=$saved
    check_instance
    say "Updating the node of $INSTANCE ($saved_from)."
    reachable "$INSTANCE/" "the instance" overridable
elif [ -n "$saved_from" ]; then
    if [ "$saved" != "$INSTANCE" ]; then
        fail "this machine's node already belongs to another instance: $saved_from names ${saved:-no instance}, and this line is for $INSTANCE. Remove that install first (stop terminus-node.service and delete $STATE and $NODE_HOME/.config/terminus-node), or use that instance's line."
    fi
    say "This machine's node already belongs to $INSTANCE ($saved_from): resuming."
fi
if [ "$ENROLLED" = 1 ]; then
    say "The node already holds its credential: the join code is not needed again."
    JOIN=''
elif [ -z "$JOIN" ]; then
    [ -t 0 ] || usage_fail "the join code is required (the app's line gives it: TERMINUS_JOIN=<code>)"
    printf 'The join code from the app (it is not shown as you type): '
    stty -echo 2>/dev/null || true
    read -r JOIN || JOIN=''
    stty echo 2>/dev/null || true
    printf '\n'
    case "$JOIN" in
    '' | *[!A-Za-z0-9._~-]*) usage_fail "the join code is malformed (it is not shown); copy the app's line again" ;;
    esac
fi

images_held() {
    # Every image this version pins is held: its file is in the node's image directory and the install's record (setup
    # writes it) expects that digest. Setup still checks each image's SHA-256 before it keeps it.
    [ "$ENROLLED" = 1 ] || return 1
    expected=$(as_node cat "$STATE/install.json" 2>/dev/null | sed -n 's/.*"expected": {\([^}]*\)}.*/\1/p' | head -n 1)
    for pinned in "preflight $IMAGE_PREFLIGHT" "compute $IMAGE_COMPUTE" "agent $IMAGE_AGENT"; do
        case "$expected" in
        *"\"${pinned%% *}\": \"${pinned#* }\""*) ;;
        *) return 1 ;;
        esac
        as_node test -s "$STATE/images/runtime-${pinned%% *}.sif" || return 1
    done
}
free_kib=$(df -Pk "$ROOT/home" | awk 'NR == 2 { print $4 }')
if images_held; then
    [ "${free_kib:-0}" -ge "$MIN_HELD_DISK_KIB" ] \
        || fail "the node needs 4 GiB free where its home is (/home), its runtime images being held; there are ${free_kib:-0} KiB"
else
    [ "${free_kib:-0}" -ge "$MIN_DISK_KIB" ] \
        || fail "the node needs 20 GiB free where its home is (/home) for the runtime images; there are ${free_kib:-0} KiB"
fi
say "Disk space: enough."

# --- 3, 5. the downloads, all checked before anything is installed ----------------------------------------------------
step "3. Downloading and checking"
# /opt/terminus-node is root's alone, or nothing in it is trusted: root runs uv and Python from it, keeps what its
# markers say is installed and stages the downloads in it.
if [ -e "$OPT" ] || [ -L "$OPT" ]; then
    untrusted=$(untrusted_in "$OPT")
    if [ -n "$untrusted" ]; then
        owner=$(stat -c %U "$OPT" 2>/dev/null || printf 'unknown')
        fail "/opt/terminus-node is not root's alone (it belongs to $owner; $untrusted is not root's or others may write it): another install's layout, perhaps an instance's event node. This script does not install over it."
    fi
fi
NEED_APPTAINER=0
if apptainer_ok; then
    say "Apptainer: $("$APPTAINER" --version 2>/dev/null) (1.3 or newer), kept."
else
    if [ -x "$APPTAINER" ]; then
        say "Apptainer: $("$APPTAINER" --version 2>/dev/null) is older than 1.3."
    else
        say "Apptainer: not installed (/usr/bin/apptainer)."
    fi
    ask "Install Apptainer $APPTAINER_VERSION from its release package ($APPTAINER_URL)?" \
        || fail "stopped: the node needs Apptainer 1.3 or newer at /usr/bin/apptainer. Install it and run this script again."
    NEED_APPTAINER=1
    fetch_pinned "$APPTAINER_URL" "$WORK/apptainer.deb" "$APPTAINER_SHA256" "Apptainer's package"
    say "Apptainer's package: checked."
fi
NEED_DBUS=0
if dbus_user_session_ok; then
    say "dbus-user-session: installed, kept."
else
    say "dbus-user-session: not installed. Rootless Apptainer sets a job's limits through the node user's systemd, over that user's session bus, which this package provides (Debian 12's cloud image leaves it out)."
    ask "Install dbus-user-session from this distribution's archive (apt-get)?" \
        || fail "stopped: the node needs the package dbus-user-session for a job's limits. Install it and run this script again."
    NEED_DBUS=1
fi
NEED_UV=1
if [ -x "$UV_DIR/uv" ] && [ -f "$UV_DIR/.tarball-sha256" ] && [ "$(cat "$UV_DIR/.tarball-sha256")" = "$UV_SHA256" ]; then
    NEED_UV=0
    say "uv $UV_VERSION: installed, kept."
else
    fetch_pinned "$UV_URL" "$WORK/uv.tar.gz" "$UV_SHA256" "uv $UV_VERSION"
    say "uv $UV_VERSION: checked."
fi
NEED_NODE=1
INSTALLED_MARK="$WHEEL_SHA256 $REQUIREMENTS_SHA256"
if [ -x "$VENV/bin/terminus-node" ] && [ -f "$VENV/.terminus-install" ] \
    && [ "$(cat "$VENV/.terminus-install")" = "$INSTALLED_MARK" ]; then
    NEED_NODE=0
    say "The node $VERSION: installed, kept."
else
    fetch_blob "$REQUIREMENTS_SHA256" "$WORK/$REQUIREMENTS_NAME" "the node's requirements ($REQUIREMENTS_NAME)"
    fetch_blob "$WHEEL_SHA256" "$WORK/$WHEEL_NAME" "the node's wheel ($WHEEL_NAME)"
    say "The node's requirements and wheel: checked."
fi
if [ -n "$REGISTRY_HEADER" ]; then rm -f "$REGISTRY_HEADER"; fi

# A root-owned staging copy, checked again, is what is installed (the caller's files could change after the check).
run_root mkdir -p "$OPT"
run_root chmod 0755 "$OPT"
untrusted=$(untrusted_in "$OPT" shallow)
[ -z "$untrusted" ] || fail "/opt/terminus-node is not root's alone ($untrusted); this script does not install over it."
STAGE="$OPT/.staging-$$"
run_root mkdir -m 0700 "$STAGE"
stage() {
    # stage <file> <sha256> <what>
    run_root install -m 0600 "$WORK/$1" "$STAGE/$1"
    staged=$(run_root sha256sum "$STAGE/$1" | cut -d ' ' -f 1)
    [ "$staged" = "$2" ] || fail "the staged copy of $3 changed after its check (got $staged); nothing more is installed"
}
if [ "$NEED_APPTAINER" = 1 ]; then stage apptainer.deb "$APPTAINER_SHA256" "Apptainer's package"; fi
if [ "$NEED_UV" = 1 ]; then stage uv.tar.gz "$UV_SHA256" "uv"; fi
if [ "$NEED_NODE" = 1 ]; then
    stage "$REQUIREMENTS_NAME" "$REQUIREMENTS_SHA256" "the node's requirements"
    stage "$WHEEL_NAME" "$WHEEL_SHA256" "the node's wheel"
fi

# --- 3. Apptainer -----------------------------------------------------------------------------------------------------
step "4. Apptainer and the session bus"
if [ "$NEED_APPTAINER" = 1 ] || [ "$NEED_DBUS" = 1 ]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update
fi
if [ "$NEED_APPTAINER" = 1 ]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "$STAGE/apptainer.deb"
    apptainer_ok || fail "Apptainer's package installed, but /usr/bin/apptainer is not 1.3 or newer"
    say "Apptainer: installed ($("$APPTAINER" --version 2>/dev/null))."
fi
if [ "$NEED_DBUS" = 1 ]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends dbus-user-session
    dbus_user_session_ok || fail "apt-get ran, but the package dbus-user-session is not installed"
    say "dbus-user-session: installed."
fi
if [ "$DISTRO" = ubuntu-24.04 ] && [ ! -f "$ROOT/etc/apparmor.d/apptainer" ]; then
    fail "Ubuntu 24.04 lets Apptainer use user namespaces only through its AppArmor profile /etc/apparmor.d/apptainer, which is missing. Install Apptainer's release package (it adds the profile) and run this script again."
fi

# --- 4. the node's user and layout ------------------------------------------------------------------------------------
step "5. The user $NODE_USER"
if [ -z "$NODE_HOME" ]; then
    run_root useradd --create-home --home-dir "$ROOT/home/$NODE_USER" --user-group --shell /usr/sbin/nologin \
        --comment "Terminus node" "$NODE_USER"
    NODE_HOME=$(getent passwd "$NODE_USER" | cut -d: -f6)
    NODE_UID=$(id -u "$NODE_USER")
    STATE="$NODE_HOME/.local/state/terminus-node"
    PERSONAL_SETTINGS="$NODE_HOME/.config/terminus-node/node.env"
    say "Created the user $NODE_USER (home $NODE_HOME)."
    [ "$(id -nG "$NODE_USER")" = "$NODE_USER" ] || fail "the new user $NODE_USER is in other groups than its own"
else
    say "The user $NODE_USER exists (home $NODE_HOME)."
fi
# Its home is closed to other users (useradd may make it 0755).
if [ -L "$NODE_HOME" ] || [ ! -d "$NODE_HOME" ] || [ "$(stat -c %u "$NODE_HOME")" != "$NODE_UID" ]; then
    fail "the home of $NODE_USER ($NODE_HOME) is not a directory of its own"
fi
run_root chmod 0750 "$NODE_HOME"
run_root touch "$ROOT/etc/subuid" "$ROOT/etc/subgid"
for map in subuid subgid; do
    if ! grep -q "^$NODE_USER:" "$ROOT/etc/$map"; then
        start=$(awk -F: 'BEGIN { top = 100000 } { end = $2 + $3; if (end > top) top = end } END { print top }' \
            "$ROOT/etc/subuid" "$ROOT/etc/subgid")
        printf '%s:%s:65536\n' "$NODE_USER" "$start" | run_root tee -a "$ROOT/etc/$map" >/dev/null
        say "Added a subordinate id range to /etc/$map."
    fi
done
LINGER_NEW=0
if [ -e "$ROOT/var/lib/systemd/linger/$NODE_USER" ]; then
    say "Lingering: on."
else
    run_root loginctl enable-linger "$NODE_USER"
    LINGER_NEW=1
    say "Lingering: turned on (rootless Apptainer uses the user's own systemd)."
fi
# The user's session bus: rootless Apptainer reaches the user's systemd over it for a job's limits (cgroups). Its
# directory is the user's alone, so the user looks. A user manager started by lingering just now gets a moment.
[ -n "$NODE_UID" ] || fail "the user $NODE_USER has no uid"
BUS="$ROOT/run/user/$NODE_UID/bus"
RECHECK=0
if [ "$LINGER_NEW" = 1 ]; then
    waited=0
    while [ "$waited" -lt 10 ] && ! as_node test -S "$ROOT/run/user/$NODE_UID/systemd/private"; do
        sleep 1
        waited=$((waited + 1))
    done
fi
if ! as_node test -S "$BUS"; then
    # A user manager that ran before dbus-user-session was installed does not know dbus.socket: a reload teaches it,
    # and starting the socket makes the bus. The manager is not restarted, which would end a running job's containers.
    as_node systemctl --user daemon-reload || say "systemctl --user daemon-reload as $NODE_USER failed."
    as_node systemctl --user start dbus.socket || say "systemctl --user start dbus.socket as $NODE_USER failed."
    RECHECK=1
    say "The user $NODE_USER's session bus: started (systemctl --user start dbus.socket)."
fi
as_node test -S "$BUS" \
    || fail "the user $NODE_USER has no session bus (/run/user/$NODE_UID/bus is not a socket), and rootless Apptainer needs it for a job's limits. Check that dbus-user-session is installed and that the user's systemd runs (systemctl status user@$NODE_UID.service), then run this script again."

# --- 5. uv, Python and the node -----------------------------------------------------------------------------------------
step "6. The node $VERSION"
UV="$UV_DIR/uv"
if [ "$NEED_UV" = 1 ]; then
    run_root mkdir -p "$STAGE/uv"
    run_root tar -xzf "$STAGE/uv.tar.gz" -C "$STAGE/uv" --strip-components=1 --no-same-owner
    run_root mkdir -p "$UV_DIR"
    run_root install -m 0755 "$STAGE/uv/uv" "$UV"
    printf '%s\n' "$UV_SHA256" | run_root tee "$UV_DIR/.tarball-sha256" >/dev/null
    say "uv $UV_VERSION: installed in $UV_DIR."
fi
if [ "$NEED_NODE" = 1 ]; then
    run_root rm -rf "$VENV"
    # uv checks the Python it downloads against its own pinned digests; the cache is the staging directory's;
    # --no-bin: no python executable in a bin directory outside /opt/terminus-node (uv's default is ~/.local/bin).
    run_root env UV_NO_CONFIG=1 UV_CACHE_DIR="$STAGE/cache" UV_PYTHON_INSTALL_DIR="$OPT/python" \
        "$UV" python install --no-bin "$PYTHON_VERSION"
    run_root env UV_NO_CONFIG=1 UV_CACHE_DIR="$STAGE/cache" UV_PYTHON_INSTALL_DIR="$OPT/python" \
        "$UV" venv --python "$PYTHON_VERSION" --python-preference only-managed "$VENV"
    # --no-build: a pinned hash installs a wheel only; no package's build code runs as root.
    if [ -n "$CA_BUNDLE" ] && [ "$INDEX" != "$DEFAULT_INDEX" ]; then
        # The live session's CA, for its own index only: PyPI keeps the system's roots.
        run_root env UV_NO_CONFIG=1 UV_CACHE_DIR="$STAGE/cache" SSL_CERT_FILE="$CA_BUNDLE" \
            "$UV" pip install --python "$VENV/bin/python" --require-hashes --no-build --index-url "$INDEX" \
            -r "$STAGE/$REQUIREMENTS_NAME"
    else
        run_root env UV_NO_CONFIG=1 UV_CACHE_DIR="$STAGE/cache" \
            "$UV" pip install --python "$VENV/bin/python" --require-hashes --no-build --index-url "$INDEX" \
            -r "$STAGE/$REQUIREMENTS_NAME"
    fi
    run_root env UV_NO_CONFIG=1 UV_CACHE_DIR="$STAGE/cache" \
        "$UV" pip install --python "$VENV/bin/python" --no-deps --no-build --no-index "$STAGE/$WHEEL_NAME"
    [ -x "$VENV/bin/terminus-node" ] || fail "the node's wheel installed no terminus-node command"
    printf '%s\n' "$INSTALLED_MARK" | run_root tee "$VENV/.terminus-install" >/dev/null
    say "The node $VERSION: installed in $VENV."
fi
run_root ln -sfn "$VERSION" "$OPT/current"
say "/opt/terminus-node/current -> $VERSION."
CA_NODE=''
if [ -n "$CA_BUNDLE" ]; then
    # The node's user reads the CA from a root-owned copy of the caller's checked copy.
    CA_NODE="$OPT/install-ca.pem"
    run_root install -m 0644 "$CA_BUNDLE" "$CA_NODE"
fi
# Nothing under /opt/terminus-node is writable but by root, so the next run's check holds by construction.
run_root chmod -R go-w "$OPT"

# --- 6. setup, the unit, the model --------------------------------------------------------------------------------------
step "7. Setup: the checks and the join"
run_setup() {
    set -- setup --instance "$INSTANCE" --expect "preflight=$IMAGE_PREFLIGHT" --expect "compute=$IMAGE_COMPUTE" \
        --expect "agent=$IMAGE_AGENT"
    if [ "$REGISTRY" != "$REGISTRY_HOST" ]; then
        set -- "$@" --registry "oras://$REGISTRY/$REGISTRY_PREFIX"
    fi
    if [ -n "$CA_NODE" ]; then
        set -- "$@" --ca-bundle "$CA_NODE"
    fi
    if [ "$ENROLLED" = 1 ]; then
        as_node "$NODE_BIN" "$@" --yes
    else
        # The single-use code goes through a pipe to setup's standard input (`--join -`), so neither sudo's log of
        # the command nor any process's arguments hold it (printf is a builtin); setup reads that one line only.
        printf '%s\n' "$JOIN" | as_node_reading "$NODE_BIN" "$@" --join - --yes
    fi
}
status=0
run_setup || status=$?
JOIN=''
if [ "$status" = "$EXIT_CODE_REFUSED" ]; then
    printf 'terminus-install: the instance refused the join code: it is spent or has expired. Make a new line in the app (Compute, Add a machine) and run it.\n' >&2
    exit "$EXIT_CODE_REFUSED"
fi
[ "$status" = 0 ] || fail "terminus-node setup stopped (exit $status); its message is above. Run this line again once it is fixed."

step "8. The node's service"
# `service` reads the node's settings (its directories) from the settings file named in its environment.
as_node TERMINUS_NODE_SETTINGS_FILE="$PERSONAL_SETTINGS" "$NODE_BIN" service --user-name "$NODE_USER" \
    --settings-file "$PERSONAL_SETTINGS" >"$WORK/unit.printed" \
    || fail "terminus-node service could not print the node's unit; its message is above"
# Root installs this text and PID 1 runs it as root, while the node's user shapes part of it: check it first. The node's
# process (or a child it left) may still hold the printed file open, so root checks and installs a copy it made after
# the command ended, which nothing of the node's user can write; any byte outside printable ASCII is refused first (an
# awk that stops at a NUL would not see the rest of the line, as systemd would not).
cp "$WORK/unit.printed" "$WORK/terminus-node.service" || fail "the node's unit could not be copied in $WORK"
# (tr and cmp see every byte; grep would take a NUL for a line's end.)
if ! LC_ALL=C tr -d ' -~\n' <"$WORK/terminus-node.service" | cmp -s - /dev/null; then
    fail "the node's unit is not one this script installs (a byte outside printable ASCII); nothing was installed. Its settings file ($PERSONAL_SETTINGS) may have been changed."
fi
unit_problem=$(check_unit "$WORK/terminus-node.service") \
    || fail "the node's unit is not one this script installs (${unit_problem:-unreadable}); nothing was installed. Its settings file ($PERSONAL_SETTINGS) may have been changed."
# A job's --cpus needs the cpu controller in the node user's systemd, and Ubuntu 22.04's systemd (249) delegates only
# memory and pids to a user (v0.33.2's live session, attempt 5): a drop-in for this user's manager alone. A reload
# applies it; the manager is not restarted, which would end a running job's containers.
[ -n "$NODE_UID" ] || fail "the user $NODE_USER has no uid"
DELEGATE_DIR="$ROOT/etc/systemd/system/user@$NODE_UID.service.d"
DELEGATE="$DELEGATE_DIR/terminus-node.conf"
RELOAD=0
if [ "$(cat "$DELEGATE" 2>/dev/null)" != "$(printf '[Service]\nDelegate=cpu memory pids')" ]; then
    run_root mkdir -p "$DELEGATE_DIR"
    printf '[Service]\nDelegate=cpu memory pids\n' | run_root tee "$DELEGATE" >/dev/null
    run_root chmod 0644 "$DELEGATE"
    RELOAD=1
    say "The user $NODE_USER's systemd: it delegates the cpu, memory and pids controllers (a job's limits)."
fi
if [ -f "$UNIT_PATH" ] && cmp -s "$WORK/terminus-node.service" "$UNIT_PATH"; then
    say "The unit $UNIT_PATH is in place."
    [ "$RELOAD" = 0 ] || run_root systemctl daemon-reload
    if [ "$UPDATE" = 1 ]; then
        run_root systemctl restart terminus-node.service
        say "terminus-node.service: restarted on $VERSION."
    elif run_root systemctl is-active --quiet terminus-node.service; then
        if [ "$RELOAD" = 1 ] || [ "$RECHECK" = 1 ]; then
            # Its container check may be backing off (up to an hour) after failing without the cpu controller or the
            # user's session bus: a restart checks again now. Its jobs keep running (KillMode=process) and are resumed.
            run_root systemctl restart terminus-node.service
            say "terminus-node.service: restarted, so it checks its container again."
        else
            say "terminus-node.service runs."
        fi
    else
        run_root systemctl enable --now terminus-node.service
        say "terminus-node.service: started."
    fi
else
    run_root install -m 0644 "$WORK/terminus-node.service" "$UNIT_PATH"
    run_root systemctl daemon-reload
    run_root systemctl enable terminus-node.service
    run_root systemctl restart terminus-node.service
    say "terminus-node.service: installed and started (it starts again at boot)."
fi

step "9. The model"
if [ "$UPDATE" = 1 ]; then
    say "The node keeps its model and key."
else
    if [ "$MODEL_SET" = 1 ]; then
        set -- "$MODEL" "$@"
    fi
    if [ "$#" -gt 0 ] || [ -t 0 ]; then
        model_status=0
        if [ -t 0 ]; then
            # The step asks on the person's terminal (its standard input; the key typed hidden: setup turns the echo
            # off on it), still in a session of its own.
            as_node_reading "$NODE_BIN" setup --model "$@" || model_status=$?
        else
            # No terminal: a question the flags do not answer ends the step with setup's own message.
            as_node "$NODE_BIN" setup --model "$@" || model_status=$?
        fi
        [ "$model_status" = 0 ] \
            || fail "the model step stopped (exit $model_status); its message is above. The node is joined and its service runs; set the model again with: sudo -u $NODE_USER /opt/terminus-node/current/bin/terminus-node setup --model"
    else
        say "No terminal and no model given: the machine waits for its model. Set it with:"
        say "  sudo -u $NODE_USER /opt/terminus-node/current/bin/terminus-node setup --model"
    fi
fi

step "Done"
say "The node $VERSION is installed for $INSTANCE. The app shows this machine under My machines."
