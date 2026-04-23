# Credential Lifecycle

How credentials are generated, stored, rotated, and revoked in Rathsted Foundations.

## Credentials Inventory

| Credential | Purpose | Storage | Rotation |
|---|---|---|---|
| Cosign private key | Image signing | Private repo (encrypted) or KMS | On incident or per policy |
| Cosign passphrase | Protects cosign private key | Operator-managed / CI | With key rotation |
| RATHSTED_GIT_SSH_KEY | Flux GitRepository SSH auth | Env var / K8s object | On incident or per policy |
| RATHSTED_GIT_TOKEN | Flux GitRepository HTTPS auth | Env var / K8s object | On incident or per policy |
| CI signing credentials | Image signing in GitHub Actions | GitHub Actions store | With key rotation |

## Generation

- **Cosign keys:** `cosign generate-key-pair` (see `supply-chain/cosign/README.md`)
- **SSH keys:** `ssh-keygen -t ed25519`
- **Git tokens:** GitHub Settings, Developer settings, Personal access tokens

## Storage Rules

**Never store credentials in:** public repositories, unencrypted files, logs, error messages, or audit output.

**Acceptable locations:** GitHub Actions credential store, environment variables on the target host, Kubernetes objects where operator policy allows them, and cloud KMS/HSM for signing keys.

## Rotation

### When to rotate

- **Immediately:** After any suspected compromise, CI breach, or unauthorized access
- **Periodically:** Per your organization's policy (recommended: annually for signing keys, more frequently for Git and CI credentials if required)
- **On personnel change:** When someone with credential access leaves the team

### How to rotate

**Cosign keys:**
1. Generate new keypair: `cosign generate-key-pair`
2. Replace `cosign.pub` in this repo
3. Run `./supply-chain/cosign/update-policy.sh`
4. Update CI credentials
5. Re-sign any images that must remain verifiable

**Git auth:**
1. Generate new SSH key or token
2. Update the K8s object in flux-system namespace
3. Reconcile: `flux reconcile source git rathsted-foundations`

## Revocation

- **Cosign keys:** Replace the public key in the policy and re-sign images. Old signatures become unverifiable.
- **Git tokens:** Revoke via GitHub Settings. Flux will fail to pull until a new token is provided.
- **CI credentials:** Update via GitHub repository settings.

## Audit

- GitHub Actions logs show which credentials were used per workflow run
- Kubernetes audit logs (enabled by install.sh) record access to sensitive objects
