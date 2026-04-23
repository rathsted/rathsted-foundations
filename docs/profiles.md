# Profiles

Profiles are **optional** and off by default. The baseline ships one:

## `profiles/app-runtime`
Minimal sovereign application pattern:
- Traefik ingress/API
- NATS queue/event bus
- Postgres database
- Demo API + demo worker
- Smoke test job

Enable:
```bash
kubectl apply -k profiles/app-runtime
```

Disable:
```bash
kubectl delete -k profiles/app-runtime
```

Policy exceptions:
- `profiles/app-runtime/policy-exception.yaml` applies registry exceptions scoped to the `app-runtime` namespace. Review and tighten before release.
