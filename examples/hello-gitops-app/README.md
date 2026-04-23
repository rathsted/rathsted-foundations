# Hello GitOps App

Example workload used to demonstrate GitOps deployment, policy enforcement, and supply-chain verification in Rathsted Foundations.

The default image is `nginx:1.29.7-alpine` from Docker Hub. For production, replace it with your own image using `make configure` or the Kustomize overlay below.

## Using your own image

Replace the image in `deployment.yaml`, or use the Kustomize overlay to avoid editing base manifests:

```yaml
# examples/hello-gitops-app/overlays/local/kustomization.yaml
images:
  - name: nginx
    newName: registry.example.com/your-app
    newTag: 1.0.0
```

After swapping in your image, sign it and register the public key with the signature policy:

```bash
export IMAGE=registry.example.com/your-app:1.0.0

cosign generate-key-pair
mv cosign.pub ../../supply-chain/cosign/cosign.pub
mv cosign.key ../../supply-chain/cosign/cosign.key
../../supply-chain/cosign/update-policy.sh

make sign IMAGE="$IMAGE"
make sbom IMAGE="$IMAGE"
```

Then run `make verify-release` to confirm the full supply-chain check passes against your image.
