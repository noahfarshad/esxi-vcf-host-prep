#!/bin/sh
# esx_ready.sh v1.12 - get standalone ESX hosts ready for VCF host commissioning:
# upgrade to build: if set, then fix hostname, vmkernels, uplinks, portgroups,
# disks, VMFS-6 datastores, certificate and maintenance mode. A host already in a
# cluster, managed by a vCenter or with a reboot pending is left alone.
#
#   sh esx_ready.sh [plan|apply|list] [host ...] [-f hosts.yaml] [--wipe-disks]
#     plan   show what would change (the default)
#     apply  change it; every host that ends "ready" in the final table can be
#            commissioned. --wipe-disks lets it destroy data: stale vSAN partitions,
#            and VMFS-5 datastores, which it recreates as VMFS-6
#     list   show how hosts.yaml was read, without connecting
#
# hosts.yaml holds only the hosts and the build (see hosts.example.yaml). The root
# password comes from ESXPW when sshpass is installed; otherwise ssh prompts.
# Runs under any POSIX sh: a jump box, or an ESX host (which then goes last).

# shellcheck disable=SC2012,SC2013,SC2016,SC2029,SC2086,SC2317,SC2329  # ls for sizes (as esx_push.sh), key names
# are single words, remote commands quoted,
# option strings split, the host-side block and the trap-called cleanup: all on purpose

VERSION=1.12
DIR=$(cd "$(dirname "$0")" && pwd)
SELF=$DIR/$(basename "$0")
CONF=$DIR/hosts.yaml
APPLY=0; WIPE=0; LIST=0; FILTERS=""
TMP=/tmp/esx_ready_run.$$
NL='
'

# ---- built in: VCF best practice, and how this behaves on real hosts. None of it varies
# by environment, so none of it is configuration.
SSHUSER=root                          # VCF commissions hosts as root
MGMT=vmk0                             # ESXi's management vmkernel, the only one kept
WANTPG="Management Network"           # ESXi's management portgroup, the only one kept
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"
                                      # new hosts have keys nobody knows yet
PROBE=8                               # seconds to wait when checking a host is up
POLL=20                               # seconds between checks on upgrading hosts
SETTLE=90                             # seconds after a host is back, before preparing it
WAIT_TIMEOUT=3600                     # seconds before giving up on a host coming back
AGENTWAIT=180                         # seconds for port 443 to serve a new certificate
STALE=7200                            # seconds before an unfinished update counts as dead
MINFREE=2000000000                    # bytes free to look for when the bundle's size is unknown;
                                      # otherwise it needs the bundle plus 256 MB

usage() { sed -n '2,/^$/p' "$SELF" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 2; }
die()   { echo "$*" >&2; exit 2; }
lc()    { printf '%s' "$1" | awk '{ print tolower($0) }'; }
esc()   { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
dur()   { if [ "$1" -ge 120 ]; then echo "$(($1 / 60)) min"; else echo "$1 s"; fi; }

while [ $# -gt 0 ]; do
  case $1 in
    plan|--dry-run) APPLY=0 ;;
    apply|--apply)  APPLY=1 ;;
    list)           LIST=1 ;;
    -f)             [ $# -ge 2 ] || usage; CONF=$2; shift ;;
    --wipe-disks)   WIPE=1 ;;
    -h|--help)      usage ;;
    -*)             die "unknown option: $1" ;;
    *)              FILTERS="$FILTERS $1" ;;
  esac
  shift
done
[ -f "$CONF" ] || die "host list not found: $CONF"
[ "$WIPE" = 1 ] && [ "$APPLY" = 0 ] && die "--wipe-disks goes with apply (plan already shows which disks need it)"

# ---- hosts.yaml: top-level "key: value" lines plus a hosts: list (as esx_push.sh reads it)
AWK_CLEAN='
function clean(v) {
  sub(/\r$/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
  if (length(v) >= 2 && ((substr(v, 1, 1) == dq && substr(v, length(v), 1) == dq) ||
                         (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)))
    v = substr(v, 2, length(v) - 2)
  return v
}'
yaml_get() {  # top-level key
  awk -v key="$1" -v sq="'" -v dq='"' "$AWK_CLEAN"'
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ {
      k = $0; sub(/[ \t]*:.*/, "", k)
      if (k == key) { v = $0; sub(/^[^:]*:/, "", v); print clean(v); exit }
    }' "$CONF"
}
yaml_hosts() {  # one "host|fqdn|datastore" line per entry under hosts:
  awk -v sq="'" -v dq='"' "$AWK_CLEAN"'
    function flush() { if (h != "") print h "|" f "|" d; h = ""; f = ""; d = "" }
    function setkv(s,  k, v) {
      k = s; sub(/[ \t]*:.*/, "", k); v = s; sub(/^[^:]*:/, "", v); v = clean(v)
      if (k == "host" || k == "name") h = v; else if (k == "fqdn") f = v; else if (k == "datastore") d = v
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

# ---- hosts.yaml: only facts about this environment
KEYS="hosts domain build bundle profile sha256 source datastore update_args"
for k in $(awk '/^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ { k = $0; sub(/[ \t]*:.*/, "", k); print k }' "$CONF"); do
  case " $KEYS " in *" $k "*) ;; *) die "$CONF: '$k' is not a key hosts.yaml takes. It takes: $KEYS" ;; esac
done
CONFDIR=$(cd "$(dirname "$CONF")" && pwd)
DOMAIN=$(yaml_get domain)
BUILD=$(yaml_get build); BUNDLE=$(yaml_get bundle); PROFILE=$(yaml_get profile)
SHA256=$(yaml_get sha256); SOURCE=$(yaml_get source); UARGS=$(yaml_get update_args)
DSPEC=$(yaml_get datastore); DSPEC=${DSPEC:-auto}
[ -z "$BUNDLE" ] || [ -n "$BUILD" ] || die "bundle: needs build: too - the build number the bundle installs"
LOGDIR=$CONFDIR/ready-logs
ULOGNAME=esx-upgrade-$BUILD.log

# ---- select hosts: "host|short|fqdn|datastore"; the host running this goes last
ALL=$(yaml_hosts)
[ -n "$ALL" ] || die "no hosts under hosts: in $CONF"
ME=$(hostname 2>/dev/null); ME=$(lc "${ME%%.*}")
SEL=""; LOCALLINE=""; LOCALSHORT=""
while IFS='|' read -r host fq hds; do
  [ -n "$host" ] || continue
  case $host in *[!0-9.]*) short=${host%%.*}; ip=0 ;; *) short=$host; ip=1 ;; esac
  if [ -n "$FILTERS" ]; then
    keep=""; for f in $FILTERS; do { [ "$f" = "$host" ] || [ "$f" = "$short" ]; } && keep=1; done
    [ -n "$keep" ] || continue
  fi
  if [ -z "$fq" ]; then
    if [ "$ip" = 1 ]; then die "$host is an IP address: put its FQDN under it in $CONF (fqdn: ...)"
    elif [ "$short" != "$host" ]; then fq=$host
    elif [ -n "$DOMAIN" ]; then fq=$host.$DOMAIN
    else die "$host has no domain: write it as an FQDN, or add domain: to $CONF"; fi
  fi
  ds=$(printf '%s' "${hds:-$DSPEC}" | sed -e "s|{short}|$(esc "$short")|g" -e "s|{host}|$(esc "$host")|g")
  line="$host|$short|$fq|$ds"
  if [ -n "$ME" ] && [ "$(lc "$short")" = "$ME" ]; then LOCALLINE=$line; LOCALSHORT=$short
  else SEL="$SEL$line$NL"; fi
done <<EOF
$ALL
EOF
[ -n "$LOCALLINE" ] && SEL="$SEL$LOCALLINE$NL"
for f in $FILTERS; do
  printf '%s' "$SEL" | awk -F'|' -v f="$f" '$1 == f || $2 == f { x = 1 } END { exit !x }' || die "not in $CONF: $f"
done
[ -n "$SEL" ] || die "no hosts selected"

# ---- the bundle on this machine, when hosts.yaml asks for upgrades
SRC=""; BSIZE=0; BUNDLE_WHY=""; SHA_DONE=0
if [ -n "$BUNDLE" ]; then
  case $SOURCE in "") SRC=$CONFDIR/$BUNDLE ;; /*) SRC=$SOURCE ;; *) SRC=$CONFDIR/$SOURCE ;; esac
  if [ -f "$SRC" ]; then BSIZE=$(ls -l "$SRC" | awk '{ print $5 }'); else BUNDLE_WHY="bundle not found on this machine: $SRC"; fi
fi

if [ "$LIST" = 1 ]; then
  echo "host list: $CONF"
  echo "build:     ${BUILD:-not set - builds are reported, not changed}"
  if [ -n "$BUNDLE" ]; then
    echo "bundle:    $BUNDLE"
    echo "source:    $SRC $([ -f "$SRC" ] && echo "(found)" || echo "(NOT FOUND)")"
    echo "profile:   ${PROFILE:-the one in the bundle ending -standard}"
    echo "sha256:    ${SHA256:-not set}"
    echo "datastore: $DSPEC"
    [ -n "$UARGS" ] && echo "update:    esxcli software profile update ... $UARGS"
  fi
  echo
  printf '%s' "$SEL" | while IFS='|' read -r host short fq ds; do
    note=""; [ "$short" = "$LOCALSHORT" ] && note="  (this host, runs last)"
    printf '  %-28s %-28s %s%s\n' "$host" "$fq" "$ds" "$note"
  done
  exit 0
fi

sha256_of() {  # the hash, with whatever this machine has; nothing if it has nothing
  if sha256sum /dev/null >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  elif openssl version >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{ print $NF }'
  elif shasum -a 256 /dev/null >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'
  else
    for py in python3 python; do
      "$py" -c '' >/dev/null 2>&1 || continue
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
check_bundle() {  # once per run, before the first copy
  [ "$SHA_DONE" = 1 ] && return 0
  [ -z "$BUNDLE_WHY" ] || return 1
  if [ -n "$SHA256" ]; then
    echo "  checking the sha256 of $SRC"
    sum=$(sha256_of "$SRC")
    if [ -z "$sum" ]; then echo "  no sha256 tool on this machine - skipping the checksum"
    elif [ "$(lc "$sum")" != "$(lc "$SHA256")" ]; then BUNDLE_WHY="sha256 of $SRC does not match $CONF - re-download $BUNDLE"; return 1; fi
  fi
  SHA_DONE=1
}

# ---- ssh: hosts.yaml ssh:, then PATH, then ESX's own OpenSSH
REMOTE=0; SSHBIN=""
printf '%s' "$SEL" | awk -F'|' -v me="$LOCALSHORT" 'NF && $2 != me { x = 1 } END { exit !x }' && REMOTE=1
if [ -z "$SSHBIN" ]; then
  if ssh -V >/dev/null 2>&1; then SSHBIN=ssh
  else for c in /usr/lib/vmware/openssh/bin/ssh /usr/bin/ssh /bin/ssh; do [ -x "$c" ] && { SSHBIN=$c; break; }; done; fi
fi
[ "$REMOTE" = 0 ] || [ -n "$SSHBIN" ] || die "no ssh client found. Set ssh: /path/to/ssh in $CONF"
SSHCMD=$SSHBIN
if [ -n "${ESXPW:-}" ] && sshpass -V >/dev/null 2>&1; then SSHPASS=$ESXPW; export SSHPASS; SSHCMD="sshpass -e $SSHBIN"; fi
# ESX won't start a shell from a long ssh command line, so the host-side script goes
# over stdin into a temp file in /tmp and runs from there
RUNNER='f=/tmp/esx_ready.$$; cat > "$f" || exit 1; sh "$f"; rc=$?; rm -f "$f"; exit $rc'

mkdir -p "$TMP" "$LOGDIR" || die "cannot create $TMP or $LOGDIR"
MUX="-o ControlMaster=no -o ControlPath=$TMP/cm-%r@%h:%p"
OPENED=""; FW=""
if [ "$REMOTE" = 1 ] && esxcli network firewall ruleset list >/dev/null 2>&1; then   # on ESX
  FW=$(esxcli network firewall ruleset list | awk '$1 == "sshClient" { print $2 }')
  [ "$FW" = false ] && esxcli network firewall ruleset set -e true -r sshClient
fi
cleanup() {
  for h in $OPENED; do $SSHBIN $SSHOPTS $MUX -O exit "$SSHUSER@$h" </dev/null >/dev/null 2>&1; done
  [ "$FW" = false ] && esxcli network firewall ruleset set -e false -r sshClient
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

awk '/^: <<.REMOTE_EOF.$/ { f = 1; next } /^REMOTE_EOF$/ { f = 0 } f' "$SELF" > "$TMP/payload.sh"
[ -s "$TMP/payload.sh" ] || die "cannot read the host-side script from $SELF"
render() {  # fqdn datastore -> the host-side script with this host's values in it
  sed -e "s|@APPLY@|$APPLY|g" -e "s|@WIPE@|$WIPE|g" -e "s|@FQDN@|$(esc "$1")|g" \
      -e "s|@MGMT@|$(esc "$MGMT")|g" -e "s|@WANTPG@|$(esc "$WANTPG")|g" \
      -e "s|@BUILD@|$(esc "$BUILD")|g" -e "s|@BUNDLE@|$(esc "$BUNDLE")|g" -e "s|@BSIZE@|$BSIZE|g" \
      -e "s|@PROFILE@|$(esc "$PROFILE")|g" -e "s|@DS@|$(esc "$2")|g" \
      -e "s|@MINFREE@|$MINFREE|g" -e "s|@STALE@|$STALE|g" -e "s|@UARGS@|$(esc "$UARGS")|g" \
      -e "s|@AGENTWAIT@|$AGENTWAIT|g" "$TMP/payload.sh"
}

is_local()   { [ -n "$LOCALSHORT" ] && [ "$1" = "$LOCALSHORT" ]; }
conn_close() { $SSHBIN $SSHOPTS $MUX -O exit "$SSHUSER@$1" </dev/null >/dev/null 2>&1; }
conn_open()  {  # one login per host; the connections after it reuse this one
  $SSHBIN $SSHOPTS $MUX -O check "$SSHUSER@$1" </dev/null >/dev/null 2>&1 && return 0
  if $SSHCMD $SSHOPTS -o ControlMaster=yes -o "ControlPath=$TMP/cm-%r@%h:%p" -fN "$SSHUSER@$1" \
       </dev/null >/dev/null 2>>"$LOGDIR/ssh.log"; then OPENED="$OPENED $1"; fi
}
reachable() {  # does the host answer ssh at all? needs no login
  out=$($SSHBIN $SSHOPTS -n -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=$PROBE "$SSHUSER@$1" true 2>&1) && { echo up; return; }
  case $out in *"ermission denied"*|*"uthentication"*) echo up ;; *) echo down ;; esac
}
HAVECURL=0; curl --version >/dev/null 2>&1 && HAVECURL=1
SOAP='<?xml version="1.0" encoding="UTF-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><RetrieveServiceContent xmlns="urn:vim25"><_this type="ServiceInstance">ServiceInstance</_this></RetrieveServiceContent></soap:Body></soap:Envelope>'
soap_build() {  # the build a host reports on 443: the unauthenticated call a vSphere client makes first
  [ "$HAVECURL" = 1 ] || return 0
  curl -sk --max-time "$PROBE" -H 'Content-Type: text/xml' -H 'SOAPAction: urn:vim25/5.0' --data "$SOAP" \
    "https://$1/sdk" 2>/dev/null | sed -n 's/.*<build>\([0-9][0-9]*\)<\/build>.*/\1/p' | head -n 1
}

# ---- per-host state lives in $TMP/<short>.state ("build state todo"), .note and .did
merge() {  # two comma lists ("-" is empty) -> one, without repeats
  out=""
  for x in $(printf '%s,%s' "$1" "$2" | awk -F, '{ for (i = 1; i <= NF; i++) print $i }'); do
    [ "$x" = - ] && continue
    case ",$out," in *",$x,"*) ;; *) out=${out:+$out,}$x ;; esac
  done
  printf '%s\n' "${out:--}"
}
record() {  # short, the host's latest STATUS line
  tag=""; b=""; st=""; did=""; todo=""; note=""
  read -r tag b st did todo note <<EOF
$2
EOF
  if [ "$tag" != STATUS ]; then b=-; st=problem; did=-; todo=-; note="no answer from the host"; fi
  echo "$b $st $todo" > "$TMP/$1.state"
  printf '%s\n' "$note" > "$TMP/$1.note"
  prev=$(cat "$TMP/$1.did" 2>/dev/null); merge "${prev:--}" "$did" > "$TMP/$1.did"
}
set_state() {  # short state note: an outcome the driver decides
  b=-; x=-; todo=-
  [ -f "$TMP/$1.state" ] && read -r b x todo < "$TMP/$1.state"
  echo "$b $2 $todo" > "$TMP/$1.state"; printf '%s\n' "$3" > "$TMP/$1.note"
}
state_of() { st=problem; [ -f "$TMP/$1.state" ] && read -r b st x < "$TMP/$1.state"; echo "$st"; }
show() {  # print the host's output as it arrives, less the machine-readable lines; keep it all
  : > "$1"
  while IFS= read -r l || [ -n "$l" ]; do
    printf '%s\n' "$l" >> "$1"
    case $l in "STATUS "*|"NEED-BUNDLE "*) ;; *) printf '%s\n' "$l" ;; esac
  done
}
run_pass() {  # host short fqdn datastore: run the host-side script once, show and record it
  pass=$LOGDIR/$2.pass
  echo "==== $1"
  if is_local "$2"; then
    render "$3" "$4" > "$TMP/local.sh"
    sh "$TMP/local.sh" </dev/null 2>&1 | show "$pass"
  else
    render "$3" "$4" | $SSHCMD $SSHOPTS $MUX "$SSHUSER@$1" "$RUNNER" 2>&1 | show "$pass"
  fi
  if ! grep -q '^STATUS ' "$pass"; then
    echo "  PROBLEM no answer from $1 (ssh or login failed)"
    printf '%s\n' "  PROBLEM no answer from $1 (ssh or login failed)" "STATUS - problem - - no answer from the host" >> "$pass"
  fi
  cat "$pass" >> "$LOGDIR/$2.log"
  record "$2" "$(grep '^STATUS ' "$pass" | tail -n 1)"
  echo
}
copy_bundle() {  # host short path-on-host
  if ! check_bundle; then echo "  PROBLEM $BUNDLE_WHY"; return 1; fi
  echo "  copying $BUNDLE to $1 ($((BSIZE / 1048576)) MB)"
  if is_local "$2"; then
    cp "$SRC" "$3.part" && mv "$3.part" "$3" && { echo "  copied"; return 0; }
  elif $SSHCMD $SSHOPTS $MUX "$SSHUSER@$1" "cat > '$3.part' && mv '$3.part' '$3'" < "$SRC"; then
    echo "  copied"; return 0
  fi
  echo "  PROBLEM copying the bundle to $1 failed"; return 1
}
one_host() {  # host short fqdn datastore: a pass, the bundle if it asks, and a second pass
  is_local "$2" || conn_open "$1"
  run_pass "$1" "$2" "$3" "$4"
  if [ "$APPLY" = 1 ] && [ "$(state_of "$2")" = need-bundle ]; then
    path=$(sed -n 's/^NEED-BUNDLE //p' "$LOGDIR/$2.pass" | tail -n 1)
    if copy_bundle "$1" "$2" "$path"; then run_pass "$1" "$2" "$3" "$4"
    else set_state "$2" problem "the bundle could not be copied over"; fi
  fi
}
wait_for_upgrades() {  # each host in $TMP/wait: back on build:, then its 1-7 pass
  now=$(date +%s)
  while IFS='|' read -r host short fq ds; do echo "$now" > "$TMP/$short.t0"; done < "$TMP/wait"
  echo "==== waiting for $(awk 'END { print NR }' "$TMP/wait") host(s) to finish upgrading: $(awk -F'|' '{ printf "%s%s", s, $2; s = " " }' "$TMP/wait")"
  echo "     up to $(dur "$WAIT_TIMEOUT"), checking every ${POLL}s. Ctrl-C is safe: apply again resumes."
  while [ -s "$TMP/wait" ]; do
    sleep "$POLL"; now=$(date +%s); : > "$TMP/wait.next"
    while IFS='|' read -r host short fq ds; do
      b=$(soap_build "$host"); down=0; [ -f "$TMP/$short.down" ] && down=1
      if [ "$b" = "$BUILD" ] || { [ "$down" = 1 ] && [ "$(reachable "$host")" = up ]; }; then
        echo "  $host is back${b:+ on build $b}; giving it ${SETTLE}s to settle"
        sleep "$SETTLE"; conn_close "$host"; conn_open "$host"; run_pass "$host" "$short" "$fq" "$ds"
        continue
      fi
      if [ "$down" = 0 ] && [ -z "$b" ] && [ "$(reachable "$host")" = down ]; then
        : > "$TMP/$short.down"; conn_close "$host"; echo "  $host is rebooting"
      fi
      t0=$(cat "$TMP/$short.t0")
      if [ $((now - t0)) -ge "$WAIT_TIMEOUT" ]; then
        set_state "$short" problem "not back on $BUILD after $(dur "$WAIT_TIMEOUT") - apply again once it is"
        echo "  PROBLEM $host is not back on $BUILD after $(dur "$WAIT_TIMEOUT") - see $ULOGNAME on its datastore, then apply again"
        continue
      fi
      echo "$host|$short|$fq|$ds" >> "$TMP/wait.next"
    done < "$TMP/wait"
    mv "$TMP/wait.next" "$TMP/wait"
  done
  echo
}
print_table() {  # one line per host; returns how many are not ready
  w=4
  while IFS='|' read -r host short fq ds; do [ ${#host} -gt "$w" ] && w=${#host}; done <<EOF
$SEL
EOF
  if [ "$APPLY" = 1 ]; then echo "==== result"; else echo "==== plan"; fi
  printf "%-${w}s  %-21s  %s\n" HOST BUILD STATE
  nr=0
  while IFS='|' read -r host short fq ds; do
    [ -n "$host" ] || continue
    b=-; st=problem; todo=-
    [ -f "$TMP/$short.state" ] && read -r b st todo < "$TMP/$short.state"
    note=$(cat "$TMP/$short.note" 2>/dev/null); did=$(cat "$TMP/$short.did" 2>/dev/null)
    [ "$todo" = - ] && todo=""; [ "$did" = - ] && did=""
    todo=$(printf '%s' "$todo" | sed 's/,/, /g'); did=$(printf '%s' "$did" | sed 's/,/, /g')
    if [ -n "$BUILD" ] && [ "$b" != - ] && [ "$b" != "$BUILD" ]; then b="$b -> $BUILD"; fi
    case $st in
      ready)      txt="ready${did:+ (did: $did)}" ;;
      todo)       txt="to do: $todo" ;;
      upgrade)    rest=$(printf '%s' "$todo" | sed 's/upgrade\(, \)\{0,1\}//'); txt="upgrade${rest:+, then: $rest}" ;;
      upgrading)  txt="upgrade in progress - apply again to finish it" ;;
      rebooting)  txt="rebooting into the new build - apply again to finish it" ;;
      left-alone) txt="left alone: $note" ;;
      *)          txt="PROBLEM: $(printf '%s' "${note:-see its output above}" | awk '{ s = $0; if (length(s) > 80) s = substr(s, 1, 77) "..."; print s }')" ;;
    esac
    [ "$st" = ready ] || nr=$((nr + 1))
    printf "%-${w}s  %-21s  %s\n" "$host" "$b" "$txt"
  done <<EOF
$SEL
EOF
  return "$nr"
}

# ---- run
mode="PLAN - nothing will be changed"
[ "$APPLY" = 1 ] && mode="APPLY - changes will be made"
[ "$WIPE" = 1 ] && mode="$mode, INCLUDING DISK WIPES"
echo "esx_ready.sh v$VERSION   $(date '+%Y-%m-%d %H:%M:%S')   $mode"
echo "host list: $CONF   build: ${BUILD:-not set}   management: $MGMT on '$WANTPG'"
if [ -n "$BUILD" ] && [ -n "$BUNDLE" ]; then
  if [ -n "$BUNDLE_WHY" ]; then echo "bundle: $BUNDLE_WHY"
  else echo "bundle: $SRC ($((BSIZE / 1048576)) MB)${PROFILE:+, profile $PROFILE}, datastore $DSPEC"; fi
elif [ -n "$BUILD" ]; then
  echo "bundle: not set - hosts on another build are reported, not upgraded"
fi
[ -n "$LOCALSHORT" ] && echo "running on $LOCALSHORT: it goes last"
[ "$HAVECURL" = 1 ] || echo "note: no curl here, so waiting on upgrades watches ssh only"
echo
: > "$TMP/wait"
while IFS='|' read -r host short fq ds; do
  [ -n "$host" ] || continue
  is_local "$short" && continue
  one_host "$host" "$short" "$fq" "$ds"
  case $(state_of "$short") in upgrading|rebooting) [ "$APPLY" = 1 ] && echo "$host|$short|$fq|$ds" >> "$TMP/wait" ;; esac
done <<EOF
$SEL
EOF
[ "$APPLY" = 1 ] && [ -s "$TMP/wait" ] && wait_for_upgrades
if [ -n "$LOCALLINE" ]; then   # the host running this: last, after everything else is done
  IFS='|' read -r host short fq ds <<EOF
$LOCALLINE
EOF
  one_host "$host" "$short" "$fq" "$ds"
  case $(state_of "$short") in upgrading|rebooting)
    echo "  $host is upgrading itself and reboots when done. Run apply here again once it's back."; echo ;;
  esac
fi
print_table && exit 0
exit 1

# ------------------------------------------------------------------ host side
# Runs on each host under busybox sh, which has no tr and no working 'command -v'.
# Never executed here. @X@ are filled in per host.
: <<'REMOTE_EOF'
APPLY=@APPLY@; WIPE=@WIPE@; FQDN='@FQDN@'; MGMT='@MGMT@'; WANTPG='@WANTPG@'
BUILD='@BUILD@'; BUNDLE='@BUNDLE@'; BSIZE='@BSIZE@'; PROFILE='@PROFILE@'; DS='@DS@'; UARGS='@UARGS@'
MINFREE='@MINFREE@'; STALE='@STALE@'; AGENTWAIT='@AGENTWAIT@'
CHANGED=0; PROBLEM=0; STEP=""; TODO=""; DID=""; NOTE=""; LEFT=0; UPSTATE=""
say()  { echo "  $*"; }
addstep() { case ",$1," in *",$STEP,"*) printf '%s' "$1" ;; *) printf '%s' "${1:+$1,}$STEP" ;; esac; }
act()  { echo "  CHANGE $*"; CHANGED=$((CHANGED+1)); DID=$(addstep "$DID"); }
plan() { echo "  WOULD  $*"; CHANGED=$((CHANGED+1)); TODO=$(addstep "$TODO"); }
bad()  { echo "  PROBLEM $*"; PROBLEM=$((PROBLEM+1)); [ -n "$NOTE" ] || NOTE=$*; }
do_or_plan() { d=$1; shift
  if [ "$APPLY" = 1 ]; then
    if out=$("$@" 2>&1); then act "$d"; else bad "$d failed: $out"; fi
  else plan "$d"; fi
}

# ---- helpers
SSL=/etc/vmware/ssl
RESTART=0
cert_names() {  # PEM on stdin -> the names it answers to, lowercased: DNS SANs, else the CN
  openssl x509 -noout -text 2>/dev/null | awk '
    san == 1 { n = split($0, p, ",")
               for (i = 1; i <= n; i++) { s = p[i]; gsub(/^[ \t]+|[ \t]+$/, "", s)
                 if (s ~ /^DNS:/) { print tolower(substr(s, 5)); found = 1 } }
               san = 2 }
    /X509v3 Subject Alternative Name/ { san = 1 }
    /^[ \t]*Subject:/ && cn == "" {
      if (match($0, /CN *= *[^,\/]+/)) { cn = substr($0, RSTART, RLENGTH); sub(/^CN *= */, "", cn); gsub(/[ \t]+$/, "", cn) } }
    END { if (!found && cn != "") print tolower(cn) }'
}
names_match() {  # $1 names, one per line; $2 the FQDN wanted
  printf '%s\n' "$1" | awk -v w="$2" '
    $0 == w { m = 1 }
    substr($0, 1, 2) == "*." { i = index(w, "."); if (i && substr(w, i + 1) == substr($0, 3)) m = 1 }
    END { exit !m }'
}
esxi_default_cert() {  # the certificate ESXi generates for itself, as opposed to one a CA issued
  subj=$(openssl x509 -in "$SSL/rui.crt" -noout -subject 2>/dev/null | sed 's/^subject= *//')
  iss=$(openssl x509 -in "$SSL/rui.crt" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
  case "$subj $iss" in *"ESX Server Default Certificate"*|*"VMware Installer"*) return 0 ;; esac
  [ -n "$iss" ] && [ "$iss" = "$subj" ]
}
served_names() { echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | cert_names; }
# ESX's busybox has no tr: awk does the lowercasing and line joining
lower()   { printf '%s\n' "$1" | awk '{ print tolower($0) }'; }
oneline() { printf '%s\n' "$1" | awk 'NF { printf "%s%s", sep, $0; sep = " " }'; }

fsize() { ls -l "$1" 2>/dev/null | awk '{ print $5; exit }'; }
ULOG="esx-upgrade-$BUILD.log"   # esx_push.sh's names too, so each tool sees the other's update
# room for the bundle, plus a little. ESX's shell compares and adds in 32 bits, so every
# byte-sized number here is handled by awk, never by the shell
NEED=$(awk -v b="$BSIZE" -v m="$MINFREE" 'BEGIN { printf "%.0f", (b + 0 > 0 ? b + 268435456 : m) }')
NEEDMB=$(awk -v n="$NEED" 'BEGIN { printf "%d", n / 1048576 }')
vols() {  # storage that could hold the bundle: "mount|free|local|name" per line. Sizes are
          # far past what a shell can compare, so awk does the reading and the arithmetic.
          # A VMFS datastore other hosts can see counts as not local: their logs would mix with ours
  esxcli storage filesystem list 2>/dev/null | awk \
    -v loc=" $(esxcli storage core device list 2>/dev/null | awk '/^[^ ]/ { d = $1 } /Is Local: true/ { printf "%s ", d }')" \
    -v ext="$(esxcli storage vmfs extent list 2>/dev/null | awk 'NR > 2 && NF >= 5 { printf "%s=%s ", $(NF-3), $(NF-1) }')" '
    BEGIN { n = split(ext, E, " ")
            for (i = 1; i <= n; i++) { p = index(E[i], "="); if (p > 1) dev[substr(E[i], 1, p - 1)] = dev[substr(E[i], 1, p - 1)] " " substr(E[i], p + 1) } }
    $(NF-3) == "true" && $(NF-2) ~ /^(VMFS-[0-9]+|VMFSOS|VMFS-L)$/ {
      name = $2; for (i = 3; i <= NF - 5; i++) name = name " " $i
      mount = $1; type = $(NF-2); islocal = 1
      if (type ~ /^VMFS-[0-9]+$/) {
        u = mount; sub(/.*\//, "", u)
        if (!(u in dev)) islocal = 0
        else { m = split(dev[u], D, " "); for (i = 1; i <= m; i++) if (index(loc, " " D[i] " ") == 0) islocal = 0 }
      }
      printf "%s|%.0f|%d|%s\n", mount, $NF + 0, islocal, name }'
}
storage_note() {  # for messages: what this host has, and how much room (no sort: ESX may not have one)
  vols | awk -F'|' '
    { u = ($2 + 0 >= 1000000000) ? sprintf("%d GB", $2 / 1000000000) : sprintf("%d MB", $2 / 1048576)
      printf "%s%s (%s free%s)", sep, $4, u, ($3 == 1 ? "" : ", shared - skipped"); sep = ", " }
    END { if (sep == "") printf "nothing it could stage the bundle on" }'
}
ds_dir() {  # where the bundle lives on this host: "physical path|why", or nothing. A datastore:
            # from hosts.yaml is used when the host has it; otherwise the largest local storage
  pre=""
  case $DS in
    auto) ;;
    /*) if [ -d "$DS" ]; then printf '%s|%s\n' "$(cd "$DS" && pwd -P || printf '%s' "$DS")" "datastore: in hosts.yaml"; return; fi
        pre="$DS is not on this host, so " ;;
    *)  if [ -d "/vmfs/volumes/$DS" ]; then
          printf '%s|%s\n' "$(cd "/vmfs/volumes/$DS" && pwd -P || printf '%s' "/vmfs/volumes/$DS")" "datastore: in hosts.yaml"; return
        fi
        pre="$DS is not on this host, so " ;;
  esac
  rows=$(vols)
  oifs=$IFS; IFS='
'
  for r in $rows; do IFS=$oifs; m=${r%%|*}   # an earlier run's bundle or update: stay with it
    if [ -f "$m/$BUNDLE" ] || [ -f "$m/$ULOG" ] || [ -f "$m/$ULOG.running" ]; then
      printf '%s|%s\n' "$m" "${pre}the bundle or its update log is already there"; return
    fi
    IFS='
'
  done
  IFS=$oifs
  # the largest local one with room, chosen in awk: esxcli reports its mount point as the real path
  best=$(printf '%s\n' "$rows" | awk -F'|' -v need="$NEED" '
    $3 == 1 && $2 + 0 >= need + 0 && $2 + 0 > top + 0 { top = $2 + 0; m = $1; f = $2 + 0 }
    END { if (m != "") printf "%s|%s", m, (f >= 1000000000 ? sprintf("%d GB", f / 1000000000) : sprintf("%d MB", f / 1048576)) }')
  [ -n "$best" ] || return 0
  printf '%s|%s\n' "${best%%|*}" "${pre}the largest local storage, ${best#*|} free"
}

# ---- 0. what is this host? Leave anything already in use alone
summary=$(vim-cmd hostsvc/hostsummary 2>/dev/null)
field() { printf '%s\n' "$summary" | awk -v k="$1" '$1 == k { v = $3; gsub(/[",]/, "", v); print v; exit }'; }
mgmtsrv=$(field managementServerIp)
reboot=$(field rebootRequired)
portset=$(esxcli network ip interface list 2>/dev/null \
  | awk -v m="$MGMT" '$1==m{f=1} f&&/Portset:/{sub(/^ *Portset: */,""); print; exit}')
build=$(vmware -v 2>/dev/null | sed -n 's/.*build-\([0-9][0-9]*\).*/\1/p')
mm=$(esxcli system maintenanceMode get 2>/dev/null)
dsdir=""; dswhy=""; zip=""; ulog=""; run=""; running=0; installed=0
if [ -n "$BUILD" ] && [ -n "$BUNDLE" ]; then
  sel=$(ds_dir); dsdir=${sel%%|*}; dswhy=${sel#*|}
  if [ -n "$dsdir" ]; then
    zip="$dsdir/$BUNDLE"; ulog="$dsdir/$ULOG"; run="$ulog.running"
    if [ -f "$run" ]; then   # an update under way, started by this tool or by esx_push.sh
      now=$(date +%s); t=$(cat "$run" 2>/dev/null)
      case $now in ""|*[!0-9]*) now=0 ;; esac
      case $t in ""|*[!0-9]*) t=0 ;; esac
      if [ $((now - t)) -lt "$STALE" ]; then running=1
      else say "an update started over $((STALE / 60)) minutes ago never finished"; [ "$APPLY" = 1 ] && rm -f "$run"; fi
    fi
    if [ "$running" = 0 ] && [ "$build" != "$BUILD" ] && [ -f "$ulog" ] && grep -q "Reboot Required: true" "$ulog"; then
      installed=1
    fi
  fi
fi
case $portset in
  *[Dd][Vv][Ss]*) bad "$MGMT is on a distributed switch ($portset) - already in a cluster, not touching this host"
                  LEFT=1; NOTE="in a cluster" ;;
esac
case $mgmtsrv in
  ""|"<unset>") ;;
  *) bad "managed by the vCenter at $mgmtsrv - remove it from that vCenter first; not touching this host"
     LEFT=1; NOTE="managed by the vCenter at $mgmtsrv" ;;
esac
if [ "$reboot" = true ] && [ "$running" = 0 ] && [ "$installed" = 0 ]; then
  bad "a reboot is pending that no upgrade from this tool explains - reboot, then re-run; not touching this host"
  LEFT=1; NOTE="reboot pending"
fi
[ "$LEFT" = 0 ] && say "standalone host, build ${build:-unknown}, maintenance mode ${mm:-unknown}"

# ---- upgrade: get to build: when bundle: says how. The start is esx_push.sh's, as proven
STEP=upgrade
if [ "$LEFT" = 0 ] && [ -n "$BUILD" ]; then
  if [ "$build" = "$BUILD" ]; then
    :
  elif [ -z "$build" ]; then
    bad "cannot read this host's build"; UPSTATE=blocked
  elif [ -z "$BUNDLE" ]; then
    bad "on build $build, hosts.yaml wants $BUILD - add bundle: to upgrade it here"; UPSTATE=blocked
  elif [ -z "$dsdir" ]; then
    if [ "$DS" = auto ]; then bad "no local storage with room for the bundle ($NEEDMB MB needed) - this host has: $(storage_note)"
    else bad "datastore $DS is not on this host, and no other local storage has room ($NEEDMB MB needed) - this host has: $(storage_note)"; fi
    UPSTATE=blocked
  elif [ "$running" = 1 ]; then
    say "update to $BUILD running (log: $ulog)"; UPSTATE=upgrading
  elif [ "$installed" = 1 ] && [ "$reboot" = true ]; then
    say "update to $BUILD installed; the host is about to reboot"; UPSTATE=rebooting
  elif [ "$installed" = 1 ]; then
    tail -n 4 "$ulog" | awk 'NF { print "    | " $0 }'
    bad "the update to $BUILD installed, but the host came back on $build - see $ulog"
    [ "$APPLY" = 1 ] && mv -f "$ulog" "$ulog.failed"
    UPSTATE=blocked
  elif [ -f "$ulog" ]; then   # the last attempt ran and did not succeed
    tail -n 6 "$ulog" | awk 'NF { print "    | " $0 }'
    bad "the last update attempt failed: $(awk 'NF { sub(/^ +/, ""); printf "%s%s", sep, $0; sep = " "; if (++n == 2) exit }' "$ulog") (log: $ulog)"
    [ "$APPLY" = 1 ] && mv -f "$ulog" "$ulog.failed"   # so the next apply tries again
    UPSTATE=blocked
  else
    UPSTATE=upgrade
    say "bundle location: $dsdir - $dswhy"
    have=$(fsize "$zip"); have=${have:-0}
    if [ "$have" = 0 ] || { [ "$BSIZE" != 0 ] && [ "$have" != "$BSIZE" ]; }; then
      if [ "$BSIZE" = 0 ]; then bad "$BUNDLE is not on this host, and not on the machine running this either"; UPSTATE=blocked
      elif [ "$APPLY" = 1 ]; then echo "NEED-BUNDLE $zip"; UPSTATE=need-bundle
      else plan "copy $BUNDLE to $dsdir"; fi
    fi
    if [ "$UPSTATE" = upgrade ]; then
      prof=$PROFILE
      if [ -z "$prof" ] && [ "$have" != 0 ]; then
        prof=$(esxcli software sources profile list -d "$zip" 2>/dev/null | awk 'NR > 2 && $1 ~ /-standard$/ { print $1 }')
      fi
      if [ "$APPLY" != 1 ]; then
        plan "upgrade $build -> $BUILD${prof:+ with $prof}: maintenance mode, then the host reboots itself"
      elif [ -z "$prof" ] || [ "$(printf '%s\n' "$prof" | awk 'END { print NR }')" != 1 ]; then
        bad "cannot pick one image profile in $BUNDLE - set profile: in hosts.yaml"; UPSTATE=blocked
      else
        left=""
        dry=$(esxcli software profile update -d "$zip" -p "$prof" $UARGS --dry-run 2>&1); rc=$?
        if [ "$rc" != 0 ]; then
          case $dry in *[Mm]aintenance*)   # in case this build only dry-runs in maintenance mode
            esxcli system maintenanceMode set -e true >/dev/null 2>&1 && left=", host left in maintenance mode"
            dry=$(esxcli software profile update -d "$zip" -p "$prof" $UARGS --dry-run 2>&1); rc=$? ;;
          esac
        fi
        printf '%s\n' "$dry" > "$ulog.dryrun"
        if [ "$rc" != 0 ]; then
          printf '%s\n' "$dry" | awk 'NF && n++ < 8 { print "    | " $0 }'
          bad "update dry run failed, nothing installed$left: $(printf '%s\n' "$dry" | awk 'NF { sub(/^ +/, ""); printf "%s%s", sep, $0; sep = " "; if (++n == 2) exit }')"
          case $dry in *no-hardware-warning*)
            say "to go ahead despite these hardware warnings, add  update_args: --no-hardware-warning  to hosts.yaml" ;;
          esac
          UPSTATE=blocked
        else
          esxcli system maintenanceMode set -e true >/dev/null 2>&1
          if ! esxcli system maintenanceMode get 2>/dev/null | grep -q Enabled; then
            bad "could not enter maintenance mode - update not started"; UPSTATE=blocked
          else
            vim-cmd hostsvc/enable_ssh >/dev/null 2>&1   # SSH has to be on after the reboot
            date +%s > "$run"
            ( trap "" HUP
              esxcli software profile update -d "$zip" -p "$prof" $UARGS > "$ulog" 2>&1
              rc=$?
              rm -f "$run"
              [ "$rc" -eq 0 ] && grep -q "Reboot Required: true" "$ulog" &&
              esxcli system shutdown reboot -r "ESX $BUILD upgrade" >> "$ulog" 2>&1
            ) </dev/null >/dev/null 2>&1 &
            act "start the update $build -> $BUILD with $prof; the host reboots itself when it's done"
            UPSTATE=upgrading
          fi
        fi
      fi
    fi
  fi
fi

# ---- 1-7 run on a host on the right build; plan also looks ahead on one due an upgrade
if [ "$LEFT" = 0 ] && { [ -z "$UPSTATE" ] || { [ "$APPLY" != 1 ] && [ "$UPSTATE" = upgrade ]; }; }; then

# ---- 1. hostname
STEP=hostname
cur=$(esxcli system hostname get 2>/dev/null | sed -n 's/^ *Fully Qualified Domain Name: *//p')
if [ -z "$FQDN" ]; then
  case $cur in
    *.*) say "hostname is $cur (not checked: add fqdn: under this host to enforce one)" ;;
    *)   bad "hostname '$cur' is not an FQDN, and none could be inferred - add fqdn: under this host in the list" ;;
  esac
elif [ "$cur" = "$FQDN" ]; then
  say "hostname OK ($cur)"
else
  short=${FQDN%%.*}
  case $FQDN in *.*) dom=${FQDN#*.} ;; *) dom="" ;; esac
  if [ "$APPLY" = 1 ]; then
    if [ -n "$dom" ]; then out=$(esxcli system hostname set --host="$short" --domain="$dom" 2>&1)
    else out=$(esxcli system hostname set --host="$short" 2>&1); fi
    if [ $? -eq 0 ]; then act "hostname $cur -> $FQDN"
    else bad "hostname set failed (host may still be domain-joined): $out"; fi
  else
    plan "hostname $cur -> $FQDN"
  fi
fi

# ---- 2. vmkernel adapters
STEP=vmkernels
mgmt_pg=$(esxcli network ip interface list 2>/dev/null \
  | awk -v m="$MGMT" '$1==m{f=1} f&&/Portgroup:/{sub(/^ *Portgroup: */,""); print; exit}')
vsw=$portset
if [ -z "$mgmt_pg" ] || [ -z "$vsw" ]; then
  bad "cannot find $MGMT and its switch - stopping before any change"
else
  say "management: $MGMT on portgroup '$mgmt_pg', switch $vsw"
  extra=$(esxcli network ip interface list 2>/dev/null \
    | awk -v m="$MGMT" '/^vmk[0-9]+$/ && $1!=m {print $1}')
  if [ -z "$extra" ]; then say "vmkernel adapters OK (only $MGMT)"
  else for v in $extra; do do_or_plan "remove vmkernel $v" esxcli network ip interface remove -i "$v"; done; fi

  # ---- 3. uplinks
  STEP=uplinks
  ups=$(esxcli network vswitch standard list 2>/dev/null \
    | awk -v s="$vsw" '$1==s{f=1} f&&/Uplinks:/{sub(/^ *Uplinks: */,""); gsub(/,/," "); print; exit}')
  nup=0; for u in $ups; do nup=$((nup+1)); done
  if [ "$nup" -le 1 ]; then
    say "uplinks OK ($vsw: ${ups:-none})"
    [ "$nup" -eq 0 ] && bad "$vsw has no uplink"
  else
    keep=""
    for u in $ups; do
      st=$(esxcli network nic list 2>/dev/null | awk -v n="$u" '$1==n{print $5}')
      [ "$st" = "Up" ] && { keep=$u; break; }
    done
    if [ -z "$keep" ]; then
      bad "no uplink on $vsw reports Link Up - not touching uplinks"
    else
      say "keeping uplink $keep (Link Up)"
      for u in $ups; do
        [ "$u" = "$keep" ] && continue
        do_or_plan "remove uplink $u from $vsw" \
          esxcli network vswitch standard uplink remove -u "$u" -v "$vsw"
      done
    fi
  fi

  # ---- 4. portgroups
  STEP=portgroups
  pgs=$(esxcli network vswitch standard portgroup list 2>/dev/null \
    | awk -v s="$vsw" 'NR>2 && NF { line=$0
        sub(/ +[^ ]+ +[0-9]+ +[0-9]+ *$/,"",line); sub(/ +$/,"",line)
        if (index($0, s)) print line }')
  RNL='
'
  OLDIFS=$IFS; IFS=$RNL
  for pg in $pgs; do
    IFS=$OLDIFS
    if [ -n "$pg" ] && [ "$pg" != "$mgmt_pg" ]; then
      do_or_plan "remove portgroup '$pg'" \
        esxcli network vswitch standard portgroup remove -p "$pg" -v "$vsw"
    fi
    IFS=$RNL
  done
  IFS=$OLDIFS

  if [ "$mgmt_pg" = "$WANTPG" ]; then
    say "management portgroup OK ($WANTPG)"
  else
    do_or_plan "rename portgroup '$mgmt_pg' -> '$WANTPG'" \
      esxcli network vswitch standard portgroup set -p "$mgmt_pg" -n "$WANTPG"
  fi
fi

# ---- 5. disks
STEP=disks
boot=$(esxcli storage core device list 2>/dev/null \
  | awk '/^[a-zA-Z0-9._:-]+$/{d=$1} /Is Boot Device: true/{print d}')
say "boot device: ${boot:-unknown}"
# devices under a VMFS datastore; Device Name is next to last (volume names can have spaces)
inuse=$(esxcli storage vmfs extent list 2>/dev/null | awk 'NR > 2 && NF >= 5 { print $(NF-1) }')
dirty=$(vdq -q 2>/dev/null | awk -F'"' '
  /"Name"/  {n=$4}
  /"State"/ {s=$4}
  /"Reason"/{r=$4; if (s ~ /Ineligible/ || s ~ /In-use/) print n "|" s "|" r}')
if [ -z "$dirty" ]; then
  say "disks OK (nothing ineligible or in use by vSAN)"
else
  say "disks needing attention:"
  oifs=$IFS; IFS='
'
  for row in $dirty; do
    IFS=$oifs
    dev=${row%%|*}; rest=${row#*|}; st=${rest%%|*}; rs=${rest#*|}
    [ -n "$dev" ] || continue
    if [ "$dev" = "$boot" ]; then say "skip $dev (boot device) - $st / $rs"; continue; fi
    skip=0; for m in $inuse; do [ "$m" = "$dev" ] && skip=1; done
    if [ "$skip" = 1 ]; then say "skip $dev (holds a VMFS datastore) - $st / $rs"; continue; fi
    if [ "$WIPE" != 1 ]; then
      if [ "$APPLY" = 1 ]; then bad "$dev needs wiping ($st / $rs) - run apply with --wipe-disks"
      else plan "wipe $dev ($st / $rs) - needs apply --wipe-disks"; fi
      continue
    fi
    esxcli vsan storage remove -d "$dev" >/dev/null 2>&1 \
      || esxcli vsan storage remove -u "$dev" >/dev/null 2>&1
    if partedUtil mklabel "/vmfs/devices/disks/$dev" gpt >/dev/null 2>&1; then act "wipe $dev ($st / $rs)"
    else bad "could not clear partitions on $dev"; fi
  done
  IFS=$oifs
fi
if [ "$WIPE" = 1 ]; then
  cl=$(esxcli vsan cluster get 2>/dev/null | sed -n 's/^ *Enabled: *//p')
  if [ "$cl" = "true" ]; then
    if esxcli vsan cluster leave >/dev/null 2>&1; then act "leave the old vSAN cluster"
    else bad "could not leave the old vSAN cluster"; fi
  fi
fi

# ---- 5b. local datastores are VMFS-6. With --wipe-disks a VMFS-5 one is recreated in
# place: unmounted, its partition reformatted as VMFS-6 under the same name, checked. The
# partition table is never edited. Never one other hosts can see, one spanning several
# extents, or one with registered VMs; if the reformat fails the old one is mounted again.
STEP=vmfs6
v5=$(esxcli storage filesystem list 2>/dev/null | awk '$(NF-3) == "true" && $(NF-2) == "VMFS-5" {
       n = $2; for (i = 3; i <= NF - 5; i++) n = n " " $i; print $1 "|" n }')
if [ -z "$v5" ]; then
  say "datastores OK (none VMFS-5)"
else
  locals=" $(esxcli storage core device list 2>/dev/null | awk '/^[^ ]/ { d = $1 } /Is Local: true/ { printf "%s ", d }')"
  exts=$(esxcli storage vmfs extent list 2>/dev/null | awk 'NR > 2 && NF >= 5 { print $(NF-3) "=" $(NF-1) ":" $NF }')
  vms=$(vim-cmd vmsvc/getallvms 2>/dev/null)
  oifs=$IFS; IFS='
'
  for row in $v5; do
    IFS=$oifs
    m=${row%%|*}; name=${row#*|}; u=${m##*/}; part=""; n=0; shared=0
    for e in $exts; do case $e in "$u="*) p=${e#*=}; n=$((n + 1)); part=$p
      case $locals in *" ${p%:*} "*) ;; *) shared=1 ;; esac ;; esac; done
    if [ "$n" = 0 ]; then say "skip $name (VMFS-5, but its disk could not be identified)"; continue; fi
    if [ "$shared" = 1 ]; then say "skip $name (VMFS-5, but other hosts can see it)"; continue; fi
    if [ "$n" != 1 ]; then bad "$name is VMFS-5 across $n extents - recreate it as VMFS-6 by hand"; continue; fi
    if printf '%s\n' "$vms" | grep -qF "[$name] "; then
      bad "$name is VMFS-5 and has registered VMs - move or unregister them first"; continue
    fi
    if [ "$WIPE" != 1 ]; then
      if [ "$APPLY" = 1 ]; then bad "$name is VMFS-5 - run apply with --wipe-disks to recreate it as VMFS-6 (wipes it)"
      else plan "recreate $name as VMFS-6 on $part (wipes it) - needs apply --wipe-disks"; fi
      continue
    fi
    if ! out=$(esxcli storage filesystem unmount -u "$u" 2>&1); then
      bad "cannot unmount $name to recreate it: $(printf '%s' "$out" | awk 'NF { print; exit }') - scratch, a core dump file or logs may live on it"
      continue
    fi
    if out=$(vmkfstools -C vmfs6 -S "$name" "/vmfs/devices/disks/$part" 2>&1); then
      vmkfstools -V >/dev/null 2>&1
      if esxcli storage filesystem list 2>/dev/null | awk -v want="$name" '{ n = $2; for (i = 3; i <= NF - 5; i++) n = n " " $i }
           n == want && $(NF-3) == "true" && $(NF-2) == "VMFS-6" { f = 1 } END { exit !f }'; then
        act "recreate $name as VMFS-6 on $part (its VMFS-5 contents are gone)"
      else bad "$name was recreated but does not show as a mounted VMFS-6 datastore - check the host's storage"; fi
    else
      esxcli storage filesystem mount -u "$u" >/dev/null 2>&1
      bad "could not recreate $name as VMFS-6: $(printf '%s' "$out" | awk 'NF { print; exit }') - the old datastore is mounted again"
    fi
  done
  IFS=$oifs
fi

# ---- 6. certificate: VCF connects by FQDN and rejects a certificate for any other name
STEP=certificate
now=$(esxcli system hostname get 2>/dev/null | sed -n 's/^ *Fully Qualified Domain Name: *//p')
want=$(lower "${FQDN:-$now}")
case $want in *.*) ;; *) want="" ;; esac
if [ -z "$want" ]; then
  say "certificate not checked (no FQDN to check it against)"
elif [ "$APPLY" = 1 ] && [ "$(lower "$now")" != "$want" ]; then
  say "certificate not checked: the hostname is not $want yet"
elif [ ! -s "$SSL/rui.crt" ] || ! openssl version >/dev/null 2>&1; then  # no 'command -v' on ESX's sh
  bad "cannot read $SSL/rui.crt with openssl - certificate not checked"
else
  have=$(cert_names < "$SSL/rui.crt")
  if [ -z "$have" ]; then
    bad "openssl read no name from $SSL/rui.crt - certificate not checked"
  elif names_match "$have" "$want"; then
    live=$(served_names)
    if [ -z "$live" ]; then
      say "certificate OK (names $want; port 443 not readable from the host)"
    elif names_match "$live" "$want"; then
      say "certificate OK (names $want)"
    elif [ "$APPLY" = 1 ]; then
      act "restart management agents: port 443 still serves [$(oneline "$live")]"; RESTART=1
    else
      plan "restart management agents: port 443 still serves [$(oneline "$live")]"
    fi
  elif ! esxi_default_cert; then
    bad "certificate is CA-issued and names [$(oneline "$have")], not $want - not replacing it; reissue it for $want"
  elif [ "$APPLY" = 1 ]; then
    ts=$(date +%Y%m%d%H%M%S)
    if mv "$SSL/rui.crt" "$SSL/rui.crt.$ts.bak" && mv "$SSL/rui.key" "$SSL/rui.key.$ts.bak"; then
      /sbin/generate-certificates >/dev/null 2>&1
      if [ -s "$SSL/rui.crt" ] && [ -s "$SSL/rui.key" ] && names_match "$(cert_names < "$SSL/rui.crt")" "$want"; then
        act "regenerate certificate [$(oneline "$have")] -> [$want], old pair kept as rui.*.$ts.bak"
        /sbin/auto-backup.sh >/dev/null 2>&1 || say "auto-backup.sh failed - run it before any reboot so the new certificate persists"
        RESTART=1
      else
        mv -f "$SSL/rui.crt.$ts.bak" "$SSL/rui.crt"; mv -f "$SSL/rui.key.$ts.bak" "$SSL/rui.key"
        bad "certificate regeneration failed - the original certificate is back in place"
      fi
    else
      [ -f "$SSL/rui.crt.$ts.bak" ] && [ ! -e "$SSL/rui.crt" ] && mv "$SSL/rui.crt.$ts.bak" "$SSL/rui.crt"
      bad "could not move the old certificate aside - certificate unchanged"
    fi
  else
    plan "regenerate certificate [$(oneline "$have")] -> [$want], then restart management agents"
  fi
fi

# ---- 7. maintenance mode: commissioning rejects a host that is in it
STEP=maintenance
mm=$(esxcli system maintenanceMode get 2>/dev/null)
case $mm in
  Disabled) say "maintenance mode OK (off)" ;;
  Enabled)  do_or_plan "exit maintenance mode" esxcli system maintenanceMode set --enable false ;;
  *)        bad "cannot read maintenance mode (${mm:-no answer})" ;;
esac

fi  # end of 1-7

echo "  ---- state now"
echo "  fqdn:       $(esxcli system hostname get 2>/dev/null | sed -n 's/^ *Fully Qualified Domain Name: *//p')"
echo "  vmkernels:  $(esxcli network ip interface list 2>/dev/null | awk '/^vmk[0-9]+$/{printf "%s ", $1}')"
echo "  uplinks:    $(esxcli network vswitch standard list 2>/dev/null | awk '/Uplinks:/{sub(/^ *Uplinks: */,""); print; exit}')"
echo "  portgroups: $(esxcli network vswitch standard portgroup list 2>/dev/null | awk 'NR>2 && NF{line=$0; sub(/ +[^ ]+ +[0-9]+ +[0-9]+ *$/,"",line); sub(/ +$/,"",line); printf "[%s] ", line}')"
echo "  build:      ${build:-unknown}"
echo "  maint mode: $(esxcli system maintenanceMode get 2>/dev/null)"
echo "  cert:       $(oneline "$(cert_names 2>/dev/null < "$SSL/rui.crt")")"
if [ "$RESTART" = 1 ]; then
  echo "  restarting management agents so port 443 serves the new certificate (up to ${AGENTWAIT}s)"
  services.sh restart >/dev/null 2>&1
  n=0; served=0
  while [ "$n" -lt $((AGENTWAIT / 5)) ]; do
    sleep 5; n=$((n + 1))
    if names_match "$(served_names)" "$want"; then served=1; break; fi
  done
  if [ "$served" = 1 ]; then say "port 443 now serves the certificate for $want"
  else bad "port 443 still serves the old certificate after ${AGENTWAIT}s - reboot the host, then re-run"; fi
fi
if [ "$LEFT" = 1 ]; then st=left-alone
elif [ "$UPSTATE" = upgrading ] || [ "$UPSTATE" = rebooting ] || [ "$UPSTATE" = need-bundle ]; then st=$UPSTATE
elif [ "$PROBLEM" -gt 0 ]; then st=problem
elif [ "$UPSTATE" = upgrade ]; then st=upgrade
elif [ -n "$TODO" ]; then st=todo
else st=ready; fi
echo "STATUS ${build:--} $st ${DID:--} ${TODO:--} $NOTE"
echo "RESULT changes=$CHANGED problems=$PROBLEM"
REMOTE_EOF
