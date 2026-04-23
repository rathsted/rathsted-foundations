# Public Trust Statement

`rathsted-foundations` is intended to be the public, reviewable source of truth for the published Foundations baseline.

## What You Should Be Able To Verify From The Public Repo

- what the baseline installs
- which policies are enforced
- which versions are pinned
- how bootstrap and verification work
- what is in scope and out of scope for the release
- how supply-chain and release verification are expected to work

You should not need access to private files, private services, or unpublished context to evaluate the public baseline.

## What This Means

- Public manifests and docs should stand on their own.
- Public examples should not rely on hidden private components.
- Public security and compliance claims should be supportable from public files alone.
- The public repo is the artifact that external reviewers, customers, and operators are expected to inspect.

## What This Repo Does Not Claim

- It does not guarantee certification or legal compliance by itself.
- It does not remove the need for operator decisions around hosting, secrets, access, backups, and incident response.
- It does not claim controls that only exist in private tooling or unpublished workflows.

## Release Assurance Model

Rathsted generates the public repository through a controlled internal publish workflow. The important requirement is not that the internal workflow be trusted blindly, but that the resulting public repository remain:

- self-contained
- reproducible from its published contents
- auditable by an external reviewer
- consistent with its own documentation

If the public repo cannot support a claim by inspection and verification, that claim should not be made.
