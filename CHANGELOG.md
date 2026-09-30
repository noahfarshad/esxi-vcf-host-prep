# Changelog

All notable changes to this project are documented here.

## [1.0.0] — 2026-09-30

### Added

- Initial public release. esx_ready.sh plans by default and leaves a host alone if it is already in a cluster, already in a vCenter, or waiting on a reboot. esx_push.sh lists, copies an offline bundle, and upgrades. A VMFS wipe requires apply and an explicit flag.

### Notes

- All customer-specific identifiers have been replaced with generic example values.
- Configuration files use placeholder credentials (ChangeMe!) that must be replaced with your own before use.
- Hostnames follow the *.example.com pattern and IP addresses use the RFC 5737 documentation range (192.0.2.0/24).
