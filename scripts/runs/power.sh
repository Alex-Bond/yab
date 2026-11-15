#!/bin/bash
# Source before starting work, and again after waiting for a compiler lock.
yab_queue_enabled() { [ -f "$HOME/.local/state/yab-farm/service-enabled" ]; }
yab_power_source() {
  local connected power
  # pmset can falsely report AC inside an agent sandbox. The battery's
  # hardware adapter flag remains readable there.
  connected="$(/usr/sbin/ioreg -r -c AppleSmartBattery 2>/dev/null | /usr/bin/sed -nE 's/.*"ExternalConnected" = (Yes|No).*/\1/p' | /usr/bin/head -1)" || connected=""
  case "$connected" in
    Yes) echo ac; return ;;
    No) echo battery; return ;;
  esac
  power="$(/usr/bin/pmset -g batt 2>/dev/null)" || { echo unknown; return; }
  case "$power" in
    *"Now drawing from 'Battery Power'"*|*'; discharging;'*) echo battery ;;
    *"Now drawing from 'AC Power'"*) echo ac ;;
    *) echo unknown ;;
  esac
}

yab_route_on_battery() {
  local power root
  # A copied worker environment must not bypass the user's local off switch.
  if [ "${YAB_FARM_WORKER:-}" = 1 ] && [ ! -f "$HOME/.local/state/yab-farm/main.disabled" ]; then
    power="$(yab_power_source)"
    [ "$power" != ac ] || return 0
    # The user asked for this job on main itself (--host main): battery is fine.
    [ "${YAB_FARM_BATTERY_OK:-}" != 1 ] || return 0
    echo "Farm worker lost AC power ($power); stopping before the next command." >&2
    exit 75
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -f "$root/scripts/runs/power.sh" ] && [ -f "$root/mini" ] || return 0
  # A Mac outside the farm (a contributor's, a CI runner) builds where it is,
  # on battery too: only a Mac the farm set up has this folder.
  [ -d "$HOME/.local/state/yab-farm" ] || return 0
  if yab_queue_enabled && [ -f "$root/scripts/remote/farm.py" ]; then
    local forwarded=(env) key relative="${PWD#"$root"}"
    for key in YAB_WMO YAB_PROBE YAB_TEST_FILTER; do
      [ -z "${!key+x}" ] || forwarded+=("$key=${!key}")
    done
    relative="${relative#/}"
    exec "$root/farm" exec -- /bin/bash -c \
      'cd "$1" && shift && exec "$@"' farm-direct "${relative:-.}" "${forwarded[@]}" "$@"
  fi
  # Direct build.sh / swift calls on main use the shared queue even when
  # its service marker is missing, preserving lane and compiler coordination.
  if [ -f "$root/scripts/remote/farm-hosts.json" ] && [ -f "$root/farm" ]; then
    local main_name local_name
    main_name="$(/usr/bin/python3 -c 'import json,pwd,os,sys; h=json.load(open(sys.argv[1]))["hosts"]["main"]; print(h["local_hostname"] if pwd.getpwuid(os.getuid()).pw_name == h["user"] else "")' "$root/scripts/remote/farm-hosts.json")" || exit 75
    local_name="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)" || local_name="$(hostname -s)"
    if [ -n "$main_name" ] && [ "$local_name" = "$main_name" ]; then
      echo 'Sending this Yab run through the shared farm queue.' >&2
      local forwarded=(env) key
      for key in YAB_WMO YAB_PROBE YAB_TEST_FILTER; do
        [ -z "${!key+x}" ] || forwarded+=("$key=${!key}")
      done
      # Keep the original relative working directory and literal arguments.
      local relative="${PWD#"$root"}"
      relative="${relative#/}"
      exec /usr/bin/python3 "$root/scripts/remote/farm.py" exec -- /bin/bash -c \
        'cd "$1" && shift && exec "$@"' farm-direct "${relative:-.}" "${forwarded[@]}" "$@"
    fi
  fi
  power="$(yab_power_source)"
  case "$power" in
    ac) return 0 ;;
    battery) echo 'Battery power: sending this Yab run to renderer-2.' >&2 ;;
    *) echo 'Power source unavailable: sending this Yab run to renderer-2.' >&2 ;;
  esac
  exec /usr/bin/python3 "$root/runs" remote "$@"
}

# At most $1 compilers, fewer when memory is short: a swift-frontend holds up
# to about 1 GB. On 2026-10-05 six of them beside a probe left adhd 14 of 16
# GB used, 5 GB compressed and 1.5 GB in swap. One per free GB, never under
# two.
yab_memory_jobs() {
  local want="$1" level total room value
  level="$(/usr/sbin/sysctl -n kern.memorystatus_level 2>/dev/null)"
  total="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)"
  for value in "$want" "$level" "$total"; do
    case "$value" in '' | *[!0-9]*) echo "$want"; return ;; esac
  done
  room=$((total / 1073741824 * level / 100))
  [ "$room" -ge 2 ] || room=2
  if [ "$room" -lt "$want" ]; then echo "$room"; else echo "$want"; fi
}
