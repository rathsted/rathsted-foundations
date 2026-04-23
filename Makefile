SHELL := /usr/bin/env bash

.PHONY: help help-core doctor configure validate-config install uninstall app-runtime verify verify-release verify-all policy-test sign sbom jurisdiction-scan flux-reconcile

REGISTRY ?= ghcr.io/rathsted
IMAGE ?= $(REGISTRY)/foundations-demo:1.0.0
KEY ?= supply-chain/cosign/cosign.key
RELEASE_TAG ?=
CUSTOMER_DIR ?= examples/customer-instance
STRICT ?= 0

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

help-core: ## Show critical day-to-day targets
	@printf "\n\033[1mCore Targets\033[0m\n"
	@printf "  %-22s %s\n" "doctor" "Check local tools and required files before starting"
	@printf "  %-22s %s\n" "configure" "Set registry/image and render policies (run before install)"
	@printf "  %-22s %s\n" "validate-config" "Validate rendered config before install or release checks"
	@printf "  %-22s %s\n" "install" "Bootstrap cluster (k3s + Flux + Kyverno + policies)"
	@printf "  %-22s %s\n" "verify" "Baseline cluster and policy verification"
	@printf "  %-22s %s\n" "verify-release" "Release-grade verification (registry + signatures)"
	@printf "  %-22s %s\n" "verify-all" "Full acceptance checks (verify + policy-test + jurisdiction-scan)"

##@ Preflight

doctor: ## Preflight check (tools, files, git, environment)
	./scripts/doctor.sh

##@ Lifecycle

configure: ## Set registry/image and render policies (run before install)
	./scripts/configure.sh

validate-config: ## Validate config/rendered/ against customer.env
	./scripts/validate-config.sh

install: ## Run bootstrap install (k3s + Flux + Kyverno + policies)
	./bootstrap/install.sh

uninstall: ## Remove k3s and all cluster state
	./bootstrap/uninstall.sh

app-runtime: ## Apply optional app-runtime profile (Traefik, NATS, Postgres)
	kubectl apply -k profiles/app-runtime

##@ Verification

verify: ## Run bootstrap verify (cluster health + policy checks)
	./bootstrap/verify.sh

verify-release: ## Release-grade verification (registry, signatures enforced)
	./bootstrap/verify.sh --release

verify-all: ## Acceptance checks (verify + policy-test + jurisdiction-scan)
	./bootstrap/verify.sh
	$(MAKE) policy-test
	$(MAKE) jurisdiction-scan

##@ Test

policy-test: ## Run Kyverno policy tests (requires kyverno CLI)
	@command -v kyverno >/dev/null 2>&1 || { echo "kyverno CLI not found"; exit 1; }
	kyverno test tests/kyverno -f kyverno-test.yaml

##@ Supply Chain

sign: ## Sign your image with cosign (IMAGE=registry/name:tag)
	@command -v cosign >/dev/null 2>&1 || { echo "cosign not found"; exit 1; }
	@if [[ ! -f "$(KEY)" ]]; then echo "cosign key not found: $(KEY)"; exit 1; fi
	cosign sign --key "$(KEY)" "$(IMAGE)"

sbom: ## Generate SBOM for your image (IMAGE=registry/name:tag)
	@command -v syft >/dev/null 2>&1 || { echo "syft not found"; exit 1; }
	@mkdir -p supply-chain/sbom/output
	syft "$(IMAGE)" -o json > supply-chain/sbom/output/image.sbom.json

##@ Operations

jurisdiction-scan: ## Run jurisdiction scan on this repo
	PYTHONPATH=tools/jurisdiction-scan/src python3 -m jurisdiction_scan.cli .

flux-reconcile: ## Force Flux to reconcile the repo
	@command -v flux >/dev/null 2>&1 || { echo "flux not found"; exit 1; }
	flux reconcile source git rathsted-foundations -n flux-system
	flux reconcile kustomization rathsted-sync -n flux-system
