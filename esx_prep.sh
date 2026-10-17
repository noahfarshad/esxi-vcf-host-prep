#!/usr/bin/env bash
# esx_prep.sh - bring standalone ESX hosts to the state VCF host commissioning accepts.
# v3.0  2026-09-21
#
# Reads the same hosts.yaml as esx_push.sh. Idempotent: re-running a prepared
# host reports changes=0 and does nothing.
#
# DRY RUN BY DEFAULT. Nothing changes until you pass --apply.
#
#   ./esx_prep.sh                       report what would change, every host
#   ./esx_prep.sh esx01                 one host (short name or as written)
#   ./esx_prep.sh --apply esx01         fix one host first
#   ./esx_prep.sh --apply               fix them all
#   ./esx_prep.sh --apply --wipe-disks  also clear stale vSAN partitions
#   -f FILE                             another host list (default hosts.yaml)
#
# What VCF commissioning requires, and what this fixes, in this order:
#   1. Hostname is the FQDN                    esxcli system hostname set
#   2. Exactly one vmkernel adapter            removes all but the management one
#   3. One uplink on the management vSwitch    keeps one with Link Up
#   4. One portgroup, "Management Network"     removes the rest, renames the mgmt one
#   5. No stale vSAN partitions                --wipe-disks; never the boot device
#   6. Certificate names the FQDN              regenerates ESXi's default one, restarts agents
#   7. Not in maintenance mode                 exits it
#
# Typical use, once esx_push.sh has every host on the target build:
#   ./esx_prep.sh            dry run: read the WOULD and PROBLEM lines
#   ./esx_prep.sh --apply    fix; the certificate step adds 1-3 minutes per host
#   ./esx_prep.sh            every host should now report changes=0
# then commission the hosts. Not covered here: DNS records, and the switch side
# (VLANs, MTU). An Active Directory join is reported, not undone: a joined host
# can't be renamed.
#
# Safety:
#   - A host that isn't standalone and settled is left untouched, with a PROBLEM:
#     management vmkernel on a distributed switch (already in a cluster), managed
#     by a vCenter, a reboot pending, or not on the build: set in hosts.yaml.
#   - The management vmkernel is never removed or reconfigured.
#   - The uplink kept is one reporting Link Up. Never leaves a host with none.
#   - The boot device and any disk holding a mounted datastore are never wiped.
#   - Only ESXi's own default certificate is regenerated, never one a CA issued.
#     The old pair is kept as rui.*.<timestamp>.bak and put back if generation
#     fails. Agents restart only when port 443 has to pick up a new certificate.
#   - Every host is re-read after changes and its final state printed.
#
# hosts.yaml keys used (all optional except hosts):
#   domain, user, mgmt_vmk, mgmt_portgroup, ssh, build (shared with esx_push.sh)
#   Example:
#     domain: example.com          # appended to bare host names
#     build: 12345678              # optional; hosts on any other build are left alone
#     hosts:
#       - host: esx01.example.com
#       - host: esx02                # becomes esx02.example.com
#       - host: 10.0.0.13            # an IP needs its FQDN under it:
#         fqdn: esx03.example.com
# It asks for each host's root password once per run. To skip the prompts,
# install sshpass and run: read -rs ESXPW && export ESXPW
#
# ESX quirks handled: its busybox sh has no tr and no working 'command -v', and
# it won't start a shell from a very long ssh command line, so the host-side
# script travels over stdin and runs from a temp file in /tmp.
#
# shellcheck disable=SC2029  # remote script is expanded locally on purpose

set -u

VERSION="3.0"
DIR=$(cd "$(dirname "$0")" && pwd)
CONF=$DIR/hosts.yaml
APPLY=0
WIPE=0
LOGDIR=${LOGDIR:-./prep-logs}
PARALLEL=${PARALLEL:-1}

usage() { sed -n '2,/^# Safety:/p' "$0" | sed '$d'; exit 2; }
die()   { echo "$*" >&2; exit 2; }

FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -f)           [ $# -ge 2 ] || usage; CONF=$2; shift ;;
    --apply)      APPLY=1 ;;
    --wipe-disks) WIPE=1 ;;
    --dry-run)    APPLY=0 ;;
    -h|--help)    usage ;;
    -*)           die "unknown option: $1" ;;
    *)            FILTERS+=("$1") ;;
  esac
  shift
done
[ -f "$CONF" ] || die "host list not found: $CONF"
[ "$WIPE" -eq 1 ] && [ "$APPLY" -eq 0 ] && die "--wipe-disks needs --apply"

TAB=$(printf '\t')
NL='
'

# ---- hosts.yaml: top-level "key: value" plus a hosts: list
AWK_CLEAN='
function clean(v) {
  sub(/\r$/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
  if (length(v) >= 2 && ((substr(v, 1, 1) == dq && substr(v, length(v), 1) == dq) ||
                         (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)))
    v = substr(v, 2, length(v) - 2)
  return v
}'
yaml_get() {
  awk -v key="$1" -v sq="'" -v dq='"' "$AWK_CLEAN"'
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ {
      k = $0; sub(/[ \t]*:.*/, "", k)
      if (k == key) { v = $0; sub(/^[^:]*:/, "", v); print clean(v); exit }
    }' "$CONF"
}
yaml_hosts() {
  awk -v sq="'" -v dq='"' "$AWK_CLEAN"'
    function flush() { if (h != "") print h "\t" q; h = ""; q = "" }
    function setkv(s,  k, v) {
      k = s; sub(/[ \t]*:.*/, "", k); v = s; sub(/^[^:]*:/, "", v); v = clean(v)
      if (k == "host" || k == "name") h = v; else if (k == "fqdn") q = v
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

DOMAIN=$(yaml_get domain)
SSHUSER=$(yaml_get user);          : "${SSHUSER:=root}"
MGMT=$(yaml_get mgmt_vmk);         : "${MGMT:=vmk0}"
WANTPG=$(yaml_get mgmt_portgroup); : "${WANTPG:=Management Network}"
BUILD=$(yaml_get build)            # optional: the ESX build every host must already be on
SSHBIN=$(yaml_get ssh)
if [ -z "$SSHBIN" ]; then SSHBIN=$(command -v ssh 2>/dev/null); fi
[ -n "$SSHBIN" ] && [ -x "$SSHBIN" ] || die "no ssh client found. Set ssh: /path/to/ssh in $CONF"

ALL=$(yaml_hosts)
[ -n "$ALL" ] || die "no hosts under hosts: in $CONF"

SEL=""
while IFS="$TAB" read -r host want; do
  [ -n "$host" ] || continue
  case $host in *[!0-9.]*) short=${host%%.*} ;; *) short=$host ;; esac
  if [ ${#FILTERS[@]} -gt 0 ]; then
    keep=""
    for f in "${FILTERS[@]}"; do { [ "$f" = "$host" ] || [ "$f" = "$short" ]; } && keep=1; done
    [ -n "$keep" ] || continue
  fi
  # the FQDN the host should report:
  #   an explicit fqdn: wins; an entry with a dot is already one;
  #   a bare name gets the domain; an IP cannot be guessed, so leave it alone
  if [ -n "$want" ]; then fqdn=$want
  else
    case $host in
      *[!0-9.]*.*) fqdn=$host ;;
      *[!0-9.]*)   fqdn=${DOMAIN:+$host.$DOMAIN}; : "${fqdn:=}" ;;
      *)           fqdn="" ;;
    esac
  fi
  SEL="$SEL$host$TAB$short$TAB$fqdn$NL"
done <<EOF
$ALL
EOF
if [ ${#FILTERS[@]} -gt 0 ]; then
  for f in "${FILTERS[@]}"; do
    printf '%s' "$SEL" | awk -F "$TAB" -v f="$f" '$1==f || $2==f {x=1} END {exit !x}' \
      || die "not in $CONF: $f"
  done
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8)
if [ -n "${ESXPW:-}" ] && command -v sshpass >/dev/null 2>&1; then
  export SSHPASS="$ESXPW"; SSH=(sshpass -e "$SSHBIN" "${SSH_OPTS[@]}")
else
  SSH=("$SSHBIN" "${SSH_OPTS[@]}")
fi

# The payload travels over stdin and runs from a file on the host. Passed as the ssh
# command line instead, it fails once it grows: ESXi won't start a shell with a
# command that long ("/bin/sh: File too large"). Stdin is fully read before the
# payload starts, so nothing it runs can swallow its own script.
# shellcheck disable=SC2016  # expanded on the host, not here
RUNNER='f=/tmp/esx_prep.$$; cat > "$f" || exit 1; sh "$f"; rc=$?; rm -f "$f"; exit $rc'

# ------------------------------------------------------------------ payload
# Runs on the host under busybox sh. @X@ placeholders are filled in per host.
read -r -d '' PAYLOAD <<'REMOTE_EOF'
APPLY=@APPLY@; WIPE=@WIPE@; FQDN='@FQDN@'; MGMT='@MGMT@'; WANTPG='@WANTPG@'; BUILD='@BUILD@'
CHANGED=0; PROBLEM=0
say()  { echo "  $*"; }
act()  { echo "  CHANGE $*"; CHANGED=$((CHANGED+1)); }
plan() { echo "  WOULD  $*"; CHANGED=$((CHANGED+1)); }
bad()  { echo "  PROBLEM $*"; PROBLEM=$((PROBLEM+1)); }
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

# ---- 0. only prepare a standalone, settled host; leave anything already in use alone
SKIP=0
summary=$(vim-cmd hostsvc/hostsummary 2>/dev/null)
field() { printf '%s\n' "$summary" | awk -v k="$1" '$1 == k { v = $3; gsub(/[",]/, "", v); print v; exit }'; }
mgmtsrv=$(field managementServerIp)
reboot=$(field rebootRequired)
portset=$(esxcli network ip interface list 2>/dev/null \
  | awk -v m="$MGMT" '$1==m{f=1} f&&/Portset:/{sub(/^ *Portset: */,""); print; exit}')
build=$(vmware -v 2>/dev/null | sed -n 's/.*build-\([0-9][0-9]*\).*/\1/p')
case $portset in
  *[Dd][Vv][Ss]*) bad "$MGMT is on a distributed switch ($portset) - already in a cluster, not touching this host"; SKIP=1 ;;
esac
case $mgmtsrv in
  ""|"<unset>") ;;
  *) bad "managed by the vCenter at $mgmtsrv - remove it from that vCenter first; not touching this host"; SKIP=1 ;;
esac
if [ "$reboot" = true ]; then
  bad "a reboot is pending (an update is waiting to finish) - reboot, then re-run; not touching this host"; SKIP=1
fi
if [ -n "$BUILD" ] && [ "$build" != "$BUILD" ]; then
  bad "on build ${build:-unknown}, hosts.yaml wants $BUILD - upgrade it first (esx_push.sh); not touching this host"; SKIP=1
fi
[ "$SKIP" = 0 ] && say "standalone host, build ${build:-unknown}"

if [ "$SKIP" = 0 ]; then

# ---- 1. hostname
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
mgmt_pg=$(esxcli network ip interface list 2>/dev/null \
  | awk -v m="$MGMT" '$1==m{f=1} f&&/Portgroup:/{sub(/^ *Portgroup: */,""); print; exit}')
if [ -z "$mgmt_pg" ]; then
  bad "cannot find $MGMT - stopping before any change"
else
  say "management: $MGMT on portgroup '$mgmt_pg'"
  extra=$(esxcli network ip interface list 2>/dev/null \
    | awk -v m="$MGMT" '/^vmk[0-9]+$/ && $1!=m {print $1}')
  if [ -z "$extra" ]; then say "vmkernel adapters OK (only $MGMT)"
  else for v in $extra; do do_or_plan "remove vmkernel $v" esxcli network ip interface remove -i "$v"; done; fi

  # ---- 3. uplinks
  vsw=$(esxcli network ip interface list 2>/dev/null \
    | awk -v m="$MGMT" '$1==m{f=1} f&&/Portset:/{sub(/^ *Portset: */,""); print; exit}')
  : "${vsw:=vSwitch0}"
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
boot=$(esxcli storage core device list 2>/dev/null \
  | awk '/^[a-zA-Z0-9._:-]+$/{d=$1} /Is Boot Device: true/{print d}')
say "boot device: ${boot:-unknown}"
mounted=$(esxcli storage filesystem list 2>/dev/null | awk 'NR>2 {print $2}')
dirty=$(vdq -q 2>/dev/null | awk -F'"' '
  /"Name"/  {n=$4}
  /"State"/ {s=$4}
  /"Reason"/{r=$4; if (s ~ /Ineligible/ || s ~ /In-use/) print n "|" s "|" r}')
if [ -z "$dirty" ]; then
  say "disks OK (nothing ineligible or in use by vSAN)"
else
  say "disks needing attention:"
  echo "$dirty" | while IFS='|' read -r dev st rs; do
    [ -n "$dev" ] || continue
    if [ "$dev" = "$boot" ]; then say "skip $dev (boot device) - $st / $rs"; continue; fi
    skip=0; for m in $mounted; do [ "$m" = "$dev" ] && skip=1; done
    if [ "$skip" = 1 ]; then say "skip $dev (has a mounted datastore) - $st / $rs"; continue; fi
    if [ "$WIPE" != 1 ]; then
      echo "  NEEDS-WIPE $dev - $st / $rs   (re-run with --wipe-disks)"; continue
    fi
    echo "  CHANGE wiping $dev - $st / $rs"
    esxcli vsan storage remove -d "$dev" >/dev/null 2>&1 \
      || esxcli vsan storage remove -u "$dev" >/dev/null 2>&1
    partedUtil mklabel "/vmfs/devices/disks/$dev" gpt >/dev/null 2>&1 \
      || echo "  PROBLEM could not clear partitions on $dev"
  done
fi
if [ "$WIPE" = 1 ]; then
  cl=$(esxcli vsan cluster get 2>/dev/null | sed -n 's/^ *Enabled: *//p')
  if [ "$cl" = "true" ]; then
    if esxcli vsan cluster leave >/dev/null 2>&1; then echo "  CHANGE left vSAN cluster"
    else echo "  PROBLEM could not leave vSAN cluster"; fi
  fi
fi

# ---- 6. certificate: VCF connects by FQDN and rejects a certificate for any other name
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
mm=$(esxcli system maintenanceMode get 2>/dev/null)
case $mm in
  Disabled) say "maintenance mode OK (off)" ;;
  Enabled)  do_or_plan "exit maintenance mode" esxcli system maintenanceMode set --enable false ;;
  *)        bad "cannot read maintenance mode (${mm:-no answer})" ;;
esac

fi  # end of: host is safe to prepare

echo "  ---- state now"
echo "  fqdn:       $(esxcli system hostname get 2>/dev/null | sed -n 's/^ *Fully Qualified Domain Name: *//p')"
echo "  vmkernels:  $(esxcli network ip interface list 2>/dev/null | awk '/^vmk[0-9]+$/{printf "%s ", $1}')"
echo "  uplinks:    $(esxcli network vswitch standard list 2>/dev/null | awk '/Uplinks:/{sub(/^ *Uplinks: */,""); print; exit}')"
echo "  portgroups: $(esxcli network vswitch standard portgroup list 2>/dev/null | awk 'NR>2 && NF{line=$0; sub(/ +[^ ]+ +[0-9]+ +[0-9]+ *$/,"",line); sub(/ +$/,"",line); printf "[%s] ", line}')"
echo "  build:      ${build:-unknown}"
echo "  maint mode: $(esxcli system maintenanceMode get 2>/dev/null)"
echo "  cert:       $(oneline "$(cert_names 2>/dev/null < "$SSL/rui.crt")")"
if [ "$RESTART" = 1 ]; then
  echo "  restarting management agents so port 443 serves the new certificate (1-3 min)"
  services.sh restart >/dev/null 2>&1
  n=0; served=0
  while [ "$n" -lt 36 ]; do
    sleep 5; n=$((n + 1))
    if names_match "$(served_names)" "$want"; then served=1; break; fi
  done
  if [ "$served" = 1 ]; then say "port 443 now serves the certificate for $want"
  else bad "port 443 still serves the old certificate after 3 minutes - reboot the host, then re-run"; fi
fi
echo "RESULT changes=$CHANGED problems=$PROBLEM"
REMOTE_EOF

# ------------------------------------------------------------------ driver
mkdir -p "$LOGDIR"
: > "$LOGDIR/summary"
mode="DRY RUN - nothing will be changed"
[ "$APPLY" -eq 1 ] && mode="APPLY - changes will be made"
[ "$WIPE" -eq 1 ] && mode="$mode, INCLUDING DISK WIPES"
echo "esx_prep.sh v$VERSION   $(date '+%Y-%m-%d %H:%M:%S')   $mode"
echo "host list: $CONF   target portgroup: '$WANTPG'   management vmk: $MGMT${BUILD:+   build: $BUILD}"
echo

prep_host() {
  host=$1; fqdn=$2
  log="$LOGDIR/$host.log"
  script=${PAYLOAD//@APPLY@/$APPLY}
  script=${script//@WIPE@/$WIPE}
  script=${script//@FQDN@/$fqdn}
  script=${script//@MGMT@/$MGMT}
  script=${script//@WANTPG@/$WANTPG}
  script=${script//@BUILD@/$BUILD}
  {
    echo "==== $host"
    if ! printf '%s\n' "$script" | "${SSH[@]}" "$SSHUSER@$host" "$RUNNER" 2>&1; then
      echo "  PROBLEM ssh to $host failed"
      echo "RESULT changes=0 problems=1"
    fi
  } | tee "$log"
  r=$(grep '^RESULT' "$log" | tail -1); [ -n "$r" ] || r="RESULT changes=0 problems=1"
  printf '%-34s %s\n' "$host" "${r#RESULT }" >> "$LOGDIR/summary"
  echo
}

running=0
while IFS="$TAB" read -r host short fqdn; do
  [ -n "$host" ] || continue
  if [ "$PARALLEL" -gt 1 ]; then
    prep_host "$host" "$fqdn" &
    running=$((running+1))
    [ "$running" -ge "$PARALLEL" ] && { wait -n; running=$((running-1)); }
  else
    prep_host "$host" "$fqdn"
  fi
done <<EOF
$SEL
EOF
wait

echo "==== summary"
sort "$LOGDIR/summary"
echo
if [ "$APPLY" -eq 0 ]; then
  echo "Dry run. Re-run with --apply to make these changes."
else
  echo "Re-run without --apply to confirm every host reports changes=0."
fi
! grep -q 'problems=[1-9]' "$LOGDIR/summary"
