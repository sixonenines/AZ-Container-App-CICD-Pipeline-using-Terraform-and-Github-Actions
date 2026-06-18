# Improvements / roadmap

Tracked list of things that would make this repo more production-grade. Ordered
roughly by impact for a portfolio / hiring reviewer.

## 1. Write a proper README (highest priority)

The current `README.md` is a stub. A reviewer reads the README first, so this is
the biggest single win. Suggested sections:

- **Title + one-paragraph summary** — what it is: an Azure Container Apps CI/CD
  pipeline built with Terraform and GitHub Actions, deployed via OIDC (no
  long-lived secrets).
- **Architecture diagram** — boxes for GitHub Actions, Entra ID (OIDC federated
  credential), the Terraform remote backend (Storage Account), ACR, the Container
  App Environment + Container App, and Log Analytics. A simple Mermaid diagram in
  the README renders on GitHub.
- **Repository layout** — explain `infra/platform`, `infra/app`, `app/`,
  `bootstrap/`, and the three-plus-one workflows.
- **How auth works** — OIDC federated credentials, why there are no client
  secrets, the user-assigned identity + AcrPull for image pulls.
- **Environments** — dev/test/prod, per-env tfvars, per-env state keys.
- **Prerequisites** — Azure subscription, `az` CLI, Terraform, the GitHub repo
  variables/secrets the workflows expect (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`, `RESOURCE_GROUP_NAME`, `TF_BACKEND_*`).
- **Getting started** — run `bootstrap/bootstrap.sh`, then the platform workflow,
  then push app code to trigger `deploy.yml`.
- **CI/CD flow** — the split between `infra-platform`, `infra-app` (plan/destroy
  only), `deploy` (build → push → apply), and `terraform-plan` on PRs. Explain
  *why* there is a single applier of the app state (no `image_tag` drift).
- **Design decisions / trade-offs** — subscription-scoped role (provider
  registration), SHA-tagged images for real rollouts, scale-to-zero for cost.
- **Cost notes** — ACR Standard fixed cost, scale-to-zero, how to fully tear down.

## 2. Add a Container App FQDN output

`infra/app/outputs.tf` is empty. Add an output for the ingress FQDN so the URL is
printed at the end of a deploy instead of having to look it up in the portal:

```hcl
output "app_url" {
  description = "Public URL of the Container App."
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}"
}
```

Then echo it in `deploy.yml` after apply.

## 3. PR validation CI

A dedicated quality gate on pull requests (separate from, or folded into, the
existing `terraform-plan` workflow):

- `terraform fmt -check -recursive`
- `terraform validate` for both stacks
- [`tflint`](https://github.com/terraform-linters/tflint) with the azurerm ruleset
- Optional: `hadolint` for the Dockerfile, `actionlint` for the workflows

Make these required status checks via branch protection on `main`.

## 4. Security scanning

Add IaC security scanning so misconfigurations are caught automatically:

- [`tfsec`](https://github.com/aquasecurity/tfsec) or
  [`checkov`](https://github.com/bridgecrewio/checkov) on PRs.
- Upload SARIF results to GitHub code scanning so findings show in the Security
  tab and inline on PRs.
- Consider `trivy` to scan the built container image for CVEs before deploy.

## 5. Promote one image artifact across environments ✅ DONE

**Implemented** via the **single shared registry** approach:

- `bootstrap.sh` creates one shared ACR (SKU configurable; defaults to `Standard`)
  plus a dedicated least-privilege **build identity** (`AcrPush` only).
- `build-deploy.yml` builds the image **once** on merge to `main`, pushes it to the
  shared registry, captures the immutable **digest**, and deploys **dev** pinned to
  that digest.
- `promote.yml` deploys the **same digest** to test/prod (resolved from the shared
  ACR by commit SHA) — **no rebuild**, so prod runs the bit-for-bit image tested in
  dev. The app stack references the image by digest (`<acr>/webapp@sha256:…`).
- The `prod` GitHub Environment is gated by a required reviewer (set via
  `PROD_REVIEWERS` in bootstrap, or in the GitHub UI).

**Trade-off accepted:** all environments share one registry, so blast-radius
isolation is weaker than a registry-per-environment. Chosen deliberately for
cheap + simple operation.

**Higher-isolation variant (not taken):** keep a registry per environment (or a
non-prod + prod split) and promote with `az acr import`, copying the exact image by
digest into the target registry rather than having every environment pull from one:

```bash
az acr import \
  --name <prod-acr> \
  --source <dev-acr>.azurecr.io/webapp@sha256:<digest> \
  --image webapp:<sha>
```

This preserves per-registry isolation at the cost of more registries (one per env)
and cross-registry import rights on the promoting identity.

## 6. Other professional touches

- **Branch protection on `main`** — require PR review + passing plan/validation
  before merge.
- **Gate prod** — require reviewers on the `prod` GitHub Environment; consider a
  manual approval between plan and apply.
- **Commit the `.terraform.lock.hcl` files** — pin provider versions for
  reproducible runs (they are currently untracked).
- **Pre-commit hooks** — `pre-commit` with terraform fmt/validate/tflint so issues
  are caught locally before CI.
- **Save plan as an artifact and apply that exact plan** — instead of a fresh
  apply, to guarantee what was reviewed is what ships.
- **Dependabot** — keep the GitHub Actions versions up to date.
