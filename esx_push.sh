#!/bin/sh
# esx_push.sh - copy an ESX offline bundle to the hosts in hosts.yaml and upgrade them.
# POSIX sh: runs on an ESX host (busybox sh) or on a Linux jump box.
#
#   sh esx_push.sh list               show how hosts.yaml was read; changes nothing
#   sh esx_push.sh copy               copy the bundle to every host
#   sh esx_push.sh upgrade esx02      copy if needed, dry run, start the update on one host
#   sh esx_push.sh upgrade            same for every host; each reboots itself when done
#   sh esx_push.sh check              show builds; hosts on the target build leave maintenance mode
#
#   -f FILE   use another host list (default: hosts.yaml next to this script)
#
# Name hosts as written in hosts.yaml or by short name. The host running the script
# always goes last. One password prompt per remote host per run.
# On ESX: run with "sh", and keep the script, hosts.yaml and the zip on a datastore.

# shellcheck disable=SC2012,SC2016,SC2029,SC2329  # remote scripts single-quoted on purpose; cleanup runs from trap
DIR=$(cd "$(dirname "$0")" && pwd)
CONF=$DIR/hosts.yaml
VOLROOT=${VOLROOT:-/vmfs/volumes}
TMP=/tmp/esx_push.$$
TAB=$(printf '\t')
NL='
'
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"

usage() { sed -n '2,16p' "$0"; exit 2; }
die()   { echo "$*" >&2; exit 2; }
lc()    { printf '%s' "$1" | awk '{print tolower($0)}'; }
show()  { : > "$1"; while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; printf '%s\n' "$l" >> "$1"; done; }
esc()   { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

if [ "${1:-}" = -f ]; then [ $# -ge 2 ] || usage; CONF=$2; shift 2; fi
[ $# -ge 1 ] || usage
ACTION=$1; shift
case $ACTION in list|copy|upgrade|check) ;; *) usage ;; esac
[ -f "$CONF" ] || die "host list not found: $CONF"

# ---- hosts.yaml (the documented subset: top-level "key: value" plus a hosts: list)
AWK_CLEAN='
function clean(v) {
  sub(/\r$/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
  if (length(v) >= 2 && ((substr(v, 1, 1) == dq && substr(v, length(v), 1) == dq) ||
                         (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)))
    v = substr(v, 2, length(v) - 2)
  return v
}'
yaml_get() { # top-level key
  awk -v key="$1" -v sq="'" -v dq='"' "$AWK_CLEAN"'
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ {
      k = $0; sub(/[ \t]*:.*/, "", k)
      if (k == key) { v = $0; sub(/^[^:]*:/, "", v); print clean(v); exit }
    }' "$CONF"
}
yaml_hosts() { # one "host<TAB>datastore" line per entry under hosts:
  awk -v sq="'" -v dq='"' "$AWK_CLEAN"'
    function flush() { if (h != "") print h "\t" d; h = ""; d = "" }
    function setkv(s,  k, v) {
      k = s; sub(/[ \t]*:.*/, "", k); v = s; sub(/^[^:]*:/, "", v); v = clean(v)
      if (k == "host" || k == "name") h = v; else if (k == "datastore") d = v
    }
    { sub(/\r$/, "") }
    /^[ \t]*(#.*)?$/ { next }
    /^[^ \t-]/ { flush(); inh = ($0 ~ /^hosts[ \t]*:/); next }
    !inh { next }
    /^[ \t]*-/ {
      flush(); s = $0; sub(/^[ \t]*-[ \t]*/, "", s)
      if (s ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:([ \t]|$)/) setkv(s); else h = clean(s)
      next
    }
    /^[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ { s = $0; sub(/^[ \t]+/, "", s); setkv(s) }
    END { flush() }' "$CONF"
}

BUNDLE=$(yaml_get bundle); PROFILE=$(yaml_get profile); BUILD=$(yaml_get build)
SHA256=$(yaml_get sha256); DSPATTERN=$(yaml_get datastore); SSHUSER=$(yaml_get user); SRC=$(yaml_get source)
[ -n "$BUNDLE" ] && [ -n "$PROFILE" ] && [ -n "$BUILD" ] || die "$CONF needs bundle, profile and build"
: "${DSPATTERN:=auto}" "${SSHUSER:=root}" "${SRC:=$DIR/$BUNDLE}"
LOG=esx-upgrade-$BUILD.log

ds_path() { # host short override -> datastore path, or "auto"
  p=$(printf '%s' "${3:-$DSPATTERN}" | sed -e "s|{short}|$(esc "$2")|g" -e "s|{host}|$(esc "$1")|g")
  case $p in auto|/*) printf '%s' "$p" ;; *) printf '%s' "$VOLROOT/$p" ;; esac
}

# ---- select hosts; the host running this goes last
ME=$(hostname 2>/dev/null); ME=$(lc "${ME%%.*}")
ALL=$(yaml_hosts)
[ -n "$ALL" ] || die "no hosts under hosts: in $CONF"
SEL=""; LOCAL=""
while IFS="$TAB" read -r host ds; do
  [ -n "$host" ] || continue
  case $host in *[!0-9.]*) short=${host%%.*} ;; *) short=$host ;; esac
  if [ $# -gt 0 ]; then
    keep=""
    for f in "$@"; do { [ "$f" = "$host" ] || [ "$f" = "$short" ]; } && keep=1; done
    [ -n "$keep" ] || continue
  fi
  line=$host$TAB$short$TAB$(ds_path "$host" "$short" "$ds")
  if [ -n "$ME" ] && [ "$(lc "$short")" = "$ME" ]; then LOCAL=$line; else SEL=$SEL$line$NL; fi
done <<EOF
$ALL
EOF
[ -n "$LOCAL" ] && SEL=$SEL$LOCAL$NL
for f in "$@"; do
  printf '%s' "$SEL" | awk -F "$TAB" -v f="$f" '$1 == f || $2 == f {x = 1} END {exit !x}' || die "not in $CONF: $f"
done

if [ "$ACTION" = list ]; then
  echo "host list: $CONF"
  echo "bundle:    $BUNDLE"
  echo "source:    $SRC $([ -f "$SRC" ] && echo "(found)" || echo "(NOT FOUND)")"
  echo "profile:   $PROFILE"
  echo "build:     $BUILD"
  echo "sha256:    ${SHA256:-not set}"
  echo "user:      $SSHUSER"
  echo
  while IFS="$TAB" read -r host short dsp; do
    [ -n "$host" ] || continue
    note=""; [ -n "$ME" ] && [ "$(lc "$short")" = "$ME" ] && note="  (this host, runs last)"
    printf '  %-30s %s%s\n' "$host" "$dsp" "$note"
  done <<EOF
$SEL
EOF
  exit 0
fi

# ---- bundle checks
# ---- ssh client: hosts.yaml ssh:, then PATH, then ESX's own OpenSSH directory
SSHBIN=$(yaml_get ssh)
if [ -z "$SSHBIN" ]; then
  for c in ssh /usr/lib/vmware/openssh/bin/ssh /usr/bin/ssh /bin/ssh; do
    case $c in
      /*) [ -x "$c" ] && { SSHBIN=$c; break; } ;;
      *)  p=$(command -v "$c" 2>/dev/null) && [ -n "$p" ] && { SSHBIN=$p; break; } ;;
    esac
  done
fi
if printf '%s' "$SEL" | awk -F "$TAB" -v me="$ME" 'me == "" || tolower($2) != me {x = 1} END {exit !x}'; then
  [ -n "$SSHBIN" ] && [ -x "$SSHBIN" ] || die "no ssh client found (looked in PATH and /usr/lib/vmware/openssh/bin).
Set ssh: /path/to/ssh in hosts.yaml, or run this script from a Linux, macOS or WSL machine with the zip next to it."
fi

sha256_of() { # prints the hash with whatever this machine has, or nothing
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    for py in python3 python; do
      command -v "$py" >/dev/null 2>&1 || continue
      "$py" -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1048576), b""):
        h.update(b)
print(h.hexdigest())' "$1"
      return
    done
  fi
}

if [ "$ACTION" != check ]; then
  [ -f "$SRC" ] || die "bundle not found: $SRC"
  SIZE=$(ls -l "$SRC" | awk '{print $5}')
  if [ -n "$SHA256" ]; then
    echo "checking sha256 of $SRC ..."
    sum=$(sha256_of "$SRC")
    if [ -z "$sum" ]; then
      echo "no sha256 tool on this machine - skipping the checksum"
    elif [ "$(lc "$sum")" != "$(lc "$SHA256")" ]; then
      die "sha256 mismatch - re-download $BUNDLE"
    fi
  fi
fi


# ---- on ESX, outbound ssh needs the sshClient firewall rule for the run
FW=""
if command -v esxcli >/dev/null 2>&1; then
  FW=$(esxcli network firewall ruleset list | awk '$1 == "sshClient" {print $2}')
  [ "$FW" = false ] && esxcli network firewall ruleset set -e true -r sshClient
fi
cleanup() {
  [ "$FW" = false ] && esxcli network firewall ruleset set -e false -r sshClient
  rm -f "$TMP".*
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- what runs on each host (@X@ placeholders are filled in per host)
T_BUILD='case "$(vmware -v)" in *@BUILD@*) echo "RESULT OK already on build @BUILD@"; exit 0 ;; esac
'
T_DS='DS="@DS@"
if [ "$DS" = auto ]; then
  DS=$(esxcli storage filesystem list | awk "/ VMFS-[0-9]+ / && \$NF + 0 > 2000000000 {print \$1; exit}")
fi
'
T_NEEDDS='[ -n "$DS" ] && [ -d "$DS" ] || { echo "RESULT FAIL datastore ${DS:-auto} not found - this host has: $(echo $(ls @VOLROOT@))"; exit 3; }
DS=$(cd "$DS" && pwd -P)
ZIP="$DS/@ZIPNAME@"
'
T_COPY='if [ "$(ls -l "$ZIP" 2>/dev/null | awk "{print \$5}")" = "@SIZE@" ]; then
  echo "bundle already in $DS"
else
  echo "receiving bundle into $DS ..."
  cat > "$ZIP" || { echo "RESULT FAIL could not write $ZIP"; exit 4; }
  [ "$(ls -l "$ZIP" | awk "{print \$5}")" = "@SIZE@" ] || { echo "RESULT FAIL copy incomplete"; exit 5; }
fi
'
T_COPIED='echo "RESULT OK bundle in $DS"
'
T_UPGRADE='RUN="$DS/@LOG@.running"
if [ -f "$RUN" ]; then
  now=$(date +%s); t=$(cat "$RUN" 2>/dev/null)
  case $now in ""|*[!0-9]*) now=0 ;; esac
  case $t in ""|*[!0-9]*) t=0 ;; esac
  [ $((now - t)) -lt 7200 ] && { echo "RESULT OK update already running on this host"; exit 0; }
fi
esxcli system maintenanceMode set -e true >/dev/null 2>&1
esxcli system maintenanceMode get | grep -q Enabled || { echo "RESULT FAIL could not enter maintenance mode"; exit 6; }
echo "maintenance mode on, dry run ..."
if ! esxcli software profile update -d "$ZIP" -p "@PROFILE@" --dry-run > "$DS/@LOG@.dryrun" 2>&1; then
  tail -4 "$DS/@LOG@.dryrun"
  echo "RESULT FAIL dry run failed, nothing installed, host left in maintenance mode"; exit 7
fi
vim-cmd hostsvc/enable_ssh >/dev/null 2>&1
date +%s > "$RUN"
( trap "" HUP
  esxcli software profile update -d "$ZIP" -p "@PROFILE@" > "$DS/@LOG@" 2>&1
  rc=$?
  rm -f "$RUN"
  [ "$rc" -eq 0 ] && grep -q "Reboot Required: true" "$DS/@LOG@" &&
  esxcli system shutdown reboot -r "ESX @BUILD@ upgrade" >> "$DS/@LOG@" 2>&1
) </dev/null >/dev/null 2>&1 &
echo "RESULT OK update started - host reboots itself when done (log $DS/@LOG@)"
'
T_CHECK='v=$(vmware -v)
case "$v" in
  *@BUILD@*)
    esxcli system maintenanceMode set -e false >/dev/null 2>&1
    echo "RESULT OK $v, maintenance mode $(esxcli system maintenanceMode get)" ;;
  *)
    l=""; [ -n "$DS" ] && l=$(tail -2 "$DS/@LOG@" 2>/dev/null || tail -2 "$DS/@LOG@.dryrun" 2>/dev/null)
    [ -n "$DS" ] && [ -f "$DS/@LOG@.running" ] && l="update still running"
    echo "RESULT PENDING $v, maintenance mode $(esxcli system maintenanceMode get) $(set -f; echo $l)" ;;
esac
'

render() { # template datastore-path
  printf '%s' "$1" | sed -e "s|@DS@|$(esc "$2")|g" -e "s|@ZIPNAME@|$(esc "$BUNDLE")|g" \
    -e "s|@SIZE@|${SIZE:-0}|g" -e "s|@BUILD@|$(esc "$BUILD")|g" -e "s|@PROFILE@|$(esc "$PROFILE")|g" \
    -e "s|@LOG@|$(esc "$LOG")|g" -e "s|@VOLROOT@|$(esc "$VOLROOT")|g"
}

: > "$TMP.summary"
while IFS="$TAB" read -r host short dsp; do
  [ -n "$host" ] || continue
  case $ACTION in
    copy)    t=$T_DS$T_NEEDDS$T_COPY$T_COPIED ;;
    upgrade) t=$T_BUILD$T_DS$T_NEEDDS$T_COPY$T_UPGRADE ;;
    check)   t=$T_DS$T_CHECK ;;
  esac
  script=$(render "$t" "$dsp")
  input=$SRC; [ "$ACTION" = check ] && input=/dev/null
  out=$TMP.$short
  echo
  echo "==== $host"
  if [ -n "$ME" ] && [ "$(lc "$short")" = "$ME" ]; then
    sh -c "$script" < "$input" 2>&1 | show "$out"
  else
    # shellcheck disable=SC2086
    "$SSHBIN" $SSHOPTS "$SSHUSER@$host" "$script" < "$input" 2>&1 | show "$out"
  fi
  grep -q '^RESULT' "$out" || echo "RESULT FAIL could not connect or log in" >> "$out"
  printf '%-30s %s\n' "$host" "$(sed -n 's/^RESULT //p' "$out" | sed -n '$p')" >> "$TMP.summary"
done <<EOF
$SEL
EOF

echo
echo "==== summary: $ACTION"
cat "$TMP.summary"
[ "$ACTION" = upgrade ] && echo "Hosts reboot on their own. Run 'sh esx_push.sh check' in about 20 minutes."
exit 0
