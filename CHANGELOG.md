# Changelog

All notable changes to this project are documented here.

## [1.2.0] — 2026-10-23

`esx_ready.sh` 1.12 → 1.20, nine versions in one day on a live fleet. Every production failure became a self-test check before its fix shipped.

### Added

- `selftest`: 104 checks against a stubbed host, no network, no dependencies. The host-side payload is extracted from the script, `esxcli`, `partedUtil`, `vdq` and the rest are replaced by stubs that log their arguments and answer from fixtures, and the assertions check parsers, output, which commands ran, and in what order.
- `update_mode: install`. `esxcli software profile update` only ever moves a VIB forward: pointed at an older build it reports success and the host stays where it is. `install` writes the profile exactly, which is the only way down.
- `--clear-datastores`: remove a local VMFS datastore and clear the disk under it so vSAN can claim it. `--wipe-disks` implies it. Never a datastore other hosts can see, one spanning several extents, one with registered VMs, one on the boot device, or one holding this host's scratch or an active core dump.
- `min_uplinks:` (default 2): the host must have that many adapters reporting Link Up, because the add to a cluster maps its pnics to the cluster's distributed switch and commissioning does not check it.
- `--restore-vswitch`, with `mgmt_vlan:` and `mgmt_uplink:`: move the management vmkernel off a distributed switch a vCenter left behind onto a standard switch, keeping its address. Opt-in, refuses rather than guess the VLAN or the uplink, puts the uplink back and stops if the standard switch does not come up with one, and writes what it did to `/var/log/esx_ready-restore.log` on the host.
- `ssh:` key: the ssh client to use when PATH has none.
- `datastore: auto` ranks local storage: the boot device first, then disks vSAN would not claim, and only then one it would. Before this the largest datastore with room was the vSAN cache disk, and the tool staged the depot onto it and reported `ready`.
- The bundle-not-found message names the depot zips that are in the directory, so a near-miss filename is not read as a missing download.

### Changed

- vSAN cluster leave now happens before the disk loop, not after it. While a host is a cluster member vSAN owns its disks and `partedUtil` is refused on every one.
- Disk groups survive leaving the cluster, and a host that was never in one can still carry them. They are now broken up by their cache device, `esxcli vsan storage remove -s <cache> -m noAction`, before any wipe; `-m noAction` because out of a cluster the default evacuation policy cannot be met and the removal is refused.
- `partedUtil mklabel` is retried three times. `esxcli` returns before a volume has finished detaching, and the first attempt is refused on a disk that is free a moment later.
- Datastores are cleared per device, not per datastore: a disk carrying a datastore and a stale OSDATA volume gets two unmounts, a wait for both to detach, and one `mklabel`.
- A core dump file blocks a datastore only when it is `Active` or `Configured`. A leftover file from a previous install is not a reason to keep a disk.
- The final table repeats the bundle problem when every host failed for it, since the banner that said so has scrolled away.

### Removed

- The management portgroup rename. `esxcli network vswitch standard portgroup set` takes a VLAN id and nothing else; the only way to change the name is to add a new portgroup and move `vmk0` onto it, which drops the connection the run is on. Nothing in commissioning or the cluster build reads the name, so a portgroup under another name is reported and left alone.

### Notes

- `esx_prep.sh` 3.0 and `esx_push.sh` are unchanged.
- The self-test's fixture names, addresses and device ids are placeholders.

## [1.1.0] — 2026-10-17

### Added

- `esx_prep.sh` 3.0: the seven commissioning steps on hosts already on the target build, with no upgrade phase. Dry run by default, `--apply` to change, `--wipe-disks` only with it; `LOGDIR` and `PARALLEL`. A host that is not on `build:` is refused, with the reason.
- `hosts.example.yaml`: the one file all three scripts read, every key documented, including the `{short}` datastore templating and the `update_args` line the dry run asks for.
- README: which script to use, the keys and what `esx_ready.sh` refuses, the states a host ends in, the refusals, the upgrade flow, the ESXi shell quirks, and where this sits before `deploy_vc.py`, the import and `nsx_prep.py`.
- `.gitignore` keeps a fleet file, the staged bundle and the run logs out of the repository.

### Notes

- `esx_ready.sh` is unchanged at 1.12, and `esx_push.sh` is unchanged.
- `esx_ready.sh` takes exactly nine keys and treats any other as an error. The keys only `esx_push.sh` and `esx_prep.sh` read (`user`, `ssh`, `mgmt_vmk`, `mgmt_portgroup`) belong in a file run with `-f` against those scripts.
- Every name and address in the example is a placeholder.

## [1.0.0] — 2026-09-30

### Added

- Initial public release. esx_ready.sh plans by default and leaves a host alone if it is already in a cluster, already in a vCenter, or waiting on a reboot. esx_push.sh lists, copies an offline bundle, and upgrades. A VMFS wipe requires apply and an explicit flag.

### Notes

- All customer-specific identifiers have been replaced with generic example values.
- Configuration files use placeholder credentials (ChangeMe!) that must be replaced with your own before use.
- Hostnames follow the *.example.com pattern and IP addresses use the RFC 5737 documentation range (192.0.2.0/24).
