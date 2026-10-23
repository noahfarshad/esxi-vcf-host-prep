# ESXi hosts, ready to commission

Three shell scripts that read one `hosts.yaml` and take standalone ESXi hosts from racked and pingable to the state VCF 9.1 host commissioning accepts: the right build, the hostname, one vmkernel, one uplink, one portgroup, clean disks, VMFS-6, a certificate that names the host, and out of maintenance mode. Plan by default. A host that is already in a cluster, managed by a vCenter or waiting on a reboot is left alone. `esx_ready.sh` carries its own self-test: 104 checks against a stubbed host, no network needed.

License: GPL-3.0. Built and proved out for [essential.coach](https://essential.coach).
Full write-up: [Sixteen Hosts, Seven Requirements, One Command: Getting ESXi Hosts Ready for VCF Commissioning](https://essential.coach/esxi-hosts-ready-for-vcf-commissioning/). The day that took `esx_ready.sh` from 1.12 to 1.20, nine versions on a live fleet: [Everything That Cost Us a Day Returned Success](https://essential.coach/everything-that-cost-a-day-returned-success/).

## What commissioning checks

VCF addresses a host by name, connects by name, and refuses anything that looks like a previous life ([Commission ESX Hosts](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/building-your-private-cloud-infrastructure/host-management/commission-hosts.html)). A host fails the wizard if any one of these is wrong, and the wizard names one host at a time:

| # | Requirement | Step |
|---|---|---|
| 1 | Hostname is the FQDN | `hostname` |
| 2 | Exactly one vmkernel adapter, `vmk0` | `vmkernels` |
| 3 | One uplink on the management vSwitch | `uplinks` |
| 4 | One portgroup on that vSwitch | `portgroups` |
| 5 | No stale vSAN partitions on the data disks | `disks` |
| 6 | Certificate names the FQDN | `certificate` |
| 7 | Not in maintenance mode | `maintenance` |

Plus VMFS-6 on the local datastores (`vmfs6`), no local datastore standing between a disk and vSAN (`datastores`), and the right build before any of it matters (`upgrade`).

The runbooks say the management portgroup is named `Management Network`. A host whose portgroup is called something else is reported and left as it is: `esxcli network vswitch standard portgroup set` takes a VLAN id and nothing else, so the only way to change the name is to add a new portgroup and move `vmk0` onto it, which drops the connection the run is travelling over. Nothing in commissioning, the vSphere 8 build or the VCF import reads the name. An earlier version tried the rename, failed on every host with `Error: Invalid option -n`, and was removed rather than hidden behind a flag. If a commissioning run is ever rejected over the name, rename it from the DCUI, on the console, not over the network.

## Which script

| Script | Version | Shell | Upgrades | Preps | |
|---|---|---|---|---|---|
| `esx_ready.sh` | 1.20 | POSIX sh | yes | yes | **Use this one.** Both phases in one pass, waits out the reboots, resumable, self-tested |
| `esx_prep.sh` | 3.0 | bash | no | yes | The seven steps only. Refuses a host that is not already on `build:` |
| `esx_push.sh` | | POSIX sh | yes | no | The original: stage the bundle and upgrade |

`esx_ready.sh` has no dependencies and runs from a jump box or from one of the hosts in the list. On a host, that host puts itself last, and the script opens the `sshClient` firewall ruleset if it has to and closes it again on the way out. One SSH login per host per run; the connections after it reuse the first. With `sshpass` installed the root password comes from `ESXPW`; otherwise ssh prompts.

`esx_prep.sh` is for a fleet already on the right build when only the prep steps are wanted. It dry-runs by default, `--apply` changes things, and `LOGDIR` (default `./prep-logs`) and `PARALLEL` are environment variables.

## hosts.yaml

One file, read by all three. `hosts.example.yaml` documents every key. `esx_ready.sh` takes exactly these fourteen and treats any other key as a hard error that prints the list, because a mistyped key silently doing nothing is worse than a stop:

| Key | Required | Meaning |
|---|---|---|
| `hosts` | yes | the list: `- host: <fqdn or ip>`, with optional `fqdn:` and `datastore:` under it |
| `domain` | no | appended to bare host names to form the FQDN |
| `build` | for upgrades | the target build number; also what `esx_prep.sh` demands a host already be on |
| `bundle` | for upgrades | the depot zip. Needs `build:` |
| `profile` | no | the image profile inside the zip; by default the one ending `-standard` |
| `sha256` | no | checked after the copy, so a bad download is caught before the upgrade, not during it |
| `source` | no | where the zip is on this machine; by default next to the script |
| `datastore` | no | where the zip is staged on each host (below); default `auto` |
| `update_args` | no | extra flags for `esxcli software profile`. The dry run tells you when you need one |
| `update_mode` | no | `update` (default) or `install`. `update` only ever moves a VIB forward: pointed at an older build it reports success and the host stays where it is. `install` writes the profile exactly, which is the only way down, and removes anything the profile does not carry |
| `min_uplinks` | no | adapters that must report Link Up on each host, default 2. Commissioning wants one uplink on vSwitch0; the add to a cluster maps the host's pnics to that cluster's distributed switch, and a host short of cabled adapters passes every check here and fails there |
| `mgmt_vlan` | for `--restore-vswitch` | the VLAN the management portgroup tags, `0` when untagged. Never guessed |
| `mgmt_uplink` | no | the adapter carrying management, for `--restore-vswitch`; otherwise the old switch's adapter that reports Link Up |
| `ssh` | no | the ssh client to use when PATH has none |

`datastore:` takes a name, where `{short}` is the host without its domain and `{host}` is the entry as written, so `"{short}_ds1"` covers sixteen hosts with sixteen datastore names in one line; a full path such as `/vmfs/volumes/datastore1`; or `auto`. `auto` ranks the local storage with room: the boot device first, then a disk vSAN would not claim, and only then one it would, which is usually the cache disk the cluster most needs clean. Shared VMFS is never used for staging: two hosts staging to one volume interleave their update logs and neither is readable afterwards. When the bundle is not where `source:` says, the error names the depot zips that are in that directory, so a near-miss filename does not read like a missing download.

An IP address entry needs `fqdn:` under it; nothing can guess it. `esx_push.sh` and `esx_prep.sh` also read `user:`, and `esx_prep.sh` reads `mgmt_vmk:` and `mgmt_portgroup:`. `esx_ready.sh` refuses those three, so a file that carries them is run with `-f` against the script that understands it.

Built in, not configurable: `SSHUSER=root`, `MGMT=vmk0`, `WANTPG="Management Network"`, and the timings (`PROBE=8`, `POLL=20`, `SETTLE=90`, `WAIT_TIMEOUT=3600`, `AGENTWAIT=180`, `STALE=7200`). They are VCF's requirements and hard-won waits, not site preferences.

## Run

```sh
sh esx_ready.sh selftest                # 104 checks against a stubbed host; connects to nothing
read -rs ESXPW && export ESXPW          # the root password never reaches shell history
sh esx_ready.sh list                    # how hosts.yaml was read; connects to nothing
sh esx_ready.sh plan                    # what would change on every host (the default)
sh esx_ready.sh apply                   # do it, and wait out the reboots
sh esx_ready.sh apply --wipe-disks      # also clear stale vSAN partitions, remove local datastores
                                        # standing between a disk and vSAN, recreate VMFS-5 as VMFS-6
sh esx_ready.sh apply --clear-datastores   # only the local datastores; plan shows them too
sh esx_ready.sh apply --restore-vswitch    # move vmk0 off a distributed switch a vCenter left behind
sh esx_ready.sh plan esx05 esx06        # a subset, by short name or as written
sh esx_ready.sh apply -f other-fleet.yaml
unset ESXPW
```

`--wipe-disks` goes only with `apply`; with `plan` it is rejected, because plan already lists which disks need it and why. `--clear-datastores` and `--restore-vswitch` are read by `plan` as well, so the plan can say what each would do. `bundle:` without `build:` is rejected.

Every run ends with one table, and each host reads one of these:

| State | Meaning |
|---|---|
| `ready` | commissionable now; `did:` lists what changed |
| `to do: …` | changes pending, which `plan` listed |
| `upgrade` | needs the build change, then whatever follows it |
| `upgrade in progress` | the update is running on the host; `apply` again to finish it |
| `rebooting` | waiting for it to come back |
| `moving vmk0 to a standard switch` | `--restore-vswitch` is under way; `apply` again once the host answers |
| `left alone: …` | not standalone and settled; the reason is on the line |
| `PROBLEM: …` | something failed; the host's own output is above |

The exit code is 0 only when every host reads `ready`, so it drops into a pipeline without anyone parsing output. Each host's last two lines are machine-readable, `STATUS <build> <state> <did> <todo> <note>` and `RESULT changes=N problems=N`, and its full output is kept under `ready-logs/` next to the hosts file. Ctrl-C is safe: all state lives on the hosts, not in the script, and `apply` again resumes, with finished hosts reporting `ready` and hosts mid-upgrade waited on.

```sh
./esx_prep.sh                       # dry run, every host
./esx_prep.sh --apply esx01         # fix one host first
./esx_prep.sh --apply --wipe-disks
PARALLEL=4 ./esx_prep.sh --apply
```

`esx_prep.sh` writes a `summary` under `LOGDIR` and exits non-zero if any host reported a problem. Re-run it without `--apply` afterwards: every host should report `changes=0`.

## What it will not do

More of this code is "should I touch this at all" than "touch it".

The whole host is left alone when the management vmkernel is on a distributed switch that a vCenter still owns (that host is in a cluster, whatever the ticket says), when `managementServerIp` is set (a vCenter manages it; remove it there first), or when a reboot is pending that no upgrade of ours explains. A distributed switch with no vCenter behind it is a different case, below.

Within a host: the management vmkernel is never removed or reconfigured; only the extras go. The uplink kept is one reporting Link Up, and if none does, uplinks are not touched: better two than none. The boot device is never wiped, and neither is a disk holding a VMFS datastore, both checked against the live device list, not inferred. Only ESXi's own self-signed certificate is regenerated; a CA-issued one is reported and left alone. The old pair is kept as `rui.*.<timestamp>.bak` and put back if generation fails, `auto-backup.sh` runs so the new one survives a reboot, and the management agents are restarted only when port 443 has to pick it up. VMFS-5 is recreated as VMFS-6 only when the datastore is local, single-extent and has no registered VMs: unmount, `vmkfstools -C vmfs6`, verify, and remount the old one if it failed. The partition table is never edited.

A local datastore is removed, and the disk under it cleared, only with `--clear-datastores` or `--wipe-disks`, and never when other hosts can see it, when it spans several extents, when it has registered VMs, when it is on the boot device, or when this host's scratch or an active core dump lives on it. A dump file that merely exists on the datastore, left by a previous install, is not a reason to keep the disk: the check is whether it reads `Active` or `Configured`. Without the flag such a datastore is reported as a problem, not removed, because VCF will not commission the host for vSAN while a disk still carries partitions and the disk holding the local datastore is often the one the cluster wants as its cache device. The decision is per datastore and the work is per device: one disk that holds anything worth keeping is left alone entirely.

## vSAN owns the disks until it does not

A disk that is still vSAN's is read-only to `partedUtil`, and `--wipe-disks` learned the chain one wrong guess at a time:

1. **Cluster membership.** While the host is a vSAN cluster member, vSAN owns every disk it has claimed. `esxcli vsan cluster leave` comes first, before the disk loop, and the disks are not released the instant it returns, so the run settles before going on.
2. **Disk groups survive the leave.** Leaving drops membership; the groups stay, and a host that was never in a cluster can still carry them. A cache disk cannot be removed on its own, so each group is broken up by its cache device, `esxcli vsan storage remove -s <cache disk> -m noAction`. `-m noAction` is not optional: out of a cluster the default evacuation policy cannot be satisfied and the removal is refused before it starts, with a message about data accessibility that reads like a safety check rather than an impossibility.
3. **Partitions.** Only now does `partedUtil mklabel` work.
4. **And it still needs a retry.** `esxcli` returns before a volume has finished detaching, so `partedUtil` refuses once and succeeds a moment later. Three attempts, and real runs have needed the third.

Two findings from the same loop: a disk carrying a datastore and a stale `OSDATA` volume from an earlier install needs two unmounts and one `mklabel`, so clearing is per device, with a wait for every volume to detach; and the plan says `leave the old vSAN cluster, then clear its disks` and `break up the old vSAN disk group on <disk>, then clear its disks` before a single partition goes.

## A distributed switch nobody owns

A host removed from a vCenter keeps the proxy switch, with `vmk0` still on it. Nothing else here can move a vmkernel between switches, so without help the host is stuck: it cannot be prepped and cannot be commissioned. `--restore-vswitch` builds `vSwitch0` and the management portgroup first, tagged with `mgmt_vlan:`, and checks that the portgroup reads back on the right switch with the right VLAN before anything live is touched. Then, detached from the SSH session it is about to lose, it releases the uplink from the proxy switch port it sits on, attaches it to `vSwitch0`, and stops if the standard switch does not come up with that uplink, putting the uplink back where it was: the host is as it was, and the restore log on it says so. Only then do the other vmkernels come off, `vmk0` is recreated on the new portgroup with the same address, mask and MTU, tagged for management, and the old switch is deleted.

The VLAN is never guessed, and the uplink is either `mgmt_uplink:` or the old switch's adapter that reports Link Up, checked against the switch's own uplink list. The run then waits for the host to answer again, up to an hour, and reports `PROBLEM` with the console fix if it does not: DCUI, Network Restore Options, Restore Standard Switch. `/var/log/esx_ready-restore.log` on the host records how far it got. Running this from the host being restored is allowed, but the run cannot confirm that host came back, because it is that host.

## The upgrade

```
on the right build ──────────────────────────────────────► steps 1-7
       │
       ▼
copy the bundle ──► sha256 ──► esxcli ... --dry-run ──► maintenance mode
                                      │                        │
                             fails ◄──┘ nothing installed,     ▼
                                        output kept        enable SSH for after the reboot,
                                                           background the update (trap "" HUP),
                                                           write a .running stamp, reboot
                                                                     │
                                                                     ▼
                                           poll the build on 443 ──► settle 90 s ──► steps 1-7
```

- The dry run goes first. If it fails nothing was installed and its output is in `esx-upgrade-<build>.log.dryrun` on the host's datastore. If it demands maintenance mode, it is retried inside it. When it fails on a hardware warning, the output names the line to add: `update_args: --no-hardware-warning`.
- `update_mode:` picks the verb. `update` is the default and only ever moves a VIB forward; pointed at an older build it finds nothing to do, reports success, and the next commissioning attempt fails identically. `install` writes the profile exactly, downward included, and is opt-in because it also removes anything the profile does not carry. The self-test checks that no verb is hardcoded anywhere in the host-side script.
- Which build the destination accepts is the destination's bill of materials, not the download portal. VCF 9.1.1 wants `9.1.1.0` build 25714478 and refuses the newer `9.1.1.0100` build 25782009 with `Host ESXi version - 9.1.1.0100.25782009 is not supported`.
- SSH is re-enabled before the reboot (`vim-cmd hostsvc/enable_ssh`): a host that comes back with SSH off is one you visit in person.
- Progress is read with the unauthenticated SOAP `RetrieveServiceContent` call on port 443, the one a vSphere client makes first, so the new build shows while the management agents are still starting. Without `curl` on the machine running this, the wait watches ssh instead.
- A `.running` stamp older than two hours counts as a dead update, not a hang. The update log has the same name under `esx_push.sh`, so each script sees the other's update in flight.

## The self-test

`esx_ready.sh` is one file that generates a payload and runs it over `ssh` on an ESXi host, which is normally untestable without a host. `sh esx_ready.sh selftest` runs the host side here: the payload is extracted from the script itself (it lives between `: <<'REMOTE_EOF'` markers, so the outer script never executes it), the template placeholders are filled with scenario values, and `esxcli`, `partedUtil`, `vdq`, `vim-cmd`, `esxcfg-vmknic`, `esxcfg-vswitch`, `net-dvs`, `vmkfstools`, `services.sh` and `openssl` are replaced by stubs on `PATH` in a temp directory, each logging its full argument list to a call log and answering from fixture files. The payload then runs under `sh` with that `PATH`.

| Helper | Asserts |
|---|---|
| `ck` | a parser returns an exact value |
| `has` | the output says something |
| `did` / `hasnt` | a command was or was not run |
| `order` | command A appears in the call log before command B |

`order` is the one that earns its keep: leave the cluster before wiping the disks, break up the disk group before `mklabel`, release the uplink before attaching it, move the vmkernel before deleting the old switch. Every one of the day's production failures was an ordering or state bug, and none of them would be caught by asserting on output. A stub that mutates state (`vsan storage remove` empties the storage list) is reset before each scenario, and a failure-injection file holding a countdown is how "refused twice, then succeeds" is tested without a real race. The count went 83 → 89 → 96 → 104 across one day, one check per outage, before each fix shipped. It is also the fastest way to tell which version you are holding: 104 checks is 1.20, 96 is 1.19, 89 is 1.18.

## ESXi's shell is not your shell

Worth knowing before editing either script. ESXi's busybox has no `tr`, so every lowercasing and line join goes through `awk`; no working `command -v`, so capability checks are `openssl version >/dev/null`; and it will not start a shell from a long ssh command line (`/bin/sh: File too large`), so the host-side script travels over stdin into `/tmp` and runs from there. Its arithmetic is 32-bit, so datastore free space in bytes overflows it silently: every byte-sized number is compared and added in `awk`. That one produces no error at all; it just picks the wrong datastore.

Learned since: `esxcli` returns before a volume finishes detaching; `esxcli software profile update` only moves VIBs forward; `esxcli network vswitch standard portgroup set` has no rename; a vSAN disk group survives leaving the cluster; `vusb0` presents as a network adapter and is counted as one (known, not yet excluded); and the SSH service policy has to be set, not just the state, or SSH is off again after a reboot. VCF disables SSH after commissioning takes a host's key, so every later batch needs it turned back on first.

## Where it sits

Every new cluster, and every day-2 host add, in this order. Each step blocks on the one before it, on purpose.

0. When the hosts are coming out of another vCenter, **`host_release.py`** ([vcf-import-prep](https://github.com/noahfarshad/vcf-import-prep)) first: evacuate, drain, vSAN disk groups out, out of the cluster, out of NSX, out of inventory. It leaves the host standalone, which is the state this repository requires; a host still in a cluster or still carrying NSX is refused here.
1. **`esx_ready.sh`**, this repository: build, hostname, vmkernels, uplinks, portgroup, disks, VMFS-6, certificate, maintenance mode. Stale NSX from a previous life comes off here too, before the host joins anything: [nsx-host-cleanup](https://github.com/noahfarshad/nsx-host-cleanup) in `--direct` mode.
2. On hardware that runs ESX 9, VCF commissions the hosts from here and the rest is VCF's. In 9.1.1 commissioning and add-to-cluster live in the vSphere Client under Global Inventory Lists, Hosts, Unassigned Hosts, from the management domain vCenter or a VCF instance with VCF SSO and vCenter linking, with the SDDC Manager UI as the documented alternative ([Commission ESX Hosts](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/building-your-private-cloud-infrastructure/host-management/commission-hosts.html)). Both are refused from a managed workload-domain vCenter. VCF Operations has no host inventory actions, no commission, decommission or add-to-cluster; it is where ESX patching lives, under Fleet Lifecycle Management, the ESX Configure Upgrade workflow, down to individual hosts. VCF Operations owns host lifecycle; the vSphere Client owns host inventory. On hardware that does not run ESX 9, the clusters are built outside VCF with **`deploy_vc.py`** ([vcf-import-prep](https://github.com/noahfarshad/vcf-import-prep)): cluster, VDS, vmkernels, NTP, vSAN, vLCM image. Its `esx` step refuses a cluster whose hosts are on mixed builds.
3. The VCF import, then the inventory sync in VCF Operations, which stalls on a host without NTP. A retried SDDC Manager task reuses cached inventory: after changing anything on a host, start a new task.
4. **`nsx_prep.py`** ([nsx-overlay-prep](https://github.com/noahfarshad/nsx-overlay-prep)): transport VLAN, TEP pool, overlay zone, host preparation. A brownfield import prepares the hosts into the VLAN transport zone only.
