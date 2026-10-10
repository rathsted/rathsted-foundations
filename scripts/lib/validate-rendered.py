#!/usr/bin/env python3
"""validate-rendered.py — structurally validate rendered config/rendered/ files.

Usage:
    python3 validate-rendered.py <rendered_dir> <registry> <image>

Exits 0 and prints OK lines on success.
Exits 1 and prints error lines to stderr on any structural failure.

Checks:
  restrict-registries.yaml
    - parses as valid YAML
    - is a Kyverno ClusterPolicy
    - anyPattern contains at least one entry matching <registry>/*

  require-signed-images.yaml
    - parses as valid YAML
    - is a Kyverno ClusterPolicy
    - imageReferences contains at least one entry matching <registry>/*

  demo-overlay/kustomization.yaml
    - parses as valid YAML
    - contains an 'images' list
    - the entry for nginx has newName set to the name
      component of <image> (no tag, no digest)
    - if <image> contains @sha256:, the entry uses 'digest' not 'newTag'
    - if <image> has a tag, the entry uses 'newTag' matching that tag
"""
import sys
import re
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml not available — install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"ok  {msg}")


def parse_yaml(path: Path) -> dict:
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        die(f"{path.name} is not valid YAML: {e}")
    if not isinstance(doc, dict):
        die(f"{path.name} did not parse to a YAML mapping")
    return doc


def parse_image(image: str):
    """Return (name, tag, digest) for an OCI image reference."""
    digest_match = re.search(r"@(sha256:[a-f0-9]{64})$", image)
    if digest_match:
        name = image[: digest_match.start()]
        return name, None, digest_match.group(1)
    tag_match = re.search(r":([a-zA-Z0-9._\-]+)$", image)
    if tag_match and tag_match.start() > image.rfind("/"):
        return image[: tag_match.start()], tag_match.group(1), None
    return image, None, None


def main():
    if len(sys.argv) != 4:
        die(f"usage: {sys.argv[0]} <rendered_dir> <registry> <image>")

    rendered_dir = Path(sys.argv[1])
    registry = sys.argv[2]
    image = sys.argv[3]

    expected_registry_glob = f"{registry}/*"
    img_name, img_tag, img_digest = parse_image(image)

    # ── restrict-registries.yaml ──────────────────────────────────────────────
    rr_path = rendered_dir / "restrict-registries.yaml"
    if not rr_path.exists():
        die("restrict-registries.yaml not found")
    rr = parse_yaml(rr_path)

    if rr.get("kind") != "ClusterPolicy":
        die("restrict-registries.yaml: expected kind: ClusterPolicy")
    ok("restrict-registries.yaml: valid YAML, kind=ClusterPolicy")

    rules = rr.get("spec", {}).get("rules", [])
    patterns = []
    for rule in rules:
        for p in rule.get("validate", {}).get("anyPattern", []):
            for c in p.get("spec", {}).get("containers", []):
                patterns.append(c.get("image", ""))

    if not any(p == expected_registry_glob for p in patterns):
        die(
            f"restrict-registries.yaml: no anyPattern entry matches '{expected_registry_glob}' "
            f"(found: {patterns})"
        )
    ok(f"restrict-registries.yaml: anyPattern contains '{expected_registry_glob}'")

    # ── require-signed-images.yaml ────────────────────────────────────────────
    rs_path = rendered_dir / "require-signed-images.yaml"
    if not rs_path.exists():
        die("require-signed-images.yaml not found")
    rs = parse_yaml(rs_path)

    if rs.get("kind") != "ClusterPolicy":
        die("require-signed-images.yaml: expected kind: ClusterPolicy")
    ok("require-signed-images.yaml: valid YAML, kind=ClusterPolicy")

    image_refs = []
    for rule in rs.get("spec", {}).get("rules", []):
        for vi in rule.get("verifyImages", []):
            image_refs.extend(vi.get("imageReferences", []))

    if not any(ref == expected_registry_glob for ref in image_refs):
        die(
            f"require-signed-images.yaml: no imageReferences entry matches '{expected_registry_glob}' "
            f"(found: {image_refs})"
        )
    ok(f"require-signed-images.yaml: imageReferences contains '{expected_registry_glob}'")

    # ── demo-overlay/kustomization.yaml ───────────────────────────────────────
    overlay_path = rendered_dir / "demo-overlay" / "kustomization.yaml"
    if not overlay_path.exists():
        die("demo-overlay/kustomization.yaml not found")
    overlay = parse_yaml(overlay_path)

    images = overlay.get("images")
    if not isinstance(images, list) or not images:
        die("demo-overlay/kustomization.yaml: 'images' key missing or empty")
    ok("demo-overlay/kustomization.yaml: valid YAML, 'images' list present")

    entry = images[0]
    new_name = entry.get("newName", "")
    new_tag = entry.get("newTag")
    digest_val = entry.get("digest")

    if new_name != img_name:
        die(
            f"demo-overlay/kustomization.yaml: newName='{new_name}' "
            f"does not match expected '{img_name}'"
        )
    ok(f"demo-overlay/kustomization.yaml: newName='{new_name}'")

    if img_digest:
        if digest_val != img_digest:
            die(
                f"demo-overlay/kustomization.yaml: digest='{digest_val}' "
                f"expected '{img_digest}'"
            )
        if new_tag is not None:
            die(
                f"demo-overlay/kustomization.yaml: digest-pinned image must not have newTag "
                f"(found newTag='{new_tag}')"
            )
        ok(f"demo-overlay/kustomization.yaml: digest='{digest_val}' (no newTag)")
    else:
        expected_tag = img_tag or "latest"
        if str(new_tag) != expected_tag:
            die(
                f"demo-overlay/kustomization.yaml: newTag='{new_tag}' "
                f"expected '{expected_tag}'"
            )
        if digest_val is not None:
            die(
                f"demo-overlay/kustomization.yaml: tag-based image must not have digest field "
                f"(found digest='{digest_val}')"
            )
        ok(f"demo-overlay/kustomization.yaml: newTag='{new_tag}' (no digest field)")


if __name__ == "__main__":
    main()
