#!/bin/bash
# Installs ipadmode for the current user. Flags: --dry-run (change nothing), --dock (append the two applets to the Dock).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${HOME}/Library/Caches/ipadmode-build/stage"
DEST="${HOME}/Applications/iPadMode"
DEST_TMP="${HOME}/Applications/.iPadMode.new"
CLI="${DEST}/iPadMode.app/Contents/MacOS/ipadmode"
AGENTS="${HOME}/Library/LaunchAgents"
SUPPORT="${HOME}/Library/Application Support/ipadmode"
LOGS="${HOME}/Library/Logs/ipadmode"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
CLI_RE="$(printf '%s' "${CLI}" | sed -e 's/[][\.*^$()+?{}|]/\\&/g')"
PROC_RE="^${CLI_RE} (daemon|watchdog)\$"

if [ "$(id -u)" -eq 0 ]; then echo "install: do not run as root" >&2; exit 1; fi

DRY=0; DOCK=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY=1 ;;
    --dock) DOCK=1 ;;
    *) echo "usage: install.sh [--dry-run] [--dock]" >&2; exit 64 ;;
  esac
done

say() { echo "install: $*"; }
# Runs a state-changing command, or only prints it under --dry-run.
act() {
  if [ "${DRY}" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

# 1. Refuse unless the installed instance (if any) is in the Normal phase. Repeated right before the bootout.
check_phase() {
  [ -x "${CLI}" ] || { say "no installed binary, skipping the phase check"; return 0; }
  local json phase
  json="$("${CLI}" status --offline --json 2>/dev/null)" || json=""
  phase="$(osascript -l JavaScript -e '
    function run(argv) {
      try {
        var p = JSON.parse(argv[0]).state.phase;
        if (typeof p === "string") return p;
        return Object.keys(p)[0];
      } catch (e) { return "unknown"; }
    }' "${json}" 2>/dev/null)" || phase="unknown"
  if [ "${phase}" != "normal" ]; then
    echo "install: refused: current phase is '${phase}', not 'normal'. Run '${CLI} normal' first." >&2
    exit 1
  fi
  say "installed instance is in phase normal"
}
check_phase

# 2. Build into the APFS stage directory.
say "building (stage ${STAGE})"
bash "${ROOT}/scripts/build-app.sh"
for item in "iPadMode.app" "iPad Remote.app" "Layar Normal.app"; do
  [ -d "${STAGE}/${item}" ] || { echo "install: missing ${STAGE}/${item}" >&2; exit 2; }
done

# Plists are generated from the templates into a temp dir and linted before anything is touched.
GEN="$(mktemp -d "${TMPDIR:-/tmp}/ipadmode-plists.XXXXXX")"
RECOVER=0
# If the install fails after the agents were stopped, put things back and start whatever agents exist,
# so a failed install never leaves the Mac unguarded.
cleanup() {
  local rc=$?
  rm -rf "${GEN}"
  if [ "${rc}" -ne 0 ] && [ "${RECOVER}" -eq 1 ] && [ "${DRY}" -eq 0 ]; then
    echo "install: failed (exit ${rc}); restarting existing agents" >&2
    if [ ! -d "${DEST}" ] && [ -d "${DEST}.old" ]; then mv "${DEST}.old" "${DEST}" 2>/dev/null || true; fi
    local role
    for role in watchdog daemon; do
      if [ -f "${AGENTS}/local.ipadmode.${role}.plist" ]; then
        launchctl bootstrap "${DOMAIN}" "${AGENTS}/local.ipadmode.${role}.plist" 2>/dev/null || true
      fi
    done
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
esc_sed() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
for role in daemon watchdog; do
  sed -e "s|__IPADMODE_BIN__|$(esc_sed "${CLI}")|g" -e "s|__LOG_DIR__|$(esc_sed "${LOGS}")|g" \
    "${ROOT}/launchd/local.ipadmode.${role}.plist" > "${GEN}/local.ipadmode.${role}.plist"
  plutil -lint "${GEN}/local.ipadmode.${role}.plist" >/dev/null
  if grep -q "__IPADMODE_BIN__\|__LOG_DIR__\|/Volumes/" "${GEN}/local.ipadmode.${role}.plist"; then
    echo "install: generated plist for ${role} still has a placeholder or an external path" >&2; exit 2
  fi
done
say "plists generated and linted"

# 3. Check the phase again (the build can take a while), then stop the agents, then wait until neither process runs (never replace the binary under a live watchdog).
check_phase
RECOVER=1
for role in daemon watchdog; do
  act launchctl bootout "${DOMAIN}/local.ipadmode.${role}" 2>/dev/null || true
done
if [ "${DRY}" -eq 0 ]; then
  n=0
  while pgrep -f "${PROC_RE}" >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "${n}" -gt 20 ]; then
      echo "install: ipadmode processes still running 5 s after bootout; aborting before replacing the binary" >&2
      exit 2
    fi
    sleep 0.25
  done
  say "agents stopped"
else
  echo "[dry-run] wait up to 5 s until pgrep -f '${PROC_RE}' finds nothing"
fi

# 4. Atomic-ish replace: ditto to a sibling, then swap.
act mkdir -p "${HOME}/Applications"
act rm -rf "${DEST_TMP}"
act mkdir -p "${DEST_TMP}"
for item in "iPadMode.app" "iPad Remote.app" "Layar Normal.app"; do
  act ditto "${STAGE}/${item}" "${DEST_TMP}/${item}"
done
act rm -rf "${DEST}.old"
if [ "${DRY}" -eq 1 ] || [ -d "${DEST}" ]; then act mv "${DEST}" "${DEST}.old"; fi
act mv "${DEST_TMP}" "${DEST}"
act rm -rf "${DEST}.old"

# 5. Symlink, only with cached sudo credentials.
LINK_CMD="sudo mkdir -p /usr/local/bin && sudo ln -sf \"${CLI}\" /usr/local/bin/ipadmode"
if [ "${DRY}" -eq 1 ]; then
  echo "[dry-run] sudo -n ln -sf \"${CLI}\" /usr/local/bin/ipadmode  (else print: ${LINK_CMD})"
elif [ "$(readlink /usr/local/bin/ipadmode 2>/dev/null || true)" = "${CLI}" ]; then
  say "symlink /usr/local/bin/ipadmode already correct"
elif sudo -n ln -sf "${CLI}" /usr/local/bin/ipadmode 2>/dev/null; then
  say "symlink /usr/local/bin/ipadmode created"
else
  say "no unattended sudo; to create the symlink run once:"
  echo "  ${LINK_CMD}"
fi

# 6. Config, directories, disabled marker.
act mkdir -p "${SUPPORT}"
act chmod 700 "${SUPPORT}"
act mkdir -p "${LOGS}"
if [ ! -e "${SUPPORT}/config.json" ]; then
  if [ "${DRY}" -eq 1 ]; then
    echo "[dry-run] write ${SUPPORT}/config.json (minimal defaults)"
  else
    printf '%s\n' '{"remote":{"resolution":"1180x820","confirmSeconds":20},"hotkey":"ctrl+opt+cmd+n"}' > "${SUPPORT}/config.json"
  fi
fi
act rm -f "${SUPPORT}/disabled"

# 7. Install plists.
act mkdir -p "${AGENTS}"
for role in daemon watchdog; do
  act install -m 644 "${GEN}/local.ipadmode.${role}.plist" "${AGENTS}/local.ipadmode.${role}.plist"
done

# 8. Start: watchdog first, then daemon.
RECOVER=0
for role in watchdog daemon; do
  act launchctl bootstrap "${DOMAIN}" "${AGENTS}/local.ipadmode.${role}.plist"
done

# 9. Doctor.
if [ "${DRY}" -eq 1 ]; then
  echo "[dry-run] sleep 3; ${CLI} doctor"
else
  sleep 3
  doc_rc=0
  doc_out="$("${CLI}" doctor 2>&1)" || doc_rc=$?
  echo "${doc_out}"
  if [ "${doc_rc}" -ne 0 ]; then
    echo "install: doctor reported a critical failure (exit ${doc_rc})" >&2
    exit 2
  fi
fi

# 10. Dock: append only the missing items.
if [ "${DOCK}" -eq 1 ]; then
  changed=0
  dock_dump="$(defaults read com.apple.dock persistent-apps 2>/dev/null || true)"
  for name in "iPad Remote" "Layar Normal"; do
    url="file://$(printf '%s' "${DEST}/${name}.app/" | sed -e 's/ /%20/g')"
    case "${dock_dump}" in
      *"${url}"*) say "Dock already has ${name}"; continue ;;
    esac
    entry="<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${url}</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    act defaults write com.apple.dock persistent-apps -array-add "${entry}"
    changed=1
  done
  if [ "${changed}" -eq 1 ]; then act killall Dock; fi
fi

say "done"
