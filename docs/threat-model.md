# Threat Model (Lightweight)

This is a lightweight statement of what Foundations is meant to reduce risk around, and what remains outside the baseline.

**Assets**
- Cluster state and workloads
- Build artifacts and container images
- Supply chain metadata (SBOMs, signatures)

**Primary threats**
- Unauthorized image or manifest changes
- Privileged workloads and unsafe runtime settings
- Tampering in the build/publish pipeline
- External dependency drift

**Current mitigations**
- GitOps as a change gate
- Kyverno policies to enforce baseline security
- Cosign signatures for image verification
- SBOM generation for transparency

**Not yet addressed**
- Runtime sandboxing beyond baseline K8s defaults
- Zero‑trust network segmentation
- Full compliance controls

## Related Docs

- [Policies](policies.md)
- [Compliance Mapping](compliance-mapping.md)
- [Jurisdiction Control Matrix](jurisdiction-control-matrix.md)
