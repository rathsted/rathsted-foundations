# Profiles

Profiles are **optional** and off by default. The baseline ships one:

## `profiles/app-runtime`
Minimal sovereign application pattern:
- Traefik ingress/API
- NATS queue/event bus
- Postgres database
- Demo API + demo worker
- Smoke test job
- Namespace-level default-deny NetworkPolicy with same-namespace traffic and DNS egress allowed

Enable:
```bash
kubectl apply -k profiles/app-runtime
```

Before enabling in any real environment:
```bash
kubectl create secret generic postgres-secret \
  -n app-runtime \
  --from-literal=POSTGRES_PASSWORD='<strong-random-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Disable:
```bash
kubectl delete -k profiles/app-runtime
```

Policy exceptions:
- `profiles/app-runtime/policy-exception.yaml` lives in the `kyverno` namespace and exempts named app-runtime workloads from four policies: `restrict-registries`, `require-probes`, `require-readonly-rootfs`, and `require-seccomp`. Review and tighten before release. See [Policy Exceptions](policy-exceptions.md) for how exceptions work.
- `profiles/app-runtime/networkpolicy.yaml` sets default deny for the namespace while allowing same-namespace service traffic and DNS. Add explicit allow policies for any extra ingress or external egress you need before exposing real services.
