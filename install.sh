#!/usr/bin/env bash
# Codex Desktop Buddy Bridge installer (macOS).
#
# What this does:
#   1. Picks a Homebrew framework Python (newest python@3.x found) and builds a
#      Bluetooth-capable copy of its Python.app under .btpython/ — see
#      "Why .btpython" below.
#   2. Creates a venv on that same interpreter and installs bleak.
#   3. Renders the launchd plist with absolute paths and loads it.
#   4. Enables [features] hooks = true in ~/.codex/config.toml, migrating the
#      deprecated codex_hooks flag if it is still there.
#   5. Writes ~/.codex/hooks.json with PermissionRequest + SessionStart +
#      UserPromptSubmit + Stop entries pointing at hooks/*.py. Existing
#      hooks.json is backed up.
#
# Why .btpython:
#   Under launchd, macOS TCC kills the process with SIGABRT the moment
#   CoreBluetooth is touched, unless the *executable bundle* declares
#   NSBluetoothAlwaysUsageDescription. No stock Python ships that key, and a
#   venv's bin/python3 is not a bundle at all. Run from a terminal it works,
#   because TCC attributes the access to Terminal.app — which is why this only
#   reproduces under launchd, with KeepAlive turning it into a crash loop every
#   ThrottleInterval seconds. So we copy the framework's Python.app, inject the
#   key, re-sign ad-hoc, and point launchd at that binary with PYTHONHOME set.
#
# Why not /usr/bin/python3:
#   Xcode's Python lives inside a system-signed bundle that cannot be patched
#   or re-signed, so the SIGABRT above is unavoidable there.
#
# Overrides:
#   CODEX_BUDDY_PYTHON=/path/to/python3   use this interpreter (must be a
#                                         framework build: Python.app present)
#   CODEX_BUDDY_SOCKET=/tmp/foo.sock      daemon socket path
#
# Re-running this script is idempotent.

set -euo pipefail

BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${BRIDGE_ROOT}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python3"
BTPY_DIR="${BRIDGE_ROOT}/.btpython"
BTPY_APP="${BTPY_DIR}/Python.app"
BTPY_BIN="${BTPY_APP}/Contents/MacOS/Python"
SOCKET_PATH="${CODEX_BUDDY_SOCKET:-/tmp/codex-buddy.sock}"
PLIST_LABEL="com.claudecodebuddy.codex-buddy"
PLIST_TARGET="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
PLIST_TEMPLATE="${BRIDGE_ROOT}/launchd/${PLIST_LABEL}.plist.template"
LOG_DIR="${HOME}/Library/Logs"
LOG_PATH="${LOG_DIR}/codex-buddy.log"
CODEX_DIR="${HOME}/.codex"
CONFIG_TOML="${CODEX_DIR}/config.toml"
HOOKS_JSON="${CODEX_DIR}/hooks.json"
MIN_PY_MINOR=10   # 3.10+

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    die "This installer is macOS-only (it uses launchd). Windows: install_windows.ps1"
fi

step "Bridge root: ${BRIDGE_ROOT}"

# --- 1. Find a framework Python ------------------------------------------------
#
# A framework build is required: only those carry Resources/Python.app, the
# bundle we patch for Bluetooth. Candidates, newest version first:
#   - $CODEX_BUDDY_PYTHON, if set
#   - Homebrew python@3.x kegs
#   - python.org installs under /Library/Frameworks

framework_dir_for() {
    # Given a python3 binary, echo its Python.framework/Versions/X.Y dir.
    local bin="$1"
    "${bin}" -c 'import sys, sysconfig, pathlib
p = pathlib.Path(sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX") or "")
v = sysconfig.get_config_var("py_version_short")
print(p / "Python.framework" / "Versions" / v if p else "")' 2>/dev/null
}

python_candidates() {
    local brew_prefix version
    if [[ -n "${CODEX_BUDDY_PYTHON:-}" ]]; then
        printf '%s\n' "${CODEX_BUDDY_PYTHON}"
    fi
    brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    # Sort 3.14 above 3.9 numerically — `sort -V` is not portable enough here.
    for version in $(ls -d "${brew_prefix}"/opt/python@3.* 2>/dev/null \
                     | sed 's|.*/python@||' | sort -t. -k1,1n -k2,2n -r); do
        printf '%s\n' "${brew_prefix}/opt/python@${version}/bin/python3"
    done
    for version in $(ls -d /Library/Frameworks/Python.framework/Versions/3.* 2>/dev/null \
                     | sed 's|.*/||' | sort -t. -k1,1n -k2,2n -r); do
        printf '%s\n' "/Library/Frameworks/Python.framework/Versions/${version}/bin/python3"
    done
}

PYTHON_BIN=""
FRAMEWORK_DIR=""
while read -r candidate; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    minor="$("${candidate}" -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo 0)"
    [[ "${minor}" -ge "${MIN_PY_MINOR}" ]] || continue
    fw="$(framework_dir_for "${candidate}")"
    [[ -n "${fw}" && -d "${fw}/Resources/Python.app" ]] || continue
    PYTHON_BIN="${candidate}"
    FRAMEWORK_DIR="${fw}"
    break
done < <(python_candidates)

if [[ -z "${PYTHON_BIN}" ]]; then
    if [[ -n "${CODEX_BUDDY_PYTHON:-}" ]]; then
        die "CODEX_BUDDY_PYTHON=${CODEX_BUDDY_PYTHON} is not a usable framework Python
   (needs 3.${MIN_PY_MINOR}+ and a Resources/Python.app inside its framework)."
    fi
    die "No Homebrew framework Python found.
   Install one, then re-run this script:

       brew install python@3.14

   /usr/bin/python3 (Xcode) cannot be used — its bundle is system-signed and
   cannot carry the Bluetooth entitlement launchd needs."
fi

PY_VERSION="$("${PYTHON_BIN}" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
step "Using Python ${PY_VERSION} at ${PYTHON_BIN}"

# --- 2. Bluetooth-capable interpreter bundle -----------------------------------

step "Building Bluetooth-capable interpreter at ${BTPY_APP}"
rm -rf "${BTPY_DIR}"
mkdir -p "${BTPY_DIR}"
cp -R "${FRAMEWORK_DIR}/Resources/Python.app" "${BTPY_APP}"

BTPY_INFO="${BTPY_APP}/Contents/Info.plist"
BT_REASON="Codex Buddy Bridge talks to the Claude desk buddy over Bluetooth LE."
for key in NSBluetoothAlwaysUsageDescription NSBluetoothPeripheralUsageDescription; do
    /usr/libexec/PlistBuddy -c "Set :${key} ${BT_REASON}" "${BTPY_INFO}" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :${key} string ${BT_REASON}" "${BTPY_INFO}" >/dev/null
done
codesign --force --sign - "${BTPY_APP}" >/dev/null 2>&1 \
    || die "codesign failed on ${BTPY_APP}"

PYTHONHOME_VALUE="${FRAMEWORK_DIR}"
SITE_PACKAGES="${VENV_DIR}/lib/python${PY_VERSION}/site-packages"
PYTHONPATH_VALUE="${BRIDGE_ROOT}:${SITE_PACKAGES}"

if ! PYTHONHOME="${PYTHONHOME_VALUE}" "${BTPY_BIN}" -c 'pass' 2>/dev/null; then
    die "The patched interpreter at ${BTPY_BIN} cannot start.
   This usually means ${FRAMEWORK_DIR} was moved or uninstalled."
fi

# --- 3. venv on the same interpreter -------------------------------------------

step "Creating Python venv and installing bleak"
venv_is_stale() {
    local venv_version
    if [[ ! -x "${VENV_PYTHON}" ]]; then
        return 0
    fi
    if ! "${VENV_PYTHON}" -c 'pass' 2>/dev/null; then
        return 0                                                # base interpreter gone
    fi
    venv_version="$("${VENV_PYTHON}" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
    [[ "${venv_version}" != "${PY_VERSION}" ]]
}
if venv_is_stale; then
    [[ -d "${VENV_DIR}" ]] && warn "Rebuilding venv — it was missing, broken, or built on another Python"
    rm -rf "${VENV_DIR}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
"${VENV_PYTHON}" -m pip install --quiet --upgrade pip
"${VENV_PYTHON}" -m pip install --quiet -r "${BRIDGE_ROOT}/requirements.txt"

# bleak lands in the venv, but the daemon runs on the patched interpreter with
# PYTHONPATH pointing back at it — verify that combination actually imports.
if ! PYTHONHOME="${PYTHONHOME_VALUE}" PYTHONPATH="${PYTHONPATH_VALUE}" \
     "${BTPY_BIN}" -c 'import bleak' 2>/dev/null; then
    die "The patched interpreter cannot import bleak from ${SITE_PACKAGES}."
fi

# --- 4. launchd -----------------------------------------------------------------

step "Rendering launchd plist"
mkdir -p "${LOG_DIR}" "$(dirname "${PLIST_TARGET}")"
sed \
    -e "s|__PYTHON_BIN__|${BTPY_BIN}|g" \
    -e "s|__PYTHONHOME__|${PYTHONHOME_VALUE}|g" \
    -e "s|__PYTHONPATH__|${PYTHONPATH_VALUE}|g" \
    -e "s|__BRIDGE_ROOT__|${BRIDGE_ROOT}|g" \
    -e "s|__SOCKET_PATH__|${SOCKET_PATH}|g" \
    -e "s|__LOG_PATH__|${LOG_PATH}|g" \
    "${PLIST_TEMPLATE}" > "${PLIST_TARGET}"

if launchctl list | grep -q "${PLIST_LABEL}"; then
    launchctl unload "${PLIST_TARGET}" 2>/dev/null || true
fi
launchctl load -w "${PLIST_TARGET}"
step "launchd loaded ${PLIST_LABEL}; logs at ${LOG_PATH}"

# --- 5. Codex feature flag ------------------------------------------------------

step "Enabling [features] hooks = true in ${CONFIG_TOML}"
mkdir -p "${CODEX_DIR}"
touch "${CONFIG_TOML}"
cp "${CONFIG_TOML}" "${CONFIG_TOML}.bak.$(date +%Y%m%d-%H%M%S)"
"${PYTHON_BIN}" - "${CONFIG_TOML}" <<'PY'
# Ensure [features] hooks = true. `codex_hooks` was renamed to `hooks` in Codex
# 0.153.4; the old name is silently ignored, so migrate rather than leave it.
import pathlib, re, sys

HOOKS_RE = re.compile(r"^hooks\s*=")
LEGACY_RE = re.compile(r"^codex_hooks\s*=")

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
out, in_features, seen_hooks, migrated = [], False, False, False


def append_hooks():
    # Insert before any blank lines trailing the section, so the key stays
    # visually inside [features] rather than floating against the next header.
    at = len(out)
    while at > 0 and not out[at - 1].strip():
        at -= 1
    out.insert(at, "hooks = true")


for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_features and not seen_hooks:
            append_hooks()
            seen_hooks = True
        in_features = stripped == "[features]"
        out.append(line)
        continue
    if in_features and LEGACY_RE.match(stripped):
        migrated = True
        if not seen_hooks:
            out.append("hooks = true")
            seen_hooks = True
        continue                      # drop the deprecated line
    if in_features and HOOKS_RE.match(stripped):
        out.append("hooks = true")
        seen_hooks = True
        continue
    out.append(line)

if in_features and not seen_hooks:
    append_hooks()
    seen_hooks = True
if not seen_hooks:
    out.extend(["", "[features]", "hooks = true"])

path.write_text("\n".join(out) + "\n")
if migrated:
    print("    migrated deprecated codex_hooks -> hooks")
PY

# --- 6. Hooks -------------------------------------------------------------------

step "Writing ${HOOKS_JSON}"
PERM_HOOK="${BRIDGE_ROOT}/hooks/permission_request.py"
SESSION_HOOK="${BRIDGE_ROOT}/hooks/session_start.py"
PROMPT_HOOK="${BRIDGE_ROOT}/hooks/user_prompt_submit.py"
STOP_HOOK="${BRIDGE_ROOT}/hooks/stop.py"
chmod +x "${PERM_HOOK}" "${SESSION_HOOK}" "${PROMPT_HOOK}" "${STOP_HOOK}"

# NOTE: InteractiveStart / InteractiveEnd are deliberately not registered — they
# are not Codex hook events, so Codex ignores those entries. The valid set is
# SessionStart, SessionEnd, SubagentStart, SubagentStop, PreToolUse, PostToolUse,
# UserPromptSubmit, Stop, PermissionRequest, PreCompact, PostCompact, Interrupt.
# The daemon still tracks interactive waits — it gets them from the app-server
# via router_client, not from hooks.

if [[ -f "${HOOKS_JSON}" ]]; then
    cp "${HOOKS_JSON}" "${HOOKS_JSON}.bak.$(date +%s)"
    warn "Existing hooks.json was backed up next to it"
fi

cat > "${HOOKS_JSON}" <<EOF
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "${PERM_HOOK}",
            "timeout": 115,
            "statusMessage": "ClaudeCodeBuddy approval"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "${SESSION_HOOK}",
            "timeout": 3
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "${PROMPT_HOOK}",
            "timeout": 3
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "${STOP_HOOK}",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
EOF

CLI_TOOL="${BRIDGE_ROOT}/codex-buddy"
chmod +x "${CLI_TOOL}"

cat <<EOF

✓ Install complete.

    Python       ${PYTHON_BIN} (${PY_VERSION})
    Daemon runs  ${BTPY_BIN}
    PYTHONHOME   ${PYTHONHOME_VALUE}

Quick CLI:
    ${CLI_TOOL} status        agent loaded? + last log lines
    ${CLI_TOOL} on            load the launchd agent
    ${CLI_TOOL} off           unload it (releases BLE for Claude Hardware Buddy)
    ${CLI_TOOL} restart
    ${CLI_TOOL} log           tail -f the daemon log
    ${CLI_TOOL} foreground    run in this terminal with --debug
    ${CLI_TOOL} uninstall     remove plist + hooks.json

Tip: alias it in your shell rc, e.g.
    alias cbuddy='${CLI_TOOL}'

Next steps:

  1. TRUST THE HOOKS. Non-managed hooks do not run until you trust them:
     open the Codex TUI, run /hooks, and approve. Trust is keyed on a hash of
     hooks.json, so re-trust after anything changes it (including re-running
     this installer). Until then you get zero hook executions and no error
     message anywhere.

  2. Restart Codex Desktop and any open Codex CLI sessions so they pick up
     ${HOOKS_JSON}.

  3. The daemon does NOT hold BLE while idle — Claude Hardware Buddy works
     normally most of the time. BLE is acquired only when a Codex approval
     fires (3-5s connect overhead) and released immediately after.

  4. Test: in Codex, run a command that needs approval. The buddy switches
     to its approval screen; press A to allow or B to deny. If Claude
     happens to be paired at that moment, Codex falls back to its native
     prompt — no error, no hang.

  5. If the device shows status but approvals never appear, the hooks are the
     broken half — status comes from a separate app-server path. Check hooks
     actually fire by appending a line to a file from the top of
     hooks/permission_request.py; ~/.codex/logs_2.sqlite never logs hooks.

EOF
