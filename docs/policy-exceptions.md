# Policy Exception Guideline

Kyverno policies in `policies/` are enforced cluster-wide. When a workload genuinely cannot comply, use a `PolicyException` rather than weakening the policy.

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
  namespace: <target-namespace>
spec:
  exceptions:
    - policyName: <policy-being-exempted>
      ruleNames:
        - <specific-rule-name>
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - <target-namespace>
          selector:
            matchLabels:
              app: <specific-app>  # Always scope to specific pods
  reason: "<Why this exception is needed and what prevents compliance>"
```

## Scoping Rules

1. **Scope to specific pods** — use `selector.matchLabels` or `selector.matchExpressions`, never just a namespace
2. **Scope to specific rules** — exempt only the rule that blocks, not the entire policy
3. **One exception per concern** — don't combine unrelated exemptions
4. **Include a reason** — the `reason` field must explain why compliance isn't possible

## Example

See `profiles/app-runtime/policy-exception.yaml` — exempts `nats`, `traefik`, `postgres`, `demo-api`, and `demo-worker` from `restrict-registries` because they use `docker.io` images that can't be rebuilt under `ghcr.io`.

## Review Checklist

Before merging a PolicyException:
- [ ] Is the scope as narrow as possible? (specific pods, not whole namespace)
- [ ] Is only the minimum set of rules exempted?
- [ ] Does the `reason` field explain why the workload can't comply?
- [ ] Is there a tracking issue to remove the exception when the root cause is resolved?
- [ ] Has the exception been tested with `make policy-test`?

## System Namespace Exclusions

The baseline policies exclude `kube-system`, `flux-system`, and `kyverno` namespaces via `exclude` blocks (not PolicyExceptions). This is intentional — these system namespaces run infrastructure components that predate the policies. This decision should be reviewed before each release.
