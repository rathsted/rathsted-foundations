# Operator-control components

`policies/require-namespace-labels.yaml` stamps `rathsted.io/operator-control`
on every governed namespace. The tracked literal is `foreign-provider`. Flux
reconciles `policies/` from your GitOps source (`cluster/gitops/apps`), so a
value set only at install time is reverted at the first reconcile. To make a
different value durable, carry it in Git: enable one of the kustomize
Components in `components/operator-control/` in your fork.

| Component | Stamps |
|---|---|
| `components/operator-control/customer` | `customer` |
| `components/operator-control/domestic-provider` | `domestic-provider` |
| `components/operator-control/foreign-provider` | `foreign-provider` |
| `components/operator-control/rathsted` | `rathsted` |

Each one patches the stamp rule's literal and nothing else. The patch first
tests that rule 0 of the policy is `stamp-operator-control`, so if the rules
are ever reordered the build fails instead of patching the wrong rule.

## Enable one in your fork

1. Add the component to `cluster/gitops/apps/kustomization.yaml`, at the top
   level of the file:

   ```yaml
   components:
     - ../../../components/operator-control/customer
   ```

   If the file already has a `components:` key, add the entry to that list.
   Do not add a second `components:` key: kustomize keeps only the last one,
   and the installer refuses a file with a duplicate key.

2. Commit and push to the branch or tag Flux follows.
3. Install with the same value:

   ```bash
   RATHSTED_OPERATOR_CONTROL=customer ./bootstrap/install.sh
   ```

   If you skip the variable, the installer refuses before changing anything:
   it would otherwise seed the policies and label the platform namespaces
   with the policy's literal, and Flux would then stamp the component's
   value, which `verify.sh` reports as a mismatch. It reads only your
   checkout (HEAD) for this, without the network.

Enable exactly one operator-control component. The installer refuses two, a
value outside the four above, a path in any other form than the one shown, or
a component that does not stamp the value its directory names.

## How the installer checks it

With `RATHSTED_OPERATOR_CONTROL` set on a path that bootstraps GitOps, the
installer reads `cluster/gitops/apps/kustomization.yaml` at the commit Flux
will apply (resolved with `git ls-remote`, read from your clone with
`git show`; no `kubectl` or `kustomize` needed). With one component listed,
the value that component stamps must equal the declaration. With none, the
literal in `policies/require-namespace-labels.yaml` at that commit must. Any
mismatch, or anything the installer cannot read, refuses before anything is
applied.

Because it reads the file as text, it also refuses anything that could make
kustomize apply something else: a top-level key that appears twice, a second
YAML document (`---` after the first content line), a top-level key other
than `apiVersion`, `kind`, `resources`, `components` and `images` (so no
`patches`, `patchesJson6902`, `patchesStrategicMerge`, `replacements`,
`transformers` or `generators`), any entry under `components:` other than
the one operator-control entry (another component would apply its own
patches, before or after it), a component file that differs from the one
Foundations ships for that value other than in comment lines, and a
`policies/kustomization.yaml` with any top-level key other than
`apiVersion`, `kind` and `resources` (each once, in one document).

Not seen by that check: an entry under `resources:`, in
`cluster/gitops/apps/kustomization.yaml` or in `policies/kustomization.yaml`,
that is itself a kustomization or overlay patching the stamp, or a manifest
that sets the label another way (for example a second policy mutating
`rathsted.io/operator-control`). Use these components, or commit the literal.
`./bootstrap/verify.sh` is the backstop: it compares the live stamp with the
declaration either way.
