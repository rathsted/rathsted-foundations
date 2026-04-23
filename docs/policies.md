# Policy Guardrails

This baseline ships Kyverno policies that enforce common secure-by-default rules. The goal is to block unsafe manifests and guide teams into predictable, reviewable patterns.

## Included Policies

- Require non‑root + drop capabilities
- Disallow privileged, hostNetwork, hostPID/IPC
- Deny hostPath volumes
- Require resource requests/limits
- Require liveness/readiness probes
- Restrict image registries to the configured customer namespace
- Require image signatures for the configured customer namespace
- Enforce namespace labels (owner, environment, jurisdiction)
- Baseline NetworkPolicy for `demo` namespace
- Default-deny NetworkPolicy for the optional `app-runtime` profile

## What These Policies Mean In Plain Language

Today the baseline rules mean:

- do not run workloads as root when safer settings are expected
- do not run privileged workloads
- do not use host-level namespace shortcuts like `hostNetwork`, `hostPID`, or `hostIPC`
- do not mount the host filesystem with `hostPath`
- do not deploy workloads without CPU and memory requests and limits
- do not deploy workloads without basic health checks
- do not pull images from unapproved registries
- do not use unsigned images where signature verification is expected
- do not create namespaces without required labels
- apply a default-deny network policy in the demo namespace
- apply a default-deny network policy in the optional app-runtime namespace

For a policy-by-policy explanation of what each one enforces, when it is useful,
and when it may be too strict, see [Policy Catalog](policy-catalog.md).

## Why This Matters

These policies are part of the reason Foundations is more than "a small Kubernetes install." They turn baseline expectations into enforced behavior that reviewers can inspect and teams can test.

## Examples

### Block privileged workloads
This should fail (Kyverno policy tests use the same fixture):
```bash
kubectl apply -f tests/kyverno/resources/bad-pod.yaml
```

### Required namespace labels
If you create a namespace without labels, it will be rejected:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

### Registry allowlist
Run `make configure` to render `policies/restrict-registries.yaml` for your image namespace. Defaults in `config/foundations.env` use `docker.io/library` with an `nginx` example image; set `RATHSTED_REGISTRY` and `RATHSTED_IMAGE` to **your** registry and workload image for production. `make configure` now rejects image references without an explicit tag or digest.

### Signature verification
Run `make configure` to render `policies/require-signed-images.yaml` for your image namespace. Then add your `cosign.pub` with `./supply-chain/cosign/update-policy.sh`.

## Testing
Run Kyverno policy tests:
```bash
make policy-test
```

Then run baseline verification:
```bash
make verify
```

If you want the policy to show up in compatibility evidence, add a matching bad
manifest to `tests/bad-manifests/` so that `verify` and `compat-test` record the
rejection explicitly.

## Adding Or Changing Policies

The short workflow is:

1. Add the policy under `policies/`
2. Include it in `policies/kustomization.yaml`
3. Add or update test fixtures in `tests/kyverno/kyverno-test.yaml`
4. Add a bad manifest in `tests/bad-manifests/` if the policy should appear in compat evidence
5. Run:

```bash
make configure
make policy-test
make verify
make compat-test
```

See [Policy Authoring and Verification](policy-authoring.md) for the full workflow.
Use [Policy Addition Checklist](policy-checklist.md) before merging a policy change.

## Optional Policy Packs Worth Considering

The current baseline is intentionally opinionated but not maximally strict. Policies
that often make sense as optional packs include:

- disallow `:latest` tags or require immutable image references
- require read-only root filesystem where practical
- restrict `NodePort` and `LoadBalancer` usage
- restrict host ports
- require NetworkPolicy coverage for every workload namespace
- require stricter ingress and TLS patterns
- require richer ownership and metadata labels
- tighten outbound egress controls for more regulated environments

## Recommended Product Direction

The cleanest model is:

- `core` policy set by default
- `hardened` policy set for teams that want a stricter starting point
- additional optional packs for more specific needs

That lets a team choose:
- start with the broad, explainable baseline
- start with a stricter posture if they already know they need it
- add narrower policy packs over time as workload complexity grows

Current state:
- Foundations ships one baseline policy set today
- the `hardened` and optional-pack model is the recommended next step, not a fully packaged feature yet

For the desired operator-facing enable/disable experience, see
[Policy Pack UX Proposal](policy-pack-ux.md).

## Why These Are Not All Default Yet

A stronger baseline is not automatically a better baseline. If the default policy set
is too strict too early, teams are more likely to disable the rules than adopt them
cleanly. The default baseline should stay:

- easy to explain
- broadly useful
- strong enough to matter
- narrow enough to stay operable

Additional hardening is often better introduced as optional policy packs and promoted
to the baseline only after repeated real-world validation.

## Namespace Exclusions
All Pod-targeting policies exclude `kube-system`, `flux-system`, and `kyverno`. These namespaces contain system components that cannot satisfy the same policy constraints as workload namespaces; excluding them is a deliberate trade-off that keeps the baseline operable without weakening enforcement for application workloads.

## Related Docs

- [Compliance Mapping](compliance-mapping.md)
- [Quickstart](quickstart.md)
- [Supply Chain](supply-chain.md)
- [Policy Authoring and Verification](policy-authoring.md)
- [Policy Addition Checklist](policy-checklist.md)
- [Policy Pack UX Proposal](policy-pack-ux.md)
- [Policy Catalog](policy-catalog.md)
