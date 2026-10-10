# Backup and Restore

Rathsted Foundations runs on a single-node k3s cluster. Node loss means total cluster loss. Backup is the operator's responsibility.

## Datastore

The shipped k3s configuration (`cluster/k3s/config.yaml`) does not set `cluster-init`, so k3s uses its default single-node datastore: **SQLite**, not etcd. k3s's automatic etcd snapshots and `k3s etcd-snapshot` do not apply to this install.

Secrets encryption at rest is enabled (`secrets-encryption: true`). A backup is only restorable together with the encryption key that k3s keeps under `/var/lib/rancher/k3s/server/cred/`; back up the whole server directory, not the database alone.

## Back Up

Stop k3s so the SQLite files are consistent, copy the server directory, and start it again:

```bash
sudo systemctl stop k3s
sudo tar -czf "k3s-server-$(date +%Y%m%d-%H%M%S).tar.gz" -C /var/lib/rancher/k3s server
sudo systemctl start k3s
```

The archive contains the datastore (`server/db/`), the server token, TLS material and the encryption configuration. **Treat it as a secret**: anyone holding it can decrypt the cluster's Secrets.

## Restore

Restore onto a host running the **same k3s version** (see `docs/versions.md`):

```bash
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server
sudo tar -xzf k3s-server-<timestamp>.tar.gz -C /var/lib/rancher/k3s
sudo systemctl start k3s
./bootstrap/verify.sh
```

## External Backup

Copy archives off-node; a backup on the node itself is lost with the node:

```bash
rsync -az k3s-server-*.tar.gz backup-host:/backups/k3s/
```

Encrypt the archive in transit and at rest at the destination. Schedule the backup with cron or a systemd timer, and stop k3s only in a maintenance window.

## If You Enable Embedded etcd

If you change the k3s configuration to use embedded etcd (`cluster-init: true`), k3s takes automatic etcd snapshots (default every 12 hours, 5 retained) under `/var/lib/rancher/k3s/server/db/snapshots/`, and you can use `k3s etcd-snapshot save` and `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`. The encryption key still has to be backed up separately. This is not the shipped configuration and is not covered by the compatibility evidence.

## What Is Backed Up

The server directory includes:
- All Kubernetes resources (deployments, services, configmaps, secrets)
- Kyverno policies and policy reports
- Flux GitRepository and Kustomization resources
- NetworkPolicies
- RBAC configuration
- The token, TLS material and secrets-encryption key needed to use the above
- Audit logs (`server/logs/`); exclude them from the archive if you ship audit logs elsewhere

## What Is NOT Backed Up

- Persistent volume data (if any PVs are in use, back those up separately)
- Container images (re-pulled from registry on restore)
- The Git repo itself (already stored in your Git provider)

## Recommendations

- **Minimum:** Back up the server directory daily and copy it off-node.
- **Better:** Automate the backup and off-node copy. Test a restore quarterly.
- **For production use:** Include backup verification in regular operational review and release-readiness checks.

## Before Reinstalling or Upgrading

In-place upgrades are not supported in 2.0.x; moving to a new version means reinstalling (`docs/upgrade-guide.md`). Take a backup first. A backup restores the cluster at the k3s version it was taken from; it does not migrate state into a new version.
