# Policy Exception Guideline

Kyverno policies in `policies/` are enforced cluster-wide. When a workload genuinely cannot comply, use a `PolicyException` rather than weakening the policy.

PolicyExceptions are enabled in this baseline. Kyverno runs with `--enablePolicyException=true --exceptionNamespace=kyverno`, so only `PolicyException` objects placed in the **`kyverno` namespace** take effect. An exception in any other namespace is silently ignored, so tenants cannot exempt their own workloads.

## When Exceptions Are Allowed

An exception is justified when:
- A third-party image cannot be rebuilt (e.g., `docker.io/nats`, `docker.io/library/traefik`)
- A system component requires capabilities the policy restricts
- The exception is scoped to the minimum necessary resources

An exception is **not** justified when:
- The workload could be rebuilt to comply
- The exception is a convenience shortcut
- The scope is broader than needed (e.g., entire namespace instead of specific pods)

## How to Write an Exception

```yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: <descriptive-name>
  namespace: kyverno           # exceptions must be in the kyverno namespace
  annotations:
    rathsted.io/reason: "<Why this exception is needed and what prevents compliance>"
spec:
  exceptions:
    - policyName: <policy-being-exempted>
      ruleNames:
        - <specific-rule-name>
        - autogen-<specific-rule-name>  # include autogen rules when applicable
  match:
    any:
      - resources:
          kinds:
            - Pod
            - Deployment   # include relevant workload kinds
          namespaces:
            - <workload-namespace>  # match workloads in their actual namespace
          names:
            - <specific-app>*  # Always scope to specific workload names
```

PolicyException has no `spec.reason` field; record the reason in the
`rathsted.io/reason` annotation, as the app-runtime exception does.

## Scoping Rules

1. **Place exceptions in the `kyverno` namespace** — only exceptions in `kyverno` are honored. Exceptions in workload namespaces are silently ignored.
2. **Scope to specific workload names** — use `names` with a prefix pattern, not just a namespace selector
3. **Scope to specific rules** — exempt only the rule that blocks, not the entire policy; include `autogen-*` variants when policies cover higher-level resources (Deployment, StatefulSet, etc.)
4. **One exception per concern** — don't combine unrelated exemptions
5. **Include a reason** — the `reason` annotation must explain why compliance isn't possible

## Example: app-runtime Profile

See `profiles/app-runtime/policy-exception.yaml` — this exception lives in the `kyverno` namespace and exempts named workloads in the `app-runtime` namespace from four policies:

- **`restrict-registries`** — these workloads use `docker.io` images (`nats`, `traefik`, `postgres`) that cannot be rebuilt under `ghcr.io`
- **`require-probes`** — some components do not expose a standard HTTP health endpoint
- **`require-readonly-rootfs`** — Postgres requires a writable filesystem for data files
- **`require-seccomp`** — these upstream images do not ship a seccomp profile annotation

## Review Checklist

Before merging a PolicyException:
- [ ] Is the exception placed in the `kyverno` namespace?
- [ ] Is the scope as narrow as possible? (specific workload names, not whole namespace)
- [ ] Is only the minimum set of rules exempted?
- [ ] Are `autogen-*` rule variants included where needed?
- [ ] Does the `reason` annotation explain why the workload can't comply?
- [ ] Is there a tracking issue to remove the exception when the root cause is resolved?
- [ ] Has the exception been tested with `make policy-test`?

## System Namespace Exclusions

System namespaces are excluded by policy configuration, not PolicyExceptions:

- Eleven of the thirteen policies exclude `kube-system`, `flux-system` and `kyverno` with `exclude` blocks.
- `baseline-networkpolicy` does not generate its default-deny NetworkPolicy in `kube-system`, `kube-public`, `kube-node-lease`, `flux-system`, `kyverno` or `default`.
- `require-namespace-labels` has no `exclude` block; Kyverno's built-in resource filters skip `kube-system` and `kyverno`.

This is intentional — these namespaces run infrastructure components that predate the policies. Review it before each release.
