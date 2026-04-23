# Backup and Restore

Rathsted Foundations runs on a single-node k3s cluster. Node loss means total cluster loss. Backup is the operator's responsibility.

## k3s Automatic Snapshots

k3s takes automatic etcd snapshots by default. On a running cluster:

```bash
# Verify snapshots exist
ls /var/lib/rancher/k3s/server/db/snapshots/

# Check snapshot schedule (default: every 12 hours, 5 retained)
cat /etc/rancher/k3s/config.yaml | grep -i snapshot
```

If no snapshots exist, k3s may be using SQLite instead of etcd (single-node default). Check with:

```bash
k3s check-config 2>&1 | grep -i datastore
```

## Manual Snapshot

```bash
k3s etcd-snapshot save --name manual-$(date +%Y%m%d-%H%M%S)
```

Snapshots are stored in `/var/lib/rancher/k3s/server/db/snapshots/`.

## Restore from Snapshot

```bash
# Stop k3s
systemctl stop k3s

# Restore from a specific snapshot
k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-file>

# Restart k3s
systemctl start k3s

# Verify
./bootstrap/verify.sh
```

## External Backup

For production use, copy snapshots off-node:

```bash
# Example: rsync snapshots to a remote host
rsync -az /var/lib/rancher/k3s/server/db/snapshots/ backup-host:/backups/k3s/

# Example: upload to S3-compatible storage
aws s3 sync /var/lib/rancher/k3s/server/db/snapshots/ s3://your-bucket/k3s-snapshots/
```

Schedule this with cron or systemd timer.

## What Is Backed Up

An etcd snapshot includes:
- All Kubernetes resources (deployments, services, configmaps, secrets)
- Kyverno policies and policy reports
- Flux GitRepository and Kustomization resources
- NetworkPolicies
- RBAC configuration

## What Is NOT Backed Up

- Persistent volume data (if any PVs are in use, back those up separately)
- Container images (re-pulled from registry on restore)
- Audit logs (stored on filesystem, not in etcd)
- The Git repo itself (already stored in your Git provider)

## Recommendations

- **Minimum:** Verify k3s snapshots are running. Copy them off-node daily.
- **Better:** Automate off-node snapshot sync with a cron job. Test restore quarterly.
- **For production use:** Include backup verification in regular operational review and release-readiness checks.

## Upgrade Backup

Before any upgrade, take a manual snapshot:

```bash
k3s etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d-%H%M%S)
```

See `docs/upgrade-guide.md` for the full upgrade procedure.
