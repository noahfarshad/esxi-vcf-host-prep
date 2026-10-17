# ESXi hosts, ready to commission

Three shell scripts that read one `hosts.yaml` and take standalone ESXi hosts from racked and pingable to the state VCF 9.1 host commissioning accepts: the right build, the hostname, one vmkernel, one uplink, one portgroup, clean disks, VMFS-6, a certificate that names the host, and out of maintenance mode. Plan by default. A host that is already in a cluster, managed by a vCenter or waiting on a reboot is left alone.

License: GPL-3.0. Built and proved out for [essential.coach](https://essential.coach).
Full write-up: [Sixteen Hosts, Seven Requirements, One Command: Getting ESXi Hosts Ready for VCF Commissioning](https://essential.coach/esxi-hosts-ready-for-vcf-commissioning/)

## What commissioning checks

VCF addresses a host by name, connects by name, and refuses anything that looks like a previous life ([Commission ESX Hosts](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/building-your-private-cloud-infrastructure/host-management/commission-hosts.html)). A host fails the wizard if any one of these is wrong, and the wizard names one host at a time:

| # | Requirement | Step |
|---|---|---|
| 1 | Hostname is the FQDN | `hostname` |
| 2 | Exactly one vmkernel adapter, `vmk0` | `vmkernels` |
| 3 | One uplink on the management vSwitch | `uplinks` |
| 4 | One portgroup, named `Management Network` | `portgroups` |
| 5 | No stale vSAN partitions on the data disks | `disks` |
| 6 | Certificate names the FQDN | `certificate` |
| 7 | Not in maintenance mode | `maintenance` |

Plus VMFS-6 on the local datastores (`vmfs6`), and the right build before any of it matters (`upgrade`).

## Which script

| Script | Version | Shell | Upgrades | Preps | |
|---|---|---|---|---|---|
| `esx_ready.sh` | 1.12 | POSIX sh | yes | yes | **Use this one.** Both phases in one pass, waits out the reboots, resumable |
| `esx_prep.sh` | 3.0 | bash | no | yes | The seven steps only. Refuses a host that is not already on `build:` |
| `esx_push.sh` | | POSIX sh | yes | no | The original: stage the bundle and upgrade |

`esx_ready.sh` has no dependencies and runs from a jump box or from one of the hosts in the list. On a host, that host puts itself last, and the script opens the `sshClient` firewall ruleset if it has to and closes it again on the way out. One SSH login per host per run; the connections after it reuse the first. With `sshpass` installed the root password comes from `ESXPW`; otherwise ssh prompts.

`esx_prep.sh` is for a fleet already on the right build when only the prep steps are wanted. It dry-runs by default, `--apply` changes things, and `LOGDIR` (default `./prep-logs`) and `PARALLEL` are environment variables.

## hosts.yaml

One file, read by all three. `hosts.example.yaml` documents every key. `esx_ready.sh` takes exactly these nine and treats any other key as a hard error that prints the list, because a mistyped key silently doing nothing is worse than a stop:

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
| `update_args` | no | extra flags for `esxcli software profile update`. The dry run tells you when you need one |

`datastore:` takes a name, where `{short}` is the host without its domain and `{host}` is the entry as written, so `"{short}_ds1"` covers sixteen hosts with sixteen datastore names in one line; a full path such as `/vmfs/volumes/datastore1`; or `auto`, the largest local datastore with room. Shared VMFS is never used for staging: two hosts staging to one volume interleave their update logs and neither is readable afterwards.

An IP address entry needs `fqdn:` under it; nothing can guess it. `esx_push.sh` and `esx_prep.sh` also read `user:` and `ssh:`, and `esx_prep.sh` reads `mgmt_vmk:` and `mgmt_portgroup:`. `esx_ready.sh` refuses those four, so a file that carries them is run with `-f` against the script that understands it.

Built in, not configurable: `SSHUSER=root`, `MGMT=vmk0`, `WANTPG="Management Network"`, and the timings (`PROBE=8`, `POLL=20`, `SETTLE=90`, `WAIT_TIMEOUT=3600`, `AGENTWAIT=180`, `STALE=7200`). They are VCF's requirements and hard-won waits, not site preferences.

## Run

```sh
read -rs ESXPW && export ESXPW          # the root password never reaches shell history
sh esx_ready.sh list                    # how hosts.yaml was read; connects to nothing
sh esx_ready.sh plan                    # what would change on every host (the default)
sh esx_ready.sh apply                   # do it, and wait out the reboots
sh esx_ready.sh apply --wipe-disks      # also clear stale vSAN partitions and recreate VMFS-5 as VMFS-6
sh esx_ready.sh plan esx05 esx06        # a subset, by short name or as written
sh esx_ready.sh apply -f other-fleet.yaml
unset ESXPW
```

`--wipe-disks` goes only with `apply`; with `plan` it is rejected, because plan already lists which disks need it and why. `bundle:` without `build:` is rejected.

Every run ends with one table, and each host reads one of these:

| State | Meaning |
|---|---|
| `ready` | commissionable now; `did:` lists what changed |
| `to do: …` | changes pending, which `plan` listed |
| `upgrade` | needs the build change, then whatever follows it |
| `upgrade in progress` | the update is running on the host; `apply` again to finish it |
| `rebooting` | waiting for it to come back |
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

The whole host is left alone when the management vmkernel is on a distributed switch (that host is in a cluster, whatever the ticket says), when `managementServerIp` is set (a vCenter manages it; remove it there first), or when a reboot is pending that no upgrade of ours explains.

Within a host: the management vmkernel is never removed or reconfigured; only the extras go. The uplink kept is one reporting Link Up, and if none does, uplinks are not touched: better two than none. The boot device is never wiped, and neither is a disk holding a VMFS datastore, both checked against the live device list, not inferred. Only ESXi's own self-signed certificate is regenerated; a CA-issued one is reported and left alone. The old pair is kept as `rui.*.<timestamp>.bak` and put back if generation fails, `auto-backup.sh` runs so the new one survives a reboot, and the management agents are restarted only when port 443 has to pick it up. VMFS-5 is recreated as VMFS-6 only when the datastore is local, single-extent and has no registered VMs: unmount, `vmkfstools -C vmfs6`, verify, and remount the old one if it failed. The partition table is never edited.

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
- SSH is re-enabled before the reboot (`vim-cmd hostsvc/enable_ssh`): a host that comes back with SSH off is one you visit in person.
- Progress is read with the unauthenticated SOAP `RetrieveServiceContent` call on port 443, the one a vSphere client makes first, so the new build shows while the management agents are still starting. Without `curl` on the machine running this, the wait watches ssh instead.
- A `.running` stamp older than two hours counts as a dead update, not a hang. The update log has the same name under `esx_push.sh`, so each script sees the other's update in flight.

## ESXi's shell is not your shell

Worth knowing before editing either script. ESXi's busybox has no `tr`, so every lowercasing and line join goes through `awk`; no working `command -v`, so capability checks are `openssl version >/dev/null`; and it will not start a shell from a long ssh command line (`/bin/sh: File too large`), so the host-side script travels over stdin into `/tmp` and runs from there. Its arithmetic is 32-bit, so datastore free space in bytes overflows it silently: every byte-sized number is compared and added in `awk`. That one produces no error at all; it just picks the wrong datastore.

## Where it sits

Every new cluster, and every day-2 host add, in this order. Each step blocks on the one before it, on purpose.

1. **`esx_ready.sh`**, this repository: build, hostname, vmkernels, uplinks, portgroup, disks, VMFS-6, certificate, maintenance mode. Stale NSX from a previous life comes off here too, before the host joins anything: [nsx-host-cleanup](https://github.com/noahfarshad/nsx-host-cleanup) in `--direct` mode.
2. On hardware that runs ESX 9, VCF commissions the hosts from here and the rest is VCF's. On hardware that does not, the clusters are built outside VCF with **`deploy_vc.py`** ([vcf-import-prep](https://github.com/noahfarshad/vcf-import-prep)): cluster, VDS, vmkernels, NTP, vSAN, vLCM image. Its `esx` step refuses a cluster whose hosts are on mixed builds.
3. The VCF import, then the inventory sync in VCF Operations, which stalls on a host without NTP.
4. **`nsx_prep.py`** ([nsx-overlay-prep](https://github.com/noahfarshad/nsx-overlay-prep)): transport VLAN, TEP pool, transport node profile, host preparation. A brownfield import prepares the hosts into the VLAN transport zone only.
