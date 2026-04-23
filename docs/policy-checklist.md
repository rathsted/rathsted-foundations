# Policy Addition Checklist

Use this checklist when adding or changing a policy.

## Authoring

- Add the policy file under `policies/`
- Use a clear policy name and rule name
- Write the failure message in plain language
- Decide whether the policy belongs in the core baseline or should stay optional
- Decide whether system namespace exclusions are needed

## Bundle

- Add the policy to `policies/kustomization.yaml`
- If the policy is optional, document that clearly instead of quietly adding it to the default bundle

## Tests

- Add or update fixtures in `tests/kyverno/kyverno-test.yaml`
- Run them with `kyverno test tests/kyverno -f kyverno-test.yaml`
- Include at least one expected pass case when practical
- Include at least one expected fail case

## Verify / Compat Evidence

- Add a bad manifest to `tests/bad-manifests/` if the policy should show up in `verify` and `compat-test`
- Add a direct named check in `bootstrap/verify.sh` if the policy is central to a release-grade trust claim

## Documentation

- Update `docs/policies.md`
- Update any related doc such as `docs/compliance-mapping.md`, `docs/supply-chain.md`, or `docs/decisions.md`
- Explain the policy in plain language, not only in YAML terms

## Final Validation

Run:

```bash
make configure
make policy-test
make verify
make compat-test
```
