# Monitoring Guidance

Rathsted Foundations does not include monitoring. This is a deliberate scope decision — the baseline stays narrow and auditable.

## What We Recommend

### Cluster Metrics
- **kube-prometheus-stack** — Prometheus + Grafana for cluster and workload metrics
- Kyverno exposes Prometheus metrics by default (the install enables `--otelConfig=prometheus`)
- k3s exposes kubelet and API server metrics on standard Kubernetes endpoints

### Log Aggregation
- **Loki + Promtail** or **Fluentd + Elasticsearch** for centralized logging
- Forward Kubernetes audit logs from `/var/lib/rancher/k3s/server/logs/audit.log`
- For tamper-evident audit retention, forward to an append-only external store

### Policy Monitoring
- Kyverno generates `PolicyReport` and `ClusterPolicyReport` resources
- Use `kubectl get policyreport -A` to check compliance status
- Consider a dashboard or alerting rule for policy violations

### Runtime Detection (Optional)
- **Falco** or **Tetragon** for syscall-level anomaly detection
- Not included in the baseline, but recommended for production deployments handling sensitive data

## Why Monitoring Is Not Included

- Adding monitoring increases the attack surface and operational complexity
- Monitoring choices are highly environment-specific (cloud vs. on-prem, existing tooling)
- The baseline prioritizes auditability over observability — different tools, different concerns
- Customers should make deliberate monitoring choices for their environment rather than inheriting opinions

## Operational Review

Production-readiness reviews should note monitoring as a deployment gap until operators have chosen a logging, metrics, and alerting stack that fits their environment.
