#!/bin/bash
# Removes ipadmode. Flags: --dry-run (change nothing), --purge (also remove support dir and logs).
set -euo pipefail

DEST="${HOME}/Applications/iPadMode"
CLI="${DEST}/iPadMode.app/Contents/MacOS/ipadmode"
AGENTS="${HOME}/Library/LaunchAgents"
SUPPORT="${HOME}/Library/Application Support/ipadmode"
LOGS="${HOME}/Library/Logs/ipadmode"
DOMAIN="gui/$(id -u)"

if [ "$(id -u)" -eq 0 ]; then echo "uninstall: do not run as root" >&2; exit 1; fi

DRY=0; PURGE=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY=1 ;;
    --purge) PURGE=1 ;;
    *) echo "usage: uninstall.sh [--dry-run] [--purge]" >&2; exit 64 ;;
  esac
done

say() { echo "uninstall: $*"; }
act() {
  if [ "${DRY}" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

# Disable first so the monitors are restored and the agents cannot re-enter remote mode.
if [ -x "${CLI}" ]; then
  if [ "${DRY}" -eq 1 ]; then
    echo "[dry-run] ${CLI} disable"
  elif ! "${CLI}" disable; then
    echo "uninstall: 'ipadmode disable' failed; nothing was removed. Check the monitors and fix this first (ipadmode doctor)." >&2
    exit 2
  fi
  if [ "${DRY}" -eq 0 ]; then
    json="$("${CLI}" status --offline --json 2>/dev/null)" || json=""
    verdict="$(osascript -l JavaScript -e '
      function run(argv) {
        try {
          var d = JSON.parse(argv[0]).displays || [];
          for (var i = 0; i < d.length; i++) { if (d[i].kind === "physical" && d[i].isOnline === false) return "offline"; }
          return "ok";
        } catch (e) { return "unknown"; }
      }' "${json}" 2>/dev/null)" || verdict="unknown"
    if [ "${verdict}" != "ok" ]; then
      echo "uninstall: a physical monitor is offline or the display state is unknown (${verdict}); nothing was removed. Check 'ipadmode status --offline'." >&2
      exit 2
    fi
  else
    echo "[dry-run] ${CLI} status --offline --json; abort if a physical monitor is offline"
  fi
else
  say "no installed binary, skipping disable"
fi

for role in daemon watchdog; do
  act launchctl bootout "${DOMAIN}/local.ipadmode.${role}" 2>/dev/null || true
  act rm -f "${AGENTS}/local.ipadmode.${role}.plist"
done
act rm -rf "${DEST}"

LINK=/usr/local/bin/ipadmode
if [ -L "${LINK}" ] && [ "$(readlink "${LINK}")" = "${CLI}" ]; then
  if [ "${DRY}" -eq 1 ]; then
    echo "[dry-run] sudo -n rm -f ${LINK}  (else print the command)"
  elif sudo -n rm -f "${LINK}" 2>/dev/null; then
    say "removed ${LINK}"
  else
    say "no unattended sudo; remove the symlink yourself:"
    echo "  sudo rm -f ${LINK}"
  fi
fi

if [ "${PURGE}" -eq 1 ]; then
  act rm -rf "${SUPPORT}"
  act rm -rf "${LOGS}"
fi

say "Dock items were left in place; remove 'iPad Remote' and 'Layar Normal' from the Dock by hand."
say "done"
