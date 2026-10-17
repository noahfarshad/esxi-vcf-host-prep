# Changelog

All notable changes to this project are documented here.

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
