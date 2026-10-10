# Jurisdiction Control Matrix

This guide helps you answer a practical question:

"If we run Rathsted Foundations for our business or for our customers, which parts of the operating model matter for local jurisdiction, customer trust, and future supportability?"

For a company in Canada, the Nordics, or any other place with customer, procurement, or regulatory expectations, the point is not to use the word "sovereign" loosely. The point is to identify which parts of the stack you control, which parts depend on third parties, and which parts need an explicit business decision.

Rathsted Foundations does not make a cloud or hosting provider sovereign by itself. It provides the groundwork for a more controlled deployment inside an environment that fits your sovereignty requirements.

## What "Sovereign" Means Here

In the context of Rathsted Foundations, sovereign means:

- the infrastructure is owned or directly controlled by you or your customer
- the control points in the delivery chain are visible and documentable
- you can state where code, artifacts, keys, and evidence live
- you can explain which external dependencies exist and why they are acceptable

It does not mean:

- automatic legal compliance
- no external dependency of any kind
- a claim that one country or hosting choice is always acceptable for every customer

## The Business Question To Ask

For each deployment, ask:

1. Where is the cluster running?
2. Who owns the git repository that defines the system?
3. Where do CI jobs run?
4. Where are images stored?
5. Who controls the signing keys?
6. Where do SBOMs, verification logs, and release evidence get retained?
7. Are those answers acceptable for this customer, contract, or operating region?

If any answer is unknown, your sovereignty posture is not yet clear enough.

## Control Matrix

| Control point | Why it matters | Questions to answer | Typical actions |
|---------------|----------------|---------------------|-----------------|
| Cluster location | Determines where runtime control and data-plane operations happen | Which country or site hosts the cluster? Who owns the infrastructure? | Use customer-owned infrastructure or an approved in-jurisdiction host |
| Git hosting | Determines who controls desired state and where repo metadata lives | Is the repo in your org, the customer's org, or a third-party vendor org? In which jurisdiction? | Prefer customer-controlled or contract-approved git hosting for stricter environments |
| CI runners | CI can introduce jurisdictional and custody exposure | Are runners hosted or self-hosted? Where do they run? Who administers them? | Use self-hosted runners in an approved region when hosted CI is not acceptable |
| Artifact registry | Images and logs may carry residency and retention implications | Where is the registry? Who controls retention and audit logs? | Replace default example registries with an approved private registry when needed |
| Signing keys | Key custody affects release trust and incident handling | Are keys in developer laptops, a secret manager, KMS, or HSM? Who can use them? | Move keys to customer-controlled KMS/HSM or approved secret storage |
| Evidence retention | Auditability depends on durable evidence storage | Where are SBOMs, verification logs, and release records retained? For how long? | Store evidence in a controlled, documented location with a defined retention policy |

## What Rathsted Foundations Gives You

Foundations gives you:

- a cluster baseline you can run on infrastructure you control
- GitOps and policy controls that make change visible and reviewable
- signing and SBOM workflows you can adapt to your approved registry and key custody model
- docs that make these control points explicit instead of burying them

## What Rathsted Foundations Does Not Decide For You

Foundations does not decide:

- whether GitHub is acceptable for your customer or market
- whether a public cloud registry is acceptable for your jurisdiction
- whether hosted CI is acceptable for your contract terms
- whether your legal or procurement team considers a given operating model compliant

Those are business and governance decisions. Foundations is meant to make them visible early.

## Example: Canadian Business With Its Own Data Center

Suppose you are a business owner in Canada with your own data center and you need a stack you can rely on in a Canadian operating context.

Rathsted Foundations can help if you want:

- a Kubernetes baseline running on infrastructure you control
- a documented way to manage cluster state through Git
- policy guardrails and signed-image workflows you can review
- a clearer story for customers who ask where the important control points live

Rathsted Foundations does not by itself guarantee:

- that every supporting tool already runs in Canada
- that your CI, registry, or key storage choices automatically satisfy every customer
- that the full surrounding platform, including secrets, backup, and observability, is already solved by this release
- that the hosting model itself becomes sovereign just because Foundations is installed

In practical terms, the right question is not "Is Rathsted sovereign in the abstract?"

The right question is:

"Can we use Rathsted Foundations as the baseline, then choose repo hosting, CI, registry, key custody, and evidence retention in a way that fits our Canadian business and our customer obligations?"

That is the level at which the product is designed to be useful.

The same reasoning applies in Nordic and other jurisdiction-sensitive environments: the useful question is not whether the word "sovereign" appears on the site, but whether the full operating model fits the customer, contract, and region you actually serve.

## Suggested Review Before Adoption

Before treating a deployment as acceptable, document:

1. Cluster host and ownership
2. Git hosting location and owner
3. CI runner location and operator
4. Artifact registry location and retention policy
5. Signing key custody and rotation policy
6. Evidence retention location and retention period
7. Any known external dependencies that fall outside the preferred jurisdiction

Then review that matrix with the people who actually carry the business risk: operations, security, procurement, legal, or the customer.

## Related Docs

- [Overview](overview.md)
- [Quickstart](quickstart.md)
- [Pipeline Sovereignty](pipeline-sovereignty.md)
- [Registry Residency Guide](registry-residency-guide.md)
- [Release Signing](release-signing.md)
