# ESXi hosts, ready to commission

Two POSIX shell scripts. One copies an offline bundle and upgrades. The other gets a standalone host to the bar VCF 9.1 commissioning actually checks.

Commissioning is not an upgrade. VCF rejects a host that is already in a cluster, already in a vCenter, still in maintenance mode, or whose hostname is not the FQDN. See [Commission ESX Hosts](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-1/building-your-private-cloud-infrastructure/host-management/commission-hosts.html).

## Run

`esx_ready.sh` defaults to plan. Apply is a different word. A host already in a cluster, already managed, or waiting on a reboot is left alone. If the management vmkernel is on a distributed switch, the script says so and does not touch the host.

Disk destruction is not implied. Recreating VMFS-5 as VMFS-6 wipes the volume, so that path requires apply and an explicit wipe flag. Plan with the wipe flag is rejected.

`esx_push.sh` list shows how the host file was read and changes nothing. Upgrade of one host does a dry run, then starts the update.

Do not point either script at a host that is already in a workload domain.
