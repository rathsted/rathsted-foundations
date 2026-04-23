# Incident Response Guidance

This is basic guidance for responding to a suspected compromise of a Rathsted Foundations deployment. It is not a full incident response plan — scale to your organization's requirements.

## If You Suspect Node Compromise

1. **Isolate the node.** Remove network access if possible. Do not shut down yet — preserving state helps investigation.

2. **Preserve evidence before reinstalling.**
   - Copy audit logs: `cp -r /var/lib/rancher/k3s/server/logs/ /tmp/audit-preserve/`
   - Take an etcd snapshot: `k3s etcd-snapshot save --name incident-$(date +%Y%m%d-%H%M%S)`
   - Copy the snapshot off-node immediately
   - Record `kubectl get events -A` and `kubectl get pods -A -o wide`
   - Record Kyverno policy reports: `kubectl get policyreport -A -o yaml`

3. **Determine scope.**
   - Were policies bypassed? Check Kyverno admission events in audit logs
   - Were system namespaces modified? Check `kubectl get all -n kube-system`
   - Were secrets accessed? Check audit log for secret reads
   - Was the kubeconfig (`/etc/rancher/k3s/k3s.yaml`) exfiltrated?

4. **Reinstall from clean state.**
   - Provision a new VM
   - Run `./bootstrap/install.sh` from a known-good copy of the repo
   - Restore from a pre-incident etcd snapshot if appropriate
   - Run `./bootstrap/verify.sh --release` to confirm integrity

5. **Rotate credentials.**
   - Rotate the Cosign signing key
   - Rotate any Git SSH keys or tokens used for GitOps
   - Rotate any application secrets that were in the cluster

## Single-Node Blast Radius

On a single-node cluster, root compromise means full cluster compromise:
- The attacker has the kubeconfig
- All Kubernetes secrets are accessible (encryption at rest does not help when the key is on the same node)
- Kyverno policies can be modified or deleted
- Audit logs can be tampered with

This is inherent to the single-node architecture. For higher assurance:
- Forward audit logs to an external, append-only log aggregator
- Use external key management (KMS) instead of local Cosign keys
- Consider runtime detection (Falco, Tetragon) as an additional layer

## If Under a Support Agreement

Contact Rathsted with:
- When the issue was discovered
- What evidence has been preserved
- What the suspected scope is

Rathsted baseline support does not include 24/7 incident response or on-call coverage. Response will be during business hours, prioritized based on severity.

## For Self-Serve Users

Open a GitHub Issue with the `security` label if you believe there is a vulnerability in Foundations itself (not in your deployment). See `SECURITY.md` for the vulnerability reporting process.
