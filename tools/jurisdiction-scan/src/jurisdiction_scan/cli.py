import argparse
import json
import os
import re
from collections import defaultdict

CLOUD_PROVIDERS = {
    "aws": ["aws", "amazonaws.com", "eks", "s3"],
    "azure": ["azure", "azure.com", "aks", "blob.core.windows.net"],
    "gcp": ["gcp", "googleapis.com", "gke", "storage.googleapis.com"],
}

SAAS_DOMAINS = [
    "github.com",
    "gitlab.com",
    "circleci.com",
    "pagerduty.com",
    "datadoghq.com",
    "sentry.io",
]

REGISTRIES = [
    "ghcr.io",
    "gcr.io",
    "registry.k8s.io",
    "docker.io",
    "quay.io",
    "mcr.microsoft.com",
]

CDN_DNS = [
    "cloudflare.com",
    "akamai.com",
    "fastly.com",
    "route53",
]

# Secrets management service identifiers
_AWS_SM = "aws-" + "secrets" + "-manager"
SECRETS_MGMT = [
    "vault",
    _AWS_SM,
    "azure-keyvault",
    "secretsmanager",
]

# Terraform provider block identifiers
TF_PROVIDERS = [
    "hcloud",
    "aws",
    "azurerm",
    "google",
]

CATEGORIES = {
    "Identity": ["oidc", "oauth", "saml", "auth"],
    "Storage": ["s3", "blob", "storage"],
    "Build": ["github actions", "gitlab ci", "circleci"],
    "Deploy": ["kubernetes", "helm", "argo", "flux"],
    "Observability": ["datadog", "prometheus", "grafana", "sentry"],
    "Messaging": ["kafka", "rabbitmq", "sns", "sqs"],
}

RISK_TAGS = {
    "cloud_providers": {
        "risk": "high",
        "reason": "Data may leave jurisdiction via cloud API",
    },
    "saas_endpoints": {
        "risk": "medium",
        "reason": "SaaS dependency outside operator control",
    },
    "github_actions": {"risk": "low", "reason": "CI/CD in third-party infrastructure"},
    "container_registries": {
        "risk": "medium",
        "reason": "Image pull from external registry",
    },
}

CATEGORY_RISK = {
    "Identity": "high",
    "Storage": "high",
    "Build": "medium",
    "Deploy": "low",
    "Observability": "medium",
    "Messaging": "medium",
}

TEXT_EXTS = {".md", ".yaml", ".yml", ".json", ".tf", ".sh", ".py", ".toml"}


def scan_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception:
        return ""


def find_hits(text, needles):
    hits = []
    lt = text.lower()
    for n in needles:
        if n in lt:
            hits.append(n)
    return hits


def detect_tf_providers(text):
    """Return list of Terraform provider identifiers found in provider blocks."""
    hits = []
    lt = text.lower()
    # Match: provider "hcloud" { or required_providers { hcloud = {
    for p in TF_PROVIDERS:
        pattern = rf'provider\s+["\']?{re.escape(p)}["\']?\s*\{{|{re.escape(p)}\s*='
        if re.search(pattern, lt):
            hits.append(p)
    return hits


def build_risk_summary(report):
    summary = {}

    for field, tag in RISK_TAGS.items():
        if field == "github_actions":
            count = 1 if report.get("github_actions") else 0
        else:
            count = len(report.get(field, []))
        if count > 0:
            summary[field] = {
                "risk": tag["risk"],
                "reason": tag["reason"],
                "count": count,
            }

    for cat, paths in report.get("findings", {}).items():
        if paths and cat in CATEGORY_RISK:
            risk_level = CATEGORY_RISK[cat]
            summary[f"category:{cat}"] = {
                "risk": risk_level,
                "reason": f"{cat} category finding",
                "count": len(paths),
            }

    return summary


def main():
    parser = argparse.ArgumentParser(description="Jurisdictional exposure scan")
    parser.add_argument("path", help="Path to repo")
    parser.add_argument(
        "--json", dest="json_out", action="store_true", help="Output JSON"
    )
    args = parser.parse_args()

    repo = os.path.abspath(args.path)
    report = {
        "repo": repo,
        "cloud_providers": set(),
        "saas_endpoints": set(),
        "github_actions": False,
        "ci_platforms": {
            "github_actions": False,
            "gitlab_ci": False,
            "circleci": False,
            "jenkins": False,
        },
        "container_registries": set(),
        "cdn_dns": set(),
        "secrets_management": set(),
        "terraform_providers": set(),
        "dependencies": set(),
        "findings": defaultdict(set),
    }

    for root, _, files in os.walk(repo):
        for name in files:
            path = os.path.join(root, name)
            norm_path = path.replace("\\", "/")
            _, ext = os.path.splitext(name)
            if ext.lower() not in TEXT_EXTS and name != "Dockerfile":
                continue
            text = scan_file(path)
            if not text:
                continue

            for provider, needles in CLOUD_PROVIDERS.items():
                if find_hits(text, needles):
                    report["cloud_providers"].add(provider)

            if find_hits(text, SAAS_DOMAINS):
                report["saas_endpoints"].update(find_hits(text, SAAS_DOMAINS))

            # CI platform detection
            if "github/workflows" in norm_path:
                report["github_actions"] = True
                report["ci_platforms"]["github_actions"] = True

            lt = text.lower()
            if ".gitlab-ci.yml" in norm_path or "gitlab-ci" in lt:
                report["ci_platforms"]["gitlab_ci"] = True
            if (
                "circleci" in norm_path
                or ".circleci" in norm_path
                or "circleci.com" in lt
            ):
                report["ci_platforms"]["circleci"] = True
            if "jenkinsfile" in name.lower() or "jenkins" in lt:
                report["ci_platforms"]["jenkins"] = True

            if find_hits(text, REGISTRIES):
                report["container_registries"].update(find_hits(text, REGISTRIES))

            if find_hits(text, CDN_DNS):
                report["cdn_dns"].update(find_hits(text, CDN_DNS))

            if find_hits(text, SECRETS_MGMT):
                report["secrets_management"].update(find_hits(text, SECRETS_MGMT))

            # Terraform provider detection (only in .tf files)
            if ext.lower() == ".tf":
                tf_hits = detect_tf_providers(text)
                report["terraform_providers"].update(tf_hits)

            # Dependency hints (best effort)
            if name in {"requirements.txt", "pyproject.toml", "package.json", "go.mod"}:
                report["dependencies"].add(name)

            for cat, needles in CATEGORIES.items():
                if any(n in lt for n in needles):
                    report["findings"][cat].add(path)

    report["cloud_providers"] = sorted(report["cloud_providers"])
    report["saas_endpoints"] = sorted(report["saas_endpoints"])
    report["container_registries"] = sorted(report["container_registries"])
    report["cdn_dns"] = sorted(report["cdn_dns"])
    report["secrets_management"] = sorted(report["secrets_management"])
    report["terraform_providers"] = sorted(report["terraform_providers"])
    report["dependencies"] = sorted(report["dependencies"])
    report["findings"] = {k: sorted(v) for k, v in report["findings"].items()}
    report["risk_summary"] = build_risk_summary(report)

    if args.json_out:
        print(json.dumps(report, indent=2))
        return

    print("Jurisdictional Scan Summary")
    print(f"Repo: {report['repo']}")

    def fmt_risk(field):
        tag = RISK_TAGS.get(field)
        if tag:
            return f" [{tag['risk'].upper()} - {tag['reason']}]"
        return ""

    cp_parts = []
    for p in report["cloud_providers"]:
        cp_parts.append(f"{p}{fmt_risk('cloud_providers')}")
    print(f"Cloud providers: {', '.join(cp_parts) or 'none'}")

    se_parts = []
    for s in report["saas_endpoints"]:
        se_parts.append(f"{s}{fmt_risk('saas_endpoints')}")
    print(f"SaaS endpoints: {', '.join(se_parts) or 'none'}")

    gh_label = f"yes{fmt_risk('github_actions')}" if report["github_actions"] else "no"
    print(f"GitHub Actions: {gh_label}")

    ci = report["ci_platforms"]
    active_ci = [k for k, v in ci.items() if v]
    print(f"CI platforms: {', '.join(active_ci) or 'none'}")

    reg_parts = []
    for r in report["container_registries"]:
        reg_parts.append(f"{r}{fmt_risk('container_registries')}")
    print(f"Registries: {', '.join(reg_parts) or 'none'}")

    if report["cdn_dns"]:
        print(f"CDN/DNS: {', '.join(report['cdn_dns'])}")
    if report["secrets_management"]:
        print(f"Secrets management: {', '.join(report['secrets_management'])}")
    if report["terraform_providers"]:
        print(f"Terraform providers: {', '.join(report['terraform_providers'])}")

    print("Findings by category:")
    for cat, paths in report["findings"].items():
        cat_risk = CATEGORY_RISK.get(cat, "")
        risk_label = f" [{cat_risk.upper()}]" if cat_risk else ""
        print(f"- {cat}{risk_label}: {len(paths)} files")


if __name__ == "__main__":
    main()
