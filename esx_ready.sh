#!/bin/sh
# esx_ready.sh v1.20 - get standalone ESX hosts ready for VCF host commissioning:
# upgrade to build: if set, then fix hostname, vmkernels, uplinks, portgroups,
# disks, VMFS-6 datastores, certificate and maintenance mode. A host already in a
# cluster, managed by a vCenter or with a reboot pending is left alone.
#
#   sh esx_ready.sh [plan|apply|list|selftest] [host ...] [-f hosts.yaml]
#                   [--wipe-disks] [--restore-vswitch]
#     plan     show what would change (the default)
#     apply    change it; every host that ends "ready" in the final table can be
#              commissioned. --wipe-disks lets it destroy data: stale vSAN partitions,
#              and VMFS-5 datastores, which it recreates as VMFS-6
#     list     show how hosts.yaml was read, without connecting
#     selftest run the host-side logic here against a stubbed host; needs nothing
#
# --clear-datastores removes a local VMFS datastore and clears the disk under it,
# so that disk can be claimed for vSAN. VCF will not commission a host for vSAN
# while a disk carries partitions, and the disk holding the local datastore is
# often the one the cluster wants as its cache device. Without the flag such a
# datastore is only reported. It is never removed when other hosts can see it,
# when it spans several extents, when it has registered VMs, when it is on the
# boot device, or when this host's scratch or core dump lives on it.
#
# A management portgroup under a different name is reported and left alone.
# esxcli cannot rename one; the only way is to create the new portgroup and move
# the vmkernel to it, which drops the connection this runs over. Nothing in
# commissioning or the cluster build reads the name, so the risk buys nothing.
#
# --restore-vswitch moves the management vmkernel off a distributed switch that a
# vCenter left behind onto a standard switch, keeping its address. It changes the
# network under its own connection, so it is opt-in, it refuses rather than guess
# the VLAN (mgmt_vlan:) or the uplink (mgmt_uplink:, otherwise the switch's own
# adapter that reports Link Up), and it puts the uplink back and stops if the
# standard switch does not come up with one. If a host does not answer afterwards,
# /var/log/esx_ready-restore.log on it says how far it got, and the DCUI's Network
# Restore Options, Restore Standard Switch does the same job from the console.
#
# hosts.yaml holds only the hosts and the build (see hosts.example.yaml). The root
# password comes from ESXPW when sshpass is installed; otherwise ssh prompts.
# Runs under any POSIX sh: a jump box, or an ESX host (which then goes last).

# shellcheck disable=SC2012,SC2013,SC2016,SC2029,SC2086,SC2317,SC2329  # ls for sizes (as esx_push.sh), key names
# are single words, remote commands quoted,
# option strings split, the host-side block and the trap-called cleanup: all on purpose

VERSION=1.20
DIR=$(cd "$(dirname "$0")" && pwd)
SELF=$DIR/$(basename "$0")
CONF=$DIR/hosts.yaml
APPLY=0; WIPE=0; LIST=0; RESTORE=0; CLEARDS=0; FILTERS=""
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

# ---- selftest: the host side, run here against a stubbed host
# The parts that decide whether a host stays reachable are parsers and an
# ordering. Both are testable without a host, and both have been wrong, so
# they are tested on demand rather than in production.
selftest() {
  T=$(mktemp -d) || die "cannot make a temp directory"
  trap 'rm -rf "$T"' EXIT INT TERM
  mkdir -p "$T/bin"
  cat > "$T/dvs.txt" <<'EOF'
DSwitch-Mgmt
   Name: DSwitch-Mgmt
   Num Ports: 2560
   MTU: 1500
   Uplinks: vmnic3, vmnic2
   DVPort:
         Client: vmnic2
         In Use: true
         Port ID: 2057

         Client: vmnic3
         In Use: true
         Port ID: 2058

         Client: vmk0
         In Use: true
         Port ID: 137

DSwitch-Storage
   Name: DSwitch-Storage
   Num Ports: 2560
   MTU: 9000
   Uplinks: vmnic5, vmnic4
   DVPort:
         Client: vmnic4
         In Use: true
         Port ID: 3001

         Client: vmk2
         In Use: true
         Port ID: 3009

EOF
  cat > "$T/sw.txt" <<'EOF'
vSwitch0
   Name: vSwitch0
   MTU: 1500
   Uplinks: vmnic2
   Portgroups: Management Network, VM Network

vSwitchNested
   Name: vSwitchNested
   MTU: 1500
   Uplinks:
   Portgroups: Isolated
EOF
  cat > "$T/pg.txt" <<'EOF'
Name                            Virtual Switch    Active Clients    VLAN ID
------------------------------  ----------------  --------------  ---------
Management Network              vSwitch0                       1         10
VM Network                      vSwitch0                       0          0
Isolated                        vSwitchNested                  0       4095
EOF
  cat > "$T/nic.txt" <<'EOF'
Name    PCI Device    Driver  Admin Status  Link Status  Speed  Duplex  MAC Address         MTU  Description
------  ------------  ------  ------------  -----------  -----  ------  -----------------  ----  -----------
vmnic0  0000:01:00.0  igbn    Up            Up            1000  Full    00:25:90:aa:bb:00  1500  I350
vmnic1  0000:01:00.1  igbn    Up            Down             0  Half    00:25:90:aa:bb:01  1500  I350
vmnic2  0000:82:00.0  i40en   Up            Up           10000  Full    00:25:90:aa:bb:02  1500  X710
vmnic3  0000:82:00.1  i40en   Up            Down             0  Half    00:25:90:aa:bb:03  1500  X710
EOF
  cat > "$T/ipif.txt" <<'EOF'
vmk0
   Name: vmk0
   Portset: DvsPortset-0
   Portgroup: N/A
   VDS Name: DSwitch-Mgmt
   VDS Port: 137
   MTU: 1500

vmk1
   Name: vmk1
   Portset: DvsPortset-0
   Portgroup: N/A
   VDS Name: DSwitch-Mgmt
   VDS Port: 140
   MTU: 9000

vmk2
   Name: vmk2
   Portset: DvsPortset-1
   Portgroup: N/A
   VDS Name: DSwitch-Storage
   VDS Port: 3009
   MTU: 9000
EOF
  cat > "$T/ipif-std.txt" <<'EOF'
vmk0
   Name: vmk0
   Portset: vSwitch0
   Portgroup: Management Network
   VDS Name: N/A
   MTU: 1500
EOF
  cat > "$T/fs.txt" <<'EOF'
Mount Point                                        Volume Name  UUID                                 Mounted  Type    Size           Free
-------------------------------------------------  -----------  -----------------------------------  -------  ------  -------------  ------------
/vmfs/volumes/67ed87fc-e293d481-a4a4-001122334455  datastore1   67ed87fc-e293d481-a4a4-001122334455  true     VMFS-6  1099243192320  880468656128
/vmfs/volumes/67ed87fc-d930a3a9-24af-001122334455  OSDATA-old   67ed87fc-d930a3a9-24af-001122334455  true     VMFS-L  128849018880   120000000000
EOF
  cat > "$T/core.txt" <<'EOF'
eui.00000000000000c3
   Display Name: Local NVMe Disk
   Is Local: true
t10.NVMe____MTFDKCC960TG
   Display Name: Local NVMe Disk
   Is Local: true
EOF
  cat > "$T/extent.txt" <<'EOF'
Volume Name  VMFS UUID                            Extent Number  Device Name           Partition
-----------  -----------------------------------  -------------  --------------------  ---------
datastore1   67ed87fc-e293d481-a4a4-001122334455              0  eui.00000000000000c3          1
OSDATA-old   67ed87fc-d930a3a9-24af-001122334455              0  eui.00000000000000c3          8
EOF
  printf '   Path: /ScratchConfig/ConfiguredScratchLocation\n   String Value: /scratch\n' > "$T/scratch.txt"
  cat > "$T/dump.txt" <<'EOF'
Path                                                              Active  Configured  Size
----------------------------------------------------------------  ------  ----------  ----------
/vmfs/volumes/67ed87fc-e293d481-a4a4-001122334455/vmkdump/a.dumpfile  false   false       8791261184
/vmfs/volumes/6ad94962-9f5b0cc5-0432-001122334455/vmkdump/a.dumpfile  true    true        8791261184
EOF
  cat > "$T/vdq.txt" <<'EOF'
[
   {
      "Name"     : "eui.00000000000000c3",
      "State"    : "Eligible for use by VSAN",
      "Reason"   : "None"
   }
]
EOF
  cat > "$T/ipv4.txt" <<'EOF'
Name  IPv4 Address   IPv4 Netmask   IPv4 Broadcast  Address Type  Gateway        DHCP DNS
----  -------------  -------------  --------------  ------------  -------------  --------
vmk0  172.16.10.61   255.255.255.0  172.16.10.255   STATIC        172.16.10.254     false
EOF
  for c in vim-cmd esxcfg-vmknic esxcfg-vswitch net-dvs vmkfstools services.sh openssl vdq; do
    { echo '#!/bin/sh'
      echo 'echo "'"$c"' $*" >> "$T/called"'
      echo 'case "'"$c"' $*" in'
      echo '  "vim-cmd hostsvc/hostsummary") echo "   rebootRequired = false," ;;'
      echo '  "vim-cmd vmsvc/getallvms") cat "$T/vms.txt" ;;'
      echo '  "vdq -q") cat "$T/vdq.txt" ;;'
      echo 'esac'
      echo 'exit 0'
    } > "$T/bin/$c"
    chmod +x "$T/bin/$c"
  done
  cat > "$T/bin/partedUtil" <<'EOF'
#!/bin/sh
echo "partedUtil $*" >> "$T/called"
case "$1" in
  getptbl) echo "gpt"; echo "116737 255 63 1875385008"; exit 0 ;;
  mklabel)
    if [ -s "$T/parted_fail" ]; then
      left=$(cat "$T/parted_fail"); left=$((left - 1)); echo "$left" > "$T/parted_fail"
      if [ "$left" -ge 0 ]; then
        echo "Error: Read-only file system during write on /dev/disks/x" >&2; exit 1
      fi
    fi
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$T/bin/partedUtil"
  cat > "$T/bin/esxcli" <<'EOF'
#!/bin/sh
echo "esxcli $*" >> "$T/called"
case "$*" in
  "network ip interface list") cat "$T/ipif.txt" ;;
  "network ip interface ipv4 get -i vmk0") cat "$T/ipv4.txt" ;;
  "network vswitch dvs vmware list") cat "$T/dvs.txt" ;;
  "network vswitch standard list") cat "$T/sw.txt" ;;
  "network vswitch standard portgroup list") cat "$T/pg.txt" ;;
  "network nic list") cat "$T/nic.txt" ;;
  "storage filesystem list")
      if [ -s "$T/unmounted" ]; then grep -v -F -f "$T/unmounted" "$T/fs.txt"; else cat "$T/fs.txt"; fi ;;
  "storage filesystem unmount -u "*)
      a=$*; echo "${a##* }" >> "$T/unmounted" ;;
  "storage filesystem mount -u "*)
      a=$*; grep -v -F -x "${a##* }" "$T/unmounted" > "$T/u2" 2>/dev/null
      mv -f "$T/u2" "$T/unmounted" 2>/dev/null; : > /dev/null ;;
  "storage core device list") cat "$T/core.txt" ;;
  "storage vmfs extent list") cat "$T/extent.txt" ;;
  "system settings advanced list -o /ScratchConfig/"*) cat "$T/scratch.txt" ;;
  "system coredump file list") cat "$T/dump.txt" ;;
  "system hostname get") printf '   Domain Name: lab.local\n   Fully Qualified Domain Name: esx41.lab.local\n   Host Name: esx41\n' ;;
  "system maintenanceMode get") echo Disabled ;;
  "vsan storage list") cat "$T/vsanstore.txt" 2>/dev/null ;;
  "vsan storage remove "*)
      [ -s "$T/vsan_rm_fail" ] && exit 1
      : > "$T/vsanstore.txt" ;;
  "vsan cluster get") printf '   Enabled: %s\n' "$(cat "$T/vsan.txt" 2>/dev/null || echo false)" ;;
esac
exit 0
EOF
  chmod +x "$T/bin/esxcli"
  export T
  awk '/^: <<.REMOTE_EOF.$/ { f = 1; next } /^REMOTE_EOF$/ { f = 0 } f' "$SELF" > "$T/raw"

  P=0; FAIL=0
  ck() { if [ "$2" = "$3" ]; then P=$((P + 1))
         else FAIL=$((FAIL + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }
  has() { if grep -q "$2" "$T/out"; then P=$((P + 1))
          else FAIL=$((FAIL + 1)); echo "  FAIL $1: output has no /$2/"; fi; }
  hasnt() { if grep -q "$2" "$T/called"; then FAIL=$((FAIL + 1)); echo "  FAIL $1: it ran /$2/"
            else P=$((P + 1)); fi; }
  did() { if grep -q "$2" "$T/called"; then P=$((P + 1))
          else FAIL=$((FAIL + 1)); echo "  FAIL $1: it never ran /$2/"; fi; }
  # apply, restore, vlan, uplink, upmode, cleards, minup, wipe
  scen() {
    : > "$T/called"; : > "$T/unmounted"
    [ -f "$T/vsan.txt" ] || echo false > "$T/vsan.txt"
    [ -f "$T/vsanstore.txt" ] || : > "$T/vsanstore.txt"
    [ -f "$T/vsan_rm_fail" ] || : > "$T/vsan_rm_fail"
    [ -f "$T/parted_fail" ] || : > "$T/parted_fail"
    sed -e "s|@APPLY@|$1|g" -e "s|@RESTORE@|$2|g" -e "s|@MGMTVLAN@|$3|g" -e "s|@MGMTUPLINK@|$4|g" \
        -e "s|@WIPE@|${8:-0}|g" -e 's|@FQDN@|esx41.lab.local|g' -e 's|@MGMT@|vmk0|g' \
        -e 's|@WANTPG@|Management Network|g' -e 's|@CONFNAME@|hosts.yaml|g' \
        -e 's|@BUILD@||g' -e 's|@BUNDLE@||g' -e 's|@BSIZE@|0|g' -e 's|@PROFILE@||g' \
        -e 's|@DS@||g' -e 's|@UARGS@||g' -e 's|@MINFREE@|1|g' -e 's|@STALE@|3600|g' \
        -e 's|@AGENTWAIT@|1|g' -e "s|@UPMODE@|${5:-update}|g" -e "s|@CLEARDS@|${6:-0}|g" \
        -e "s|@MINUP@|${7:-2}|g" \
        -e "s|^RLOG=.*|RLOG=$T/rlog|" "$T/raw" > "$T/p.sh"
    PATH="$T/bin:$PATH" sh "$T/p.sh" > "$T/out" 2>&1
    sleep 1   # the restore detaches itself
  }
  order() {  # $1 before $2 in the call log
    a=$(grep -n "$1" "$T/called" | head -n 1 | cut -d: -f1)
    b=$(grep -n "$2" "$T/called" | head -n 1 | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then P=$((P + 1))
    else FAIL=$((FAIL + 1)); echo "  FAIL order: /$1/ ($a) did not come before /$2/ ($b)"; fi
  }

  echo "---- the esxcli verb the host will run"
  # 'update' never moves a VIB backwards, so a downgrade needs 'install'.
  # Getting this wrong is silent: the run reports success and the build stays.
  hard=$(grep -c 'esxcli software profile \(update\|install\) ' "$T/raw")
  ck "no hardcoded verb"    "$hard" "0"
  soft=$(grep -c 'esxcli software profile \$UPMODE ' "$T/raw")
  ck "every call is config-driven" "$soft" "3"
  for m in update install; do
    sed "s|@UPMODE@|$m|g" "$T/raw" > "$T/m.sh"
    ck "update_mode $m lands" "$(sed -n "s/.*UPMODE='\\([a-z]*\\)'.*/\\1/p" "$T/m.sh")" "$m"
  done

  echo "---- parsers"
  PATH="$T/bin:$PATH"
  eval "$(awk '/^vmk_field\(\)/,/^restore_vswitch\(\) \{/' "$T/raw" | sed '$d')"
  ck "uplinks, second switch" "$(dvs_field DSwitch-Storage Uplinks)" "vmnic5, vmnic4"
  ck "uplinks, first switch"  "$(dvs_field DSwitch-Mgmt Uplinks)"    "vmnic3, vmnic2"
  ck "absent switch"          "$(dvs_field DSwitch-Nope Uplinks)"    ""
  ck "port of vmnic2"         "$(dvs_port_of DSwitch-Mgmt vmnic2)"   "2057"
  ck "port of vmnic3"         "$(dvs_port_of DSwitch-Mgmt vmnic3)"   "2058"
  ck "port of vmk0"           "$(dvs_port_of DSwitch-Mgmt vmk0)"     "137"
  ck "port, second switch"    "$(dvs_port_of DSwitch-Storage vmnic4)" "3001"
  ck "no bleed across switch" "$(dvs_port_of DSwitch-Mgmt vmnic4)"   ""
  ck "standard uplinks"       "$(sw_uplinks vSwitch0)"               "vmnic2"
  ck "standard, no uplink"    "$(sw_uplinks vSwitchNested)"          ""
  ck "portgroup and vlan"     "$(pg_switch_vlan 'Management Network')" "vSwitch0 10"
  ck "portgroup vlan 0"       "$(pg_switch_vlan 'VM Network')"       "vSwitch0 0"
  ck "portgroup absent"       "$(pg_switch_vlan Nope)"               ""
  in_list "vmnic3, vmnic2" vmnic2  && r=y || r=n; ck "in_list, comma and space" "$r" y
  in_list "vmnic20,vmnic21" vmnic2 && r=y || r=n; ck "in_list, no prefix match" "$r" n
  in_list "" vmnic2                && r=y || r=n; ck "in_list, empty"           "$r" n
  nic_is_up vmnic2 && r=y || r=n; ck "nic up"        "$r" y
  nic_is_up vmnic3 && r=y || r=n; ck "nic link down" "$r" n
  nic_is_up vmnic9 && r=y || r=n; ck "nic absent"    "$r" n

  echo "---- a host left on a proxy switch, without --restore-vswitch"
  scen 1 0 10 ''
  has   "it says what is wrong"  "left behind when it was removed"
  hasnt "no vmkernel removed"    "interface remove"
  hasnt "no vmkernel moved"      "vmknic -d"
  hasnt "no switch deleted"      "net-dvs -d"
  hasnt "no disk touched"        "mklabel"

  echo "---- plan, with --restore-vswitch"
  scen 0 1 10 ''
  has   "it plans rather than does" "WOULD  restore vmk0"
  has   "it picks the cabled port"  "uplink vmnic2 released"
  has   "it finds the right port"   "port 2057"
  hasnt "plan changes nothing"      "vswitch standard add"

  echo "---- apply, with --restore-vswitch"
  scen 1 1 10 ''
  did   "builds the switch"      "vswitch standard add -v vSwitch0"
  did   "tags the portgroup"     "portgroup set -p Management Network --vlan-id 10"
  did   "releases the uplink"    "esxcfg-vswitch -Q vmnic2 -V 2057 DSwitch-Mgmt"
  did   "attaches the uplink"    "uplink add -u vmnic2 -v vSwitch0"
  did   "moves the vmkernel"     "esxcfg-vmknic -a -i 172.16.10.61"
  did   "keeps the MTU"          "esxcfg-vmknic -a -i 172.16.10.61 -n 255.255.255.0 -m 1500"
  did   "tags it management"     "interface tag add -i vmk0 -t Management"
  did   "deletes the old switch" "net-dvs -d DSwitch-Mgmt"
  order "portgroup set -p Management Network" "esxcfg-vswitch -Q"
  order "esxcfg-vswitch -Q"                   "uplink add -u vmnic2"
  order "uplink add -u vmnic2"                "esxcfg-vmknic -d"
  order "esxcfg-vmknic -d"                    "esxcfg-vmknic -a"
  order "esxcfg-vmknic -a"                    "net-dvs -d"

  echo "---- apply, but the uplink will not attach"
  sed 's/^   Uplinks: vmnic2$/   Uplinks:/' "$T/sw.txt" > "$T/sw.tmp" && mv "$T/sw.tmp" "$T/sw.txt"
  scen 1 1 10 ''
  hasnt "the vmkernel is not moved"   "esxcfg-vmknic -d"
  hasnt "no other vmkernel removed"   "interface remove"
  hasnt "the old switch stays"        "net-dvs -d"
  did   "the uplink goes back"        "esxcfg-vswitch -P vmnic2 -V 2057 DSwitch-Mgmt"
  if grep -q "ABORT" "$T/rlog" 2>/dev/null; then P=$((P + 1))
  else FAIL=$((FAIL + 1)); echo "  FAIL: nothing written to the host's restore log"; fi
  sed 's/^   Uplinks:$/   Uplinks: vmnic2/' "$T/sw.txt" > "$T/sw.tmp" && mv "$T/sw.tmp" "$T/sw.txt"

  echo "---- refusals: a wrong value here strands a host"
  scen 1 1 '' ''
  has   "no mgmt_vlan"           "mgmt_vlan is not set"
  hasnt "and nothing was done"   "esxcfg-vswitch -Q"
  scen 1 1 10 vmnic3
  has   "mgmt_uplink is down"    "does not report Link Up"
  hasnt "and nothing was done"   "esxcfg-vswitch -Q"
  scen 1 1 10 vmnic0
  has   "mgmt_uplink not on it"  "does not use it"
  hasnt "and nothing was done"   "esxcfg-vswitch -Q"

  echo "---- a clean standalone host carrying a local datastore"
  # Section 5c removes a datastore and clears the disk under it. Every guard
  # that stops it is a reason a host would otherwise lose data.
  cp "$T/ipif-std.txt" "$T/ipif.txt"
  printf 'Vmid Name File\n' > "$T/vms.txt"

  scen 1 0 10 '' update 0
  has   "it names both volumes"       "datastore1 OSDATA-old is on eui.00000000000000c3"
  has   "and refuses, not notes"      "PROBLEM datastore1 OSDATA-old is on"
  has   "and says VCF will not take it" "will not commission this host for vSAN"
  hasnt "but removes nothing"         "filesystem unmount"
  hasnt "and clears nothing"          "mklabel"

  scen 0 0 10 '' update 1
  has   "plan names both volumes" "WOULD  remove datastore1 OSDATA-old from eui.00000000000000c3"
  hasnt "plan changes nothing"    "filesystem unmount"

  # The disk carries a datastore and a stale OSDATA from an earlier install.
  # partedUtil refuses while either is mounted, so both come off before the
  # one mklabel. Clearing per datastore instead of per device fails here.
  scen 1 0 10 '' update 1
  did   "unmounts the datastore"  "filesystem unmount -u 67ed87fc-e293d481-a4a4-001122334455"
  did   "unmounts the OSDATA too" "filesystem unmount -u 67ed87fc-d930a3a9-24af-001122334455"
  did   "clears the disk"         "mklabel /vmfs/devices/disks/eui.00000000000000c3 gpt"
  has   "and says it is eligible" "now eligible for vSAN"
  order "filesystem unmount -u 67ed87fc-e293d481" "mklabel"
  order "filesystem unmount -u 67ed87fc-d930a3a9" "mklabel"
  ck "one mklabel, not one per volume" "$(grep -c mklabel "$T/called")" "1"

  echo "---- cabled adapters for the destination cluster's switch"
  # The fixture has vmnic0 and vmnic2 Up, vmnic1 and vmnic3 Link Down.
  scen 1 0 10 '' update 0 2
  has   "two up is enough for two"  "adapters Link Up: 2"
  hasnt "and nothing is flagged"    "report Link Up"
  scen 1 0 10 '' update 0 3
  has   "two up is not enough for three" "2 adapter(s) report Link Up"
  has   "and it says why it matters"     "commissioning will not catch it"
  scen 0 0 10 '' update 0 4
  has   "four needed, two present"       "the destination cluster.s switch is built on 4"

  echo "---- a disk that is not free on the first ask"
  # esxcli returns before a volume has finished detaching, so partedUtil can
  # refuse once and succeed a moment later. Giving up on the first refusal is
  # what left four hosts uncleared.
  echo 1 > "$T/parted_fail"
  scen 1 0 10 '' update 1
  ck "it asks again"        "$(grep -c 'partedUtil mklabel' "$T/called")" "2"
  has "and says so"         "cleared on attempt 2"
  has "and the disk is done" "now eligible for vSAN"
  echo 9 > "$T/parted_fail"
  scen 1 0 10 '' update 1
  ck "but not forever"      "$(grep -c 'partedUtil mklabel' "$T/called")" "3"
  has "it reports the real error" "Read-only file system"
  has "and remounts"              "the datastores are mounted again"
  : > "$T/parted_fail"

  echo "---- a host still carrying its old vSAN cluster"
  # vSAN owns the disks of a cluster member and partedUtil is refused on every
  # one it has claimed. Leaving after the wipes instead of before is what left
  # two disks on each of three hosts uncleared, with the run still saying ready.
  echo true > "$T/vsan.txt"
  scen 1 0 10 '' update 1 2 1
  did   "it leaves the cluster"  "vsan cluster leave"
  order "vsan cluster leave" "mklabel"
  has   "and says it did"        "leave the old vSAN cluster"
  scen 0 0 10 '' update 1 2 1
  has   "the plan says so first" "WOULD  leave the old vSAN cluster, then clear its disks"
  hasnt "and leaves nothing"     "vsan cluster leave"
  echo false > "$T/vsan.txt"
  scen 1 0 10 '' update 1 2 1
  hasnt "a host in no cluster is left alone" "vsan cluster leave"
  did   "and its disks are still cleared"    "mklabel /vmfs/devices/disks/eui.00000000000000c3 gpt"

  echo "---- a host still carrying an old vSAN disk group"
  # Leaving the cluster drops membership, not the disk groups, and vSAN keeps
  # every disk in a group read-only to partedUtil. A cache disk cannot come out
  # on its own, so the group is broken up by its cache device before any wipe.
  vsfix() { cat > "$T/vsanstore.txt" <<'VS'
naa.50000000000000a1
   Device: naa.50000000000000a1
   Is SSD: true
   VSAN Disk Group Name: naa.50000000000000a1
   Is Capacity Tier: false
naa.50000000000000b2
   Device: naa.50000000000000b2
   Is SSD: true
   VSAN Disk Group Name: naa.50000000000000a1
   Is Capacity Tier: true
VS
  }
  vsfix; scen 1 0 10 '' update 1 2 1
  did   "it breaks up the group"  "vsan storage remove -s naa.50000000000000a1 -m noAction"
  has   "and says it did"         "break up the old vSAN disk group on naa.50000000000000a1"
  order "vsan storage remove -s naa.50000000000000a1" "mklabel"
  ck "once per group, not once per disk" "$(grep -c 'vsan storage remove -s' "$T/called")" "1"

  vsfix; scen 0 0 10 '' update 1 2 1
  has   "the plan says so first"  "WOULD  break up the old vSAN disk group on naa.50000000000000a1"
  hasnt "and removes nothing"     "vsan storage remove"

  echo 1 > "$T/vsan_rm_fail"
  vsfix; scen 1 0 10 '' update 1 2 1
  has   "a group that will not come apart is a problem" "could not break up the old vSAN disk group"
  has   "and it says why that matters"                  "cannot be cleared while vSAN owns them"
  : > "$T/vsan_rm_fail"; : > "$T/vsanstore.txt"

  echo "---- the guards, each one a reason a host would lose data"
  printf 'Vmid Name File\n12 web01 [datastore1] web01/web01.vmx\n' > "$T/vms.txt"
  scen 1 0 10 '' update 1
  has   "registered VMs"   "keep datastore1 (has registered VMs)"
  hasnt "nothing removed"  "filesystem unmount"
  printf 'Vmid Name File\n' > "$T/vms.txt"

  printf '   String Value: /vmfs/volumes/67ed87fc-e293d481-a4a4-001122334455/.locker\n' > "$T/scratch.txt"
  scen 1 0 10 '' update 1
  has   "scratch lives on it" "holds this host.s scratch"
  hasnt "nothing removed"     "filesystem unmount"
  printf '   String Value: /scratch\n' > "$T/scratch.txt"

  # A dump file on the disk that the host is not actually using is not a
  # reason to keep the disk. The fixture carries one of each.
  scen 1 0 10 '' update 1
  hasnt "a stale dump does not block" "core dump"
  did   "so the disk is still cleared" "mklabel /vmfs/devices/disks/eui.00000000000000c3 gpt"

  sed 's/   Is Local: true/   Is Local: false/' "$T/core.txt" > "$T/c.tmp" && mv "$T/c.tmp" "$T/core.txt"
  scen 1 0 10 '' update 1
  has   "other hosts can see it" "keep datastore1 (other hosts can see it)"
  hasnt "nothing removed"        "filesystem unmount"
  sed 's/   Is Local: false/   Is Local: true/' "$T/core.txt" > "$T/c.tmp" && mv "$T/c.tmp" "$T/core.txt"

  echo
  if [ "$FAIL" = 0 ]; then echo "$P checks passed"; rm -rf "$T"; exit 0
  else echo "$P passed, $FAIL FAILED"; rm -rf "$T"; exit 1; fi
}

while [ $# -gt 0 ]; do
  case $1 in
    plan|--dry-run) APPLY=0 ;;
    apply|--apply)  APPLY=1 ;;
    list)           LIST=1 ;;
    -f)             [ $# -ge 2 ] || usage; CONF=$2; shift ;;
    --wipe-disks)   WIPE=1; CLEARDS=1 ;;
    --clear-datastores) CLEARDS=1 ;;
    --restore-vswitch) RESTORE=1 ;;
    selftest)       selftest ;;
    -h|--help)      usage ;;
    -*)             die "unknown option: $1" ;;
    *)              FILTERS="$FILTERS $1" ;;
  esac
  shift
done
[ -f "$CONF" ] || die "host list not found: $CONF"
[ "$WIPE" = 1 ] && [ "$APPLY" = 0 ] && die "--wipe-disks goes with apply (plan already shows which disks need it)"
:  # --clear-datastores is read in plan too, so the plan can show what it would remove

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
KEYS="hosts domain build bundle profile sha256 source datastore update_args update_mode mgmt_vlan mgmt_uplink min_uplinks ssh"
for k in $(awk '/^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ { k = $0; sub(/[ \t]*:.*/, "", k); print k }' "$CONF"); do
  case " $KEYS " in *" $k "*) ;; *) die "$CONF: '$k' is not a key hosts.yaml takes. It takes: $KEYS" ;; esac
done
CONFDIR=$(cd "$(dirname "$CONF")" && pwd)
DOMAIN=$(yaml_get domain)
BUILD=$(yaml_get build); BUNDLE=$(yaml_get bundle); PROFILE=$(yaml_get profile)
SHA256=$(yaml_get sha256); SOURCE=$(yaml_get source); UARGS=$(yaml_get update_args)
# 'update' only ever moves a VIB forward, so pointed at an older build it finds
# nothing to do and the host stays where it is. 'install' writes the profile
# exactly as it is, which is the only way down, and is opt-in because it also
# removes anything the profile does not carry.
UPMODE=$(yaml_get update_mode); UPMODE=${UPMODE:-update}
case $UPMODE in update|install) ;; *) die "update_mode: must be update or install, not '$UPMODE'" ;; esac
MGMTVLAN=$(yaml_get mgmt_vlan); MGMTUPLINK=$(yaml_get mgmt_uplink)
# The destination cluster's distributed switch is built on this many adapters,
# and VCF maps each host's pnics to them when the host joins. One adapter on
# vSwitch0 is what commissioning wants; the others still have to exist and be
# cabled, and a host that is short only finds out at the add.
MINUP=$(yaml_get min_uplinks); MINUP=${MINUP:-2}
case $MINUP in ''|*[!0-9]*) die "min_uplinks: must be a whole number, not '$MINUP'" ;; esac
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
  if [ -f "$SRC" ]; then BSIZE=$(ls -l "$SRC" | awk '{ print $5 }')
  else
    BUNDLE_WHY="bundle not found on this machine: $SRC"
    # A depot that is there under a slightly different name reads exactly like
    # one that was never downloaded. Name what is actually in the directory.
    near=$(ls -1 "$(dirname "$SRC")" 2>/dev/null \
      | awk '/[Dd]epot.*\.zip$/ { printf "%s%s", s, $0; s = ", " }')
    [ -n "$near" ] && BUNDLE_WHY="$BUNDLE_WHY
        that directory does have: $near
        if one of those is the right build, correct bundle: in $CONF to match it exactly"
  fi
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
    echo "update:    esxcli software profile $UPMODE ...${UARGS:+ $UARGS}"
  fi
  echo "mgmt vlan: ${MGMTVLAN:-not set - --restore-vswitch will refuse rather than guess it}"
  echo "mgmt nic:  ${MGMTUPLINK:-not set - the old switch's uplink that reports Link Up}"
  echo "uplinks:   at least $MINUP adapters must report Link Up (min_uplinks)"
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
REMOTE=0; SSHBIN=$(yaml_get ssh)
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
      -e "s|@MINUP@|$MINUP|g" -e "s|@CLEARDS@|$CLEARDS|g" -e "s|@RESTORE@|$RESTORE|g" -e "s|@MGMTVLAN@|$(esc "$MGMTVLAN")|g" \
      -e "s|@MGMTUPLINK@|$(esc "$MGMTUPLINK")|g" -e "s|@CONFNAME@|$(esc "$(basename "$CONF")")|g" \
      -e "s|@MGMT@|$(esc "$MGMT")|g" -e "s|@WANTPG@|$(esc "$WANTPG")|g" \
      -e "s|@BUILD@|$(esc "$BUILD")|g" -e "s|@BUNDLE@|$(esc "$BUNDLE")|g" -e "s|@BSIZE@|$BSIZE|g" \
      -e "s|@PROFILE@|$(esc "$PROFILE")|g" -e "s|@DS@|$(esc "$2")|g" \
      -e "s|@UPMODE@|$UPMODE|g" \
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
  echo "==== waiting for $(awk 'END { print NR }' "$TMP/wait") host(s) to come back: $(awk -F'|' '{ printf "%s%s", s, $2; s = " " }' "$TMP/wait")"
  echo "     up to $(dur "$WAIT_TIMEOUT"), checking every ${POLL}s. Ctrl-C is safe: apply again resumes."
  while [ -s "$TMP/wait" ]; do
    sleep "$POLL"; now=$(date +%s); : > "$TMP/wait.next"
    while IFS='|' read -r host short fq ds; do
      b=$(soap_build "$host"); down=0; [ -f "$TMP/$short.down" ] && down=1
      rst=0; [ -f "$TMP/$short.restoring" ] && rst=1
      # A restored host keeps its build, so "back on $BUILD" never fires for
      # it. Answering again is the signal; the pass that follows re-reads the
      # host and says so if the switch did not actually move.
      if { [ "$rst" = 1 ] && [ "$(reachable "$host")" = up ]; } \
         || [ "$b" = "$BUILD" ] || { [ "$down" = 1 ] && [ "$(reachable "$host")" = up ]; }; then
        echo "  $host is back${b:+ on build $b}; giving it ${SETTLE}s to settle"
        sleep "$SETTLE"; conn_close "$host"; conn_open "$host"; run_pass "$host" "$short" "$fq" "$ds"
        continue
      fi
      if [ "$down" = 0 ] && [ -z "$b" ] && [ "$(reachable "$host")" = down ]; then
        : > "$TMP/$short.down"; conn_close "$host"; echo "  $host is rebooting"
      fi
      t0=$(cat "$TMP/$short.t0")
      if [ $((now - t0)) -ge "$WAIT_TIMEOUT" ]; then
        if [ "$rst" = 1 ]; then
          set_state "$short" problem "did not answer again within $(dur "$WAIT_TIMEOUT") of moving $MGMT to a standard switch"
          echo "  PROBLEM $host has not answered since $MGMT was moved to vSwitch0 - the VLAN or the uplink is wrong. Recover it from the console: DCUI, Network Restore Options, Restore Standard Switch"
        else
          set_state "$short" problem "not back on $BUILD after $(dur "$WAIT_TIMEOUT") - apply again once it is"
          echo "  PROBLEM $host is not back on $BUILD after $(dur "$WAIT_TIMEOUT") - see $ULOGNAME on its datastore, then apply again"
        fi
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
      restoring)  txt="moving $MGMT to a standard switch - apply again once it answers" ;;
      left-alone) txt="left alone: $note" ;;
      *)          txt="PROBLEM: $(printf '%s' "${note:-see its output above}" | awk '{ s = $0; if (length(s) > 80) s = substr(s, 1, 77) "..."; print s }')" ;;
    esac
    [ "$st" = ready ] || nr=$((nr + 1))
    printf "%-${w}s  %-21s  %s\n" "$host" "$b" "$txt"
  done <<EOF
$SEL
EOF
  # One cause, every host, and the banner that said so has scrolled away by now.
  [ -n "$BUNDLE_WHY" ] && [ "$nr" -gt 0 ] && printf '\n%s\n' "$BUNDLE_WHY"
  return "$nr"
}

# ---- run
mode="PLAN - nothing will be changed"
[ "$APPLY" = 1 ] && mode="APPLY - changes will be made"
[ "$WIPE" = 1 ] && mode="$mode, INCLUDING DISK WIPES"
[ "$CLEARDS" = 1 ] && mode="$mode, REMOVING LOCAL DATASTORES"
[ "$RESTORE" = 1 ] && mode="$mode, RESTORING STANDARD SWITCHES"
echo "esx_ready.sh v$VERSION   $(date '+%Y-%m-%d %H:%M:%S')   $mode"
echo "host list: $CONF   build: ${BUILD:-not set}   management: $MGMT on '$WANTPG'"
if [ -n "$BUILD" ] && [ -n "$BUNDLE" ]; then
  [ "$UPMODE" = install ] && echo "update mode: PROFILE INSTALL - writes the image exactly, including downward, and removes anything the profile does not carry"
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
  case $(state_of "$short") in
    upgrading|rebooting) [ "$APPLY" = 1 ] && echo "$host|$short|$fq|$ds" >> "$TMP/wait" ;;
    restoring) [ "$APPLY" = 1 ] && { : > "$TMP/$short.restoring"; echo "$host|$short|$fq|$ds" >> "$TMP/wait"; } ;;
  esac
done <<EOF
$SEL
EOF
[ "$APPLY" = 1 ] && [ -s "$TMP/wait" ] && wait_for_upgrades
if [ -n "$LOCALLINE" ]; then   # the host running this: last, after everything else is done
  IFS='|' read -r host short fq ds <<EOF
$LOCALLINE
EOF
  one_host "$host" "$short" "$fq" "$ds"
  case $(state_of "$short") in
    upgrading|rebooting)
      echo "  $host is upgrading itself and reboots when done. Run apply here again once it's back."; echo ;;
    restoring)
      echo "  $host moved $MGMT to vSwitch0. This run cannot confirm it came back, because it is that host. Reach it at its own address and apply again."; echo ;;
  esac
fi
print_table && exit 0
exit 1

# ------------------------------------------------------------------ host side
# Runs on each host under busybox sh, which has no tr and no working 'command -v'.
# Never executed here. @X@ are filled in per host.
: <<'REMOTE_EOF'
APPLY=@APPLY@; WIPE=@WIPE@; FQDN='@FQDN@'; MGMT='@MGMT@'; WANTPG='@WANTPG@'
CLEARDS=@CLEARDS@; MINUP='@MINUP@'; RESTORE=@RESTORE@; MGMTVLAN='@MGMTVLAN@'; MGMTUPLINK='@MGMTUPLINK@'; CONFNAME='@CONFNAME@'
BUILD='@BUILD@'; BUNDLE='@BUNDLE@'; BSIZE='@BSIZE@'; PROFILE='@PROFILE@'; DS='@DS@'; UARGS='@UARGS@'
MINFREE='@MINFREE@'; STALE='@STALE@'; AGENTWAIT='@AGENTWAIT@'; UPMODE='@UPMODE@'
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
RLOG=/var/log/esx_ready-restore.log   # on the host: what a standard-switch restore did,
                                     # readable from the ESXi Shell when it does not come back
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
  # Never the boot disk's neighbours: a datastore on a disk vSAN would claim is
  # about to be removed, and staging a bundle there puts it on the cache device.
  # The boot device is the one disk vSAN never takes, so it is preferred.
  bootdev=$(esxcli storage core device list 2>/dev/null | awk '/^[^ ]/ { d = $1 } /Is Boot Device: true/ { print d; exit }')
  ineligible=" $(vdq -q 2>/dev/null | awk -F'"' '
    /"Name"/ { n = $4 } /"State"/ { if ($4 !~ /^Eligible/) printf "%s ", n }')"
  ok=$(printf '%s\n' "$rows" | awk -F'|' -v need="$NEED" -v boot="$bootdev" -v inel="$ineligible" -v ext="$(esxcli storage vmfs extent list 2>/dev/null | awk 'NR > 2 && NF >= 5 { printf "%s=%s ", $(NF-3), $(NF-1) }')" '
    function devof(mount,   u, i, n, p) {
      n = split(ext, p, " ")
      u = mount; sub(/.*\//, "", u)
      for (i = 1; i <= n; i++) { split(p[i], kv, "="); if (kv[1] == u) return kv[2] }
      return "" }
    $3 == 1 && $2 + 0 >= need + 0 {
      d = devof($1)
      rank = (d != "" && d == boot) ? 0 : (index(inel, " " d " ") ? 1 : 2)
      if (best == "" || rank < brank || (rank == brank && $2 + 0 > bfree)) {
        best = $1; brank = rank; bfree = $2 + 0; bdev = d } }
    END { if (best != "") printf "%s|%s|%d", best, (bfree >= 1000000000 ? sprintf("%d GB", bfree / 1000000000) : sprintf("%d MB", bfree / 1048576)), brank }')
  [ -n "$ok" ] || return 0
  m=${ok%%|*}; rest=${ok#*|}; free=${rest%|*}; rank=${rest##*|}
  case $rank in
    0) why="on the boot device, $free free" ;;
    1) why="the largest local storage not wanted by vSAN, $free free" ;;
    *) why="the largest local storage, $free free - NOTE this disk is one vSAN could claim" ;;
  esac
  printf '%s|%s\n' "$m" "${pre}${why}"
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


# ---- 0b. a distributed switch left behind by a vCenter that no longer owns this host
# Removing a host from a vCenter leaves the proxy switch on it with $MGMT still
# attached. Nothing else here can move a vmkernel between switches, so without
# this the host is stuck: it cannot be prepped and cannot be commissioned.
#
# This ends its own connection. The move runs detached, the host keeps its
# address, and the run then waits for it to answer again before going on. Two
# values decide whether it comes back, and neither is ever guessed: the VLAN
# the portgroup tags, and the uplink the switch is built on.
vmk_field() { printf '%s\n' "$1" | sed -n "s/^ *$2: *//p" | head -n 1; }

# One named switch's block out of a list. Reading the first block instead
# returns another switch's values on a host that has more than one.
dvs_field() {  # switch, field -> the field's value
  esxcli network vswitch dvs vmware list 2>/dev/null | awk -v want="$1" -v k="$2" '
    $0 == want { f = 1; next }
    f && /^[^[:space:]]/ { exit }
    f && index($0, k ":") { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
}
dvs_port_of() {  # switch, client -> the proxy switch port that client sits on
  esxcli network vswitch dvs vmware list 2>/dev/null | awk -v want="$1" -v cl="$2" '
    $0 == want { f = 1; next }
    f && /^[^[:space:]]/ { exit }
    f && index($0, "Client:") { c = $NF; next }
    f && c == cl && index($0, "Port ID:") { print $NF; exit }'
}
sw_uplinks() {  # the uplinks of one named standard switch
  esxcli network vswitch standard list 2>/dev/null | awk -v want="$1" '
    $0 == want { f = 1; next }
    f && /^[^[:space:]]/ { exit }
    f && index($0, "Uplinks:") { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
}
# ESX's busybox has no tr, so commas are split by sed and matched by awk
in_list() { printf '%s\n' "$1" | sed 's/,/ /g' | awk -v w="$2" '
  { for (i = 1; i <= NF; i++) if ($i == w) f = 1 } END { exit !f }'; }
nic_is_up() {
  esxcli network nic list 2>/dev/null | awk -v d="$1" '$1 == d && $5 == "Up" { u = 1 } END { exit !u }'
}
pg_switch_vlan() {  # standard portgroup -> "<switch> <vlan>", so a silent set is caught
  esxcli network vswitch standard portgroup list 2>/dev/null | awk -v p="$1" '
    index($0, p) == 1 && substr($0, length(p) + 1, 1) == " " { print $(NF-2), $NF; exit }'
}

restore_vswitch() {
  info=$(esxcli network ip interface list 2>/dev/null \
    | awk -v m="$MGMT" '$1==m{f=1; print; next} f&&/^[^ ]/{exit} f{print}')
  vds=$(vmk_field "$info" "VDS Name")
  port=$(vmk_field "$info" "VDS Port")
  mtu=$(vmk_field "$info" "MTU")
  [ -n "$mtu" ] || mtu=1500
  addr=$(esxcli network ip interface ipv4 get -i "$MGMT" 2>/dev/null \
    | awk -v m="$MGMT" '$1==m{print $2" "$3; exit}')
  ip=${addr%% *}; mask=${addr##* }

  if [ -z "$vds" ] || [ -z "$port" ] || [ -z "$ip" ] || [ -z "$mask" ]; then
    bad "cannot read $MGMT's switch and address well enough to move it safely (vds='$vds' port='$port' ip='$ip' mask='$mask') - use the console: DCUI, Network Restore Options, Restore Standard Switch"
    return 1
  fi

  # The VLAN the new portgroup tags. Wrong here and the host does not come back.
  vlan="$MGMTVLAN"
  case $vlan in
    ""|*[!0-9]*)
      bad "mgmt_vlan is not set in $CONFNAME, and the VLAN $MGMT is tagged with on $vds cannot be read from the host. Guessing it strands the host. Set 'mgmt_vlan: <id>' (0 when the port is untagged)"
      return 1 ;;
  esac

  # The uplink the new switch is built on. Explicit beats inferred: which pnic
  # carries management is a site fact, and two ports of one card are not
  # interchangeable when only one of them is cabled.
  dvsup=$(dvs_field "$vds" "Uplinks")
  if [ -n "$MGMTUPLINK" ]; then
    up="$MGMTUPLINK"
    if ! in_list "$dvsup" "$up"; then
      bad "mgmt_uplink is $up but $vds does not use it (it uses ${dvsup:-nothing}) - $up is not the adapter carrying management on this host"
      return 1
    fi
    if ! nic_is_up "$up"; then
      bad "mgmt_uplink is $up but that adapter does not report Link Up - a standard switch built on it would not reach the network"
      return 1
    fi
  else
    cands=$(printf '%s\n' "$dvsup" | sed 's/,/ /g')
    if [ -z "$cands" ]; then
      bad "cannot read which adapters $vds uses on this host. Set 'mgmt_uplink: vmnicN' in $CONFNAME to the adapter carrying management"
      return 1
    fi
    up=""; nup=0
    for n in $cands; do
      nic_is_up "$n" || continue
      nup=$((nup + 1)); [ -n "$up" ] || up="$n"
    done
    if [ -z "$up" ]; then
      bad "none of $vds's adapters ($cands) reports Link Up. Check the cabling, or set 'mgmt_uplink: vmnicN' in $CONFNAME"
      return 1
    fi
    [ "$nup" -gt 1 ] && say "$vds has $nup adapters up ($cands); using $up. Set mgmt_uplink in $CONFNAME to pin it"
  fi

  # A pnic belongs to one switch at a time, so $up has to be released from the
  # proxy switch before vSwitch0 can claim it. Without the port it sits on
  # there is no way to release it, and a standard switch with no uplink does
  # not reach the network.
  upport=$(dvs_port_of "$vds" "$up")
  if [ -z "$upport" ]; then
    bad "cannot find the port $up sits on in $vds, so it cannot be released from it - use the console: DCUI, Network Restore Options, Restore Standard Switch"
    return 1
  fi

  what="restore $MGMT to a standard switch: vSwitch0, $WANTPG vlan $vlan, uplink $up released from $vds port $upport, keeping $ip/$mask"
  if [ "$APPLY" != 1 ]; then plan "$what"; return 0; fi
  act "$what"

  # Build the switch first. Nothing here touches the live path, so a failure
  # leaves the host up and reachable.
  esxcli network vswitch standard add -v vSwitch0 >/dev/null 2>&1
  esxcli network vswitch standard portgroup add -p "$WANTPG" -v vSwitch0 >/dev/null 2>&1
  esxcli network vswitch standard portgroup set -p "$WANTPG" --vlan-id "$vlan" >/dev/null 2>&1
  got=$(pg_switch_vlan "$WANTPG")
  if [ "$got" != "vSwitch0 $vlan" ]; then
    bad "could not put $WANTPG on vSwitch0 tagged for VLAN $vlan - it reads as '${got:-absent}'. Nothing was moved"
    return 1
  fi
  vim-cmd hostsvc/enable_ssh >/dev/null 2>&1

  # Past here runs without us: releasing the uplink ends this session. What it
  # does is written to $RLOG on the host, which is readable from the ESXi
  # Shell if the host does not come back.
  ( trap "" HUP
    exec >>"$RLOG" 2>/dev/null || exec >/dev/null
    exec 2>&1
    echo "=== $(date) $MGMT $ip/$mask -> vSwitch0/$WANTPG vlan $vlan on $up, from $vds port $port"
    esxcfg-vswitch -Q "$up" -V "$upport" "$vds"
    esxcli network vswitch standard uplink add -u "$up" -v vSwitch0
    # Moving $MGMT onto a switch with no uplink takes the host off the network
    # with no way back but a console. Stop here instead, while it is still up.
    if ! in_list "$(sw_uplinks vSwitch0)" "$up"; then
      # $up has already left $vds, so the host has no uplink at all right now.
      # Put it back: that is the state the host was reachable in.
      esxcfg-vswitch -P "$up" -V "$upport" "$vds"
      if in_list "$(dvs_field "$vds" Uplinks)" "$up"; then
        echo "ABORT: $up did not attach to vSwitch0, so it was put back on $vds. $MGMT never moved; the host is as it was."
      else
        echo "ABORT: $up attached to neither vSwitch0 nor $vds. $MGMT is still on $vds but has no uplink - recover from the console: DCUI, Network Restore Options, Restore Standard Switch."
      fi
      exit 1
    fi
    # The other vmkernels are on the same dead switch and are rebuilt by the
    # prep that follows. They go first so the new one takes the lowest free
    # index and comes back as $MGMT.
    for v in $(esxcli network ip interface list 2>/dev/null | awk '/^vmk/{print $1}'); do
      [ "$v" = "$MGMT" ] && continue
      esxcli network ip interface remove -i "$v"
    done
    esxcfg-vmknic -d -v "$port" -s "$vds"
    esxcfg-vmknic -a -i "$ip" -n "$mask" -m "$mtu" -p "$WANTPG"
    esxcli network ip interface tag add -i "$MGMT" -t Management
    net-dvs -d "$vds"
    echo "=== done: $(esxcli network ip interface ipv4 get -i "$MGMT" 2>&1)"
  ) </dev/null >/dev/null 2>&1 &
  return 2
}
case $portset in
  *[Dd][Vv][Ss]*)
    # A host removed from a vCenter keeps the distributed switch: the proxy
    # switch stays and $MGMT stays on it. That is a different problem from a
    # host still in a cluster, and it has a different fix, so say which.
    case $mgmtsrv in
      ""|"<unset>")
        if [ "$RESTORE" = 1 ]; then
          restore_vswitch; rc=$?
          if [ "$rc" = 2 ]; then
            NOTE="restoring the standard switch"
            say "STATUS $build restoring - - moving $MGMT to vSwitch0, keeping its address; run again once it answers"
            exit 0
          elif [ "$rc" = 0 ]; then
            LEFT=1; NOTE="standard switch to restore"   # plan: the line above says what it would do
          else
            LEFT=1                                      # bad() set NOTE to why
          fi
        else
          bad "$MGMT is on a distributed switch ($portset) but no vCenter manages this host - the switch was left behind when it was removed. Run apply with --restore-vswitch to move $MGMT to a standard switch, or do it from the DCUI (Network Restore Options)"
          LEFT=1; NOTE="distributed switch left behind - apply with --restore-vswitch"
        fi ;;
      *)
        bad "$MGMT is on a distributed switch ($portset) - already in a cluster, not touching this host"
        LEFT=1; NOTE="in a cluster" ;;
    esac ;;
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
        verb=upgrade; [ "$UPMODE" = install ] && verb="write the exact image"
        plan "$verb $build -> $BUILD${prof:+ with $prof}: maintenance mode, then the host reboots itself"
      elif [ -z "$prof" ] || [ "$(printf '%s\n' "$prof" | awk 'END { print NR }')" != 1 ]; then
        bad "cannot pick one image profile in $BUNDLE - set profile: in hosts.yaml"; UPSTATE=blocked
      else
        left=""
        dry=$(esxcli software profile $UPMODE -d "$zip" -p "$prof" $UARGS --dry-run 2>&1); rc=$?
        if [ "$rc" != 0 ]; then
          case $dry in *[Mm]aintenance*)   # in case this build only dry-runs in maintenance mode
            esxcli system maintenanceMode set -e true >/dev/null 2>&1 && left=", host left in maintenance mode"
            dry=$(esxcli software profile $UPMODE -d "$zip" -p "$prof" $UARGS --dry-run 2>&1); rc=$? ;;
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
              esxcli software profile $UPMODE -d "$zip" -p "$prof" $UARGS > "$ulog" 2>&1
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

  # Enough cabled adapters for the switch the destination cluster is built on.
  # esx_ready leaves one on vSwitch0, which is what commissioning wants, but the
  # add to a cluster maps this host's pnics to that cluster's VDS uplinks. A
  # host short of adapters passes every check here and fails there.
  live=$(esxcli network nic list 2>/dev/null | awk 'NR > 2 && $5 == "Up" { printf "%s ", $1 }')
  nlive=$(printf '%s' "$live" | awk '{ print NF }')
  if [ "$nlive" -lt "$MINUP" ]; then
    bad "$nlive adapter(s) report Link Up (${live:-none}) - the destination cluster's switch is built on $MINUP. Cabling has to be fixed before this host can join, and commissioning will not catch it"
  else
    say "adapters Link Up: $nlive (${live}) - enough for a $MINUP-uplink switch"
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
    # esxcli has no rename for a standard portgroup: 'portgroup set' takes a vlan
    # id and nothing else. Renaming means adding the new one and moving $MGMT to
    # it, which drops the connection this is running over. Neither commissioning
    # nor the cluster build reads the name, so it is reported, not changed.
    say "management portgroup is '$mgmt_pg', not '$WANTPG' - left as it is, nothing downstream reads the name"
  fi
fi

# ---- 5. disks
STEP=disks
# The cluster goes first. While this host is still a member, vSAN owns the
# disks and partedUtil is refused on every one it has claimed - which is most
# of them.
if [ "$WIPE" = 1 ]; then
  cl=$(esxcli vsan cluster get 2>/dev/null | sed -n 's/^ *Enabled: *//p')
  if [ "$cl" = "true" ]; then
    if [ "$APPLY" = 1 ]; then
      if esxcli vsan cluster leave >/dev/null 2>&1; then
        act "leave the old vSAN cluster"
        sleep 5                       # the disks are not released the instant it returns
      else bad "could not leave the old vSAN cluster - its disks cannot be cleared while it is a member"; fi
    else plan "leave the old vSAN cluster, then clear its disks"; fi
  fi
fi
# Leaving the cluster drops membership, not the disk groups, and a host that was
# never in one can still carry them. vSAN owns every disk in a group, so
# partedUtil gets "Read-only file system" on all of them. A cache disk cannot be
# removed on its own either - the group it anchors has to come apart first.
if [ "$WIPE" = 1 ]; then
  dgs=$(esxcli vsan storage list 2>/dev/null \
    | sed -n 's/^ *VSAN Disk Group Name: *//p' | awk 'NF && !seen[$0]++')
  for dg in $dgs; do
    if [ "$APPLY" != 1 ]; then
      plan "break up the old vSAN disk group on $dg, then clear its disks"
      continue
    fi
    if esxcli vsan storage remove -s "$dg" -m noAction >/dev/null 2>&1 \
       || esxcli vsan storage remove -s "$dg" >/dev/null 2>&1; then
      act "break up the old vSAN disk group on $dg"
      sleep 5                         # the disks are not released the instant it returns
    else
      bad "could not break up the old vSAN disk group on $dg - its disks cannot be cleared while vSAN owns them"
    fi
  done
fi
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
    # A disk still in a group is read-only to partedUtil. -m noAction first:
    # out of a cluster the default policy cannot evacuate anything, so the
    # removal is refused before it starts.
    esxcli vsan storage remove -d "$dev" -m noAction >/dev/null 2>&1 \
      || esxcli vsan storage remove -d "$dev" >/dev/null 2>&1 \
      || esxcli vsan storage remove -u "$dev" >/dev/null 2>&1
    try=0; wiped=0; mkout=""
    while :; do
      if mkout=$(partedUtil mklabel "/vmfs/devices/disks/$dev" gpt 2>&1); then wiped=1; break; fi
      try=$((try + 1)); [ "$try" -ge 3 ] && break
      sleep 3
    done
    if [ "$wiped" = 1 ]; then
      act "wipe $dev ($st / $rs)${try:+${try:+}}"
      [ "$try" -gt 0 ] && say "    $dev took $((try + 1)) attempts"
    else
      bad "could not clear partitions on $dev ($st / $rs): $(printf '%s' "$mkout" | awk 'NF { sub(/^ +/, ""); print; exit }')"
    fi
  done
  IFS=$oifs
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

# ---- 5c. a local datastore standing between a disk and vSAN. VCF will not commission a
# host for vSAN while a disk still carries partitions, and a datastore is partitions. The
# disk it sits on is often the one the cluster wants as its OSA cache. --clear-datastores
# unmounts it and clears the disk's partition table; without the flag it is only reported,
# because a host that is not heading for vSAN may want its local storage. Never one other
# hosts can see, one spanning several extents, one with registered VMs, the boot device,
# or one holding this host's scratch or core dump.
STEP=datastores
dss=$(esxcli storage filesystem list 2>/dev/null | awk '$(NF-3) == "true" && $(NF-2) ~ /^VMFS/ {
        n = $2; for (i = 3; i <= NF - 5; i++) n = n " " $i; print $1 "|" n }')
if [ -z "$dss" ]; then
  say "local datastores: none mounted"
else
  dlocal=" $(esxcli storage core device list 2>/dev/null | awk '/^[^ ]/ { d = $1 } /Is Local: true/ { printf "%s ", d }')"
  dext=$(esxcli storage vmfs extent list 2>/dev/null | awk 'NR > 2 && NF >= 5 { print $(NF-3) "=" $(NF-1) ":" $NF }')
  dvms=$(vim-cmd vmsvc/getallvms 2>/dev/null)
  scratch=$(esxcli system settings advanced list -o /ScratchConfig/ConfiguredScratchLocation 2>/dev/null | sed -n 's/^ *String Value: *//p')
  curscr=$(esxcli system settings advanced list -o /ScratchConfig/CurrentScratchLocation 2>/dev/null | sed -n 's/^ *String Value: *//p')
  dumps=$(esxcli system coredump file list 2>/dev/null | awk 'NR > 2 && ($2 == "true" || $3 == "true") { print $1 }')
  # A disk's partition table can only be cleared when every volume on it is
  # unmounted, and these disks carry two: a datastore and an ESX-OSData
  # partition from an earlier install. So the decision is per datastore and
  # the work is per device - one device that holds anything worth keeping is
  # left alone entirely.
  clearable=""; blocked=""
  oifs=$IFS; IFS='
'
  for row in $dss; do
    IFS=$oifs
    m=${row%%|*}; name=${row#*|}; u=${m##*/}; part=""; nex=0; shared=0
    for e in $dext; do case $e in "$u="*) p=${e#*=}; nex=$((nex + 1)); part=$p
      case $dlocal in *" ${p%:*} "*) ;; *) shared=1 ;; esac ;; esac; done
    dev=${part%:*}
    keep=""
    if   [ "$nex" = 0 ];      then keep="its disk could not be identified"
    elif [ "$shared" = 1 ];   then keep="other hosts can see it"
    elif [ "$nex" != 1 ];     then keep="spans $nex extents"
    elif [ "$dev" = "$boot" ];then keep="on the boot device"
    elif printf '%s\n' "$dvms" | grep -qF "[$name] "; then keep="has registered VMs"
    else
      held=""
      case "$scratch$curscr" in *"/vmfs/volumes/$u"*|*"/vmfs/volumes/$name/"*) held="scratch" ;; esac
      for f in $dumps; do case $f in *"/vmfs/volumes/$u"*|*"/vmfs/volumes/$name/"*) held="${held:+$held and a }core dump" ;; esac; done
      [ -n "$held" ] && keep="holds this host's $held"
    fi
    if [ -n "$keep" ]; then
      say "keep $name ($keep)"
      [ -n "$dev" ] && blocked="$blocked $dev"
      case $keep in "holds this host's"*)
        say "    scratch: ${curscr:-unset}"
        for f in $dumps; do say "    active core dump: $f"; done ;;
      esac
      IFS='
'
      continue
    fi
    clearable="$clearable$dev|$u|$name
"
    IFS='
'
  done
  IFS=$oifs

  # one line per device, with every volume it carries
  devs=$(printf '%s' "$clearable" | awk -F'|' 'NF == 3 { d[$1] = d[$1] " " $2 "=" $3 } END { for (k in d) print k "|" substr(d[k], 2) }')
  oifs=$IFS; IFS='
'
  for drow in $devs; do
    IFS=$oifs
    dev=${drow%%|*}; vols=${drow#*|}
    case " $blocked " in *" $dev "*)
      say "keep the volumes on $dev - something else on that disk has to stay"
      IFS='
'
      continue ;;
    esac
    names=$(printf '%s' "$vols" | sed 's/[^ ]*=//g; s/^ //')
    if [ "$CLEARDS" != 1 ]; then
      bad "$names is on $dev, a disk vSAN would otherwise claim. VCF will not commission this host for vSAN while it exists - apply --wipe-disks (or --clear-datastores) removes it"
      IFS='
'
      continue
    fi
    if [ "$APPLY" != 1 ]; then
      plan "remove $names from $dev and clear it (their contents are gone)"
      IFS='
'
      continue
    fi
    # every volume off the disk first: partedUtil refuses while one is mounted
    bad_unmount=""
    for v in $vols; do
      vu=${v%%=*}; vn=${v#*=}
      if ! out=$(esxcli storage filesystem unmount -u "$vu" 2>&1); then
        bad_unmount="$vn: $(printf '%s' "$out" | awk 'NF { print; exit }')"
        break
      fi
      say "unmounted $vn"
    done
    if [ -n "$bad_unmount" ]; then
      for v in $vols; do esxcli storage filesystem mount -u "${v%%=*}" >/dev/null 2>&1; done
      bad "cannot unmount everything on $dev ($bad_unmount) - the datastores are mounted again"
      IFS='
'
      continue
    fi
    # esxcli returns before the volume has finished detaching, and partedUtil
    # refuses while any of them is still listed. Wait for them to go rather
    # than racing it.
    w=0
    while :; do
      still=""
      for v in $vols; do
        esxcli storage filesystem list 2>/dev/null | grep -q "${v%%=*}" && still="$still ${v#*=}"
      done
      [ -z "$still" ] && break
      [ "$w" -ge 20 ] && break
      sleep 1; w=$((w + 1))
    done
    [ "$w" -gt 0 ] && say "    waited ${w}s for the volumes to detach"
    [ -n "$still" ] && say "    still listed after ${w}s:$still"
    # partedUtil's reason for refusing is the whole diagnosis, so keep it, and
    # print the table with it: a disk still carrying ESX system partitions is a
    # different problem from one carrying only datastores.
    # A refusal here is usually the disk not being free yet, so it is worth
    # asking again before giving up. getptbl first both reads the table for
    # the error message and makes the kernel look at the device again.
    try=0; cleared=0; mkout=""; ptbl=""
    while :; do
      ptbl=$(partedUtil getptbl "/vmfs/devices/disks/$dev" 2>&1)
      if mkout=$(partedUtil mklabel "/vmfs/devices/disks/$dev" gpt 2>&1); then cleared=1; break; fi
      try=$((try + 1)); [ "$try" -ge 3 ] && break
      sleep 3
    done
    [ "$try" -gt 0 ] && [ "$cleared" = 1 ] && say "    cleared on attempt $((try + 1))"
    if [ "$cleared" = 1 ]; then
      if vdq -q 2>/dev/null | awk -F'"' -v d="$dev" '
           /"Name"/{n=$4} /"State"/{if (n == d && $4 ~ /^Eligible/) f = 1}
           END { exit !f }'; then
        act "remove $names, clear $dev - now eligible for vSAN"
      else
        act "remove $names and clear $dev"
        say "    $dev still does not read as eligible for vSAN - check it before commissioning"
      fi
    else
      for v in $vols; do esxcli storage filesystem mount -u "${v%%=*}" >/dev/null 2>&1; done
      bad "could not clear $dev after unmounting $names - the datastores are mounted again: $(printf '%s' "$mkout" | awk 'NF { sub(/^ +/, ""); print; exit }')"
      printf '%s\n' "$mkout" | awk 'NF && n++ < 4 { print "    | " $0 }'
      say "    partition table on $dev:"
      printf '%s\n' "$ptbl" | awk 'NF && n++ < 14 { print "    | " $0 }'
    fi
    IFS='
'
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
