#!/usr/bin/env bash
set -euo pipefail


set -a
source .env
set +a

ENVIRONMENTS=("dev" "test" "prod")
WORKLOAD="webapp" # must match the Terraform `workload` variable default

SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
TENANT_ID=$(az account show --query "tenantId" -o tsv)
STATE_STORAGE_RESOURCE_GROUP="${RESOURCE_GROUP_BASE_NAME}-tfstatestorage"
GITHUB_REPO_FULL="${GITHUB_OWNER}/${GITHUB_REPO}"

az account set --subscription "$SUBSCRIPTION_ID"

# Create a RG for the storage account
az group create --name "$STATE_STORAGE_RESOURCE_GROUP" --location "$LOCATION"

## Todo: Handle unavailable account names
az storage account check-name --name "$STORAGE_ACCOUNT_NAME"

az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$STATE_STORAGE_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --enable-versioning true

# Custom role granting ONLY resource-provider/feature registration at subscription scope.
# Registration is subscription-wide and non-destructive, so sharing it across
# environments does not let one environment touch another's resources.
PROVIDER_REGISTRATION_ROLE_NAME="Resource Provider Registrant"
if [ -z "$(az role definition list --name "$PROVIDER_REGISTRATION_ROLE_NAME" --query "[0].roleName" -o tsv)" ]; then
  az role definition create --role-definition '{
    "Name": "'"$PROVIDER_REGISTRATION_ROLE_NAME"'",
    "Description": "Register resource providers/features at subscription scope. No resource access.",
    "Actions": ["*/register/action"],
    "AssignableScopes": ["/subscriptions/'"$SUBSCRIPTION_ID"'"]
  }'
  sleep 10  # let the new role definition propagate before it can be assigned
fi


# ---------------------------------------------------------------------------
# Shared foundation: ONE registry that every environment builds into and pulls
# from, plus a dedicated least-privilege build identity that can only push to it.
# Created here (like the Terraform state storage account) rather than in Terraform,
# because it is cross-environment foundational infrastructure.
# ---------------------------------------------------------------------------
SHARED_RESOURCE_GROUP="${RESOURCE_GROUP_BASE_NAME}-shared"
BUILD_MANAGED_IDENTITY="${MANAGED_IDENTITY_NAME}-build"
BUILD_FEDERATED_CREDENTIAL="${FEDERATED_CREDENTIAL_NAME}-build"

az group create --name "$SHARED_RESOURCE_GROUP" --location "$LOCATION"

# Reuse an existing registry if bootstrap ran before; otherwise create one with a
# globally-unique name (ACR names are 5-50 chars, lowercase alphanumeric).
SHARED_ACR_NAME=$(az acr list --resource-group "$SHARED_RESOURCE_GROUP" --query "[0].name" -o tsv)
if [ -z "$SHARED_ACR_NAME" ]; then
  ACR_BASE=$(echo "$RESOURCE_GROUP_BASE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
  SHARED_ACR_NAME="cr${ACR_BASE:0:18}$(openssl rand -hex 4)"
  az acr create \
    --name "$SHARED_ACR_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard \
    --admin-enabled false
fi
ACR_ID=$(az acr show --name "$SHARED_ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" --query id -o tsv)

# Dedicated build identity — granted ONLY AcrPush, so it can push images and
# nothing else. Distinct from the per-env deploy identities, which can only pull.
az identity create \
  --name "$BUILD_MANAGED_IDENTITY" \
  --resource-group "$SHARED_RESOURCE_GROUP" \
  --location "$LOCATION"

BUILD_IDENTITY_CLIENT_ID=$(az identity show --name "$BUILD_MANAGED_IDENTITY" --resource-group "$SHARED_RESOURCE_GROUP" --query "clientId" -o tsv)
BUILD_IDENTITY_PRINCIPAL_ID=$(az identity show --name "$BUILD_MANAGED_IDENTITY" --resource-group "$SHARED_RESOURCE_GROUP" --query "principalId" -o tsv)

az identity federated-credential create \
  --name "$BUILD_FEDERATED_CREDENTIAL" \
  --identity-name "$BUILD_MANAGED_IDENTITY" \
  --resource-group "$SHARED_RESOURCE_GROUP" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:build" \
  --audiences "api://AzureADTokenExchange"

sleep 20  # let the new identity propagate before assigning a role

az role assignment create \
  --assignee-object-id "$BUILD_IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPush" \
  --scope "$ACR_ID"

# The build job runs in the `build` GitHub Environment so its OIDC token subject
# (repo:owner/repo:environment:build) matches the federated credential above.
gh api -X PUT "repos/${GITHUB_REPO_FULL}/environments/build" >/dev/null
gh variable set AZURE_CLIENT_ID       --env build --repo "$GITHUB_REPO_FULL" --body "$BUILD_IDENTITY_CLIENT_ID"
gh variable set AZURE_TENANT_ID       --env build --repo "$GITHUB_REPO_FULL" --body "$TENANT_ID"
gh secret   set AZURE_SUBSCRIPTION_ID --env build --repo "$GITHUB_REPO_FULL" --body "$SUBSCRIPTION_ID"

# Repo-level vars so every workflow and Terraform stack can locate the shared registry.
gh variable set SHARED_ACR_NAME       --repo "$GITHUB_REPO_FULL" --body "$SHARED_ACR_NAME"
gh variable set SHARED_RESOURCE_GROUP --repo "$GITHUB_REPO_FULL" --body "$SHARED_RESOURCE_GROUP"


# Each environment gets its own RG + managed identity + OIDC + per-env state container + scoped roles
for ENV in "${ENVIRONMENTS[@]}"; do
  ENV_RESOURCE_GROUP="${RESOURCE_GROUP_BASE_NAME}-${ENV}"
  ENV_MANAGED_IDENTITY="${MANAGED_IDENTITY_NAME}-${ENV}"
  ENV_FEDERATED_CREDENTIAL="${FEDERATED_CREDENTIAL_NAME}-${ENV}"
  ENV_CONTAINER="${BLOB_CONTAINER_NAME}-${ENV}"

  az group create --name "$ENV_RESOURCE_GROUP" --location "$LOCATION"

  # Per-env state container so this env's MI can be scoped to only its own state
  az storage container create \
    --name "$ENV_CONTAINER" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --public-access off \
    --auth-mode login

  az identity create \
    --name "$ENV_MANAGED_IDENTITY" \
    --resource-group "$ENV_RESOURCE_GROUP" \
    --location "$LOCATION"

  # Could read json once and then query it in the other var.
  MANAGED_IDENTITY_CLIENT_ID=$(az identity show --name "$ENV_MANAGED_IDENTITY" --resource-group "$ENV_RESOURCE_GROUP" --query "clientId" -o tsv)

  MANAGED_IDENTITY_PRINCIPAL_ID=$(az identity show --name "$ENV_MANAGED_IDENTITY" --resource-group "$ENV_RESOURCE_GROUP" --query "principalId" -o tsv)


  az identity federated-credential create \
    --name "$ENV_FEDERATED_CREDENTIAL" \
    --identity-name "$ENV_MANAGED_IDENTITY" \
    --resource-group "$ENV_RESOURCE_GROUP" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:${ENV}" \
    --audiences "api://AzureADTokenExchange"

  # Role assignment can take time to propagate, I could continously check till its propagated
  # sleep works fine for now
  sleep 20

  az role assignment create \
    --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ENV_RESOURCE_GROUP}"

  az role assignment create \
    --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "User Access Administrator" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ENV_RESOURCE_GROUP}"

  CONTAINER_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${STATE_STORAGE_RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}/blobServices/default/containers/${ENV_CONTAINER}"
  # Scoped to this env's own container only — e.g. dev cannot read/write prod state
  az role assignment create \
  --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$CONTAINER_SCOPE"

  # Let this env's Terraform register resource providers (subscription scope, register-only)
  az role assignment create \
    --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$PROVIDER_REGISTRATION_ROLE_NAME" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}"

  # Runtime identity the Container App uses to pull images. Created here (not in
  # Terraform) and granted AcrPull on the shared ACR directly — so no deploy
  # identity ever holds role-assignment rights over the shared registry. The
  # platform Terraform only reads this identity by name.
  RUNTIME_IDENTITY="id-${WORKLOAD}-${ENV}"
  az identity create \
    --name "$RUNTIME_IDENTITY" \
    --resource-group "$ENV_RESOURCE_GROUP" \
    --location "$LOCATION"

  RUNTIME_IDENTITY_PRINCIPAL_ID=$(az identity show --name "$RUNTIME_IDENTITY" --resource-group "$ENV_RESOURCE_GROUP" --query "principalId" -o tsv)

  sleep 10 # let the new identity propagate before assigning a role

  az role assignment create \
    --assignee-object-id "$RUNTIME_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "AcrPull" \
    --scope "$ACR_ID"

  # GitHub environment must exist before setting env-scoped vars/secrets (gh won't auto-create it)
  gh api -X PUT "repos/${GITHUB_REPO_FULL}/environments/${ENV}" >/dev/null

  gh variable set AZURE_CLIENT_ID       --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$MANAGED_IDENTITY_CLIENT_ID"
  gh variable set AZURE_TENANT_ID       --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$TENANT_ID"
  gh variable set RESOURCE_GROUP_NAME   --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$ENV_RESOURCE_GROUP"   # Consumed by Terraform via TF_VAR_resource_group_name
  gh variable set TF_BACKEND_CONTAINER  --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$ENV_CONTAINER"  # Per-env state container; resolves per environment in the workflow
  gh secret set AZURE_SUBSCRIPTION_ID --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$SUBSCRIPTION_ID" # Microsoft recommends to not keep the subscription id public
done



# Variables — backend config, fine as plaintext
gh variable set TF_BACKEND_RESOURCE_GROUP  --repo "$GITHUB_REPO_FULL" --body "$STATE_STORAGE_RESOURCE_GROUP"
gh variable set TF_BACKEND_STORAGE_ACCOUNT --repo "$GITHUB_REPO_FULL" --body "$STORAGE_ACCOUNT_NAME"
# TF_BACKEND_CONTAINER is set per-environment inside the loop (one container per env)


# Optionally gate production: require a reviewer to approve any promote.yml run
# targeting prod. Set PROD_REVIEWERS in .env to a comma-separated list of GitHub
# usernames. If unset, the gate is skipped (configure it later in the GitHub UI).
if [ -n "${PROD_REVIEWERS:-}" ]; then
  REVIEWERS_JSON=""
  IFS=',' read -ra REVIEWER_LOGINS <<< "$PROD_REVIEWERS"
  for LOGIN in "${REVIEWER_LOGINS[@]}"; do
    LOGIN=$(echo "$LOGIN" | xargs) # trim surrounding whitespace
    [ -z "$LOGIN" ] && continue
    REVIEWER_ID=$(gh api "users/${LOGIN}" --jq '.id' 2>/dev/null || true)
    if [ -n "$REVIEWER_ID" ]; then
      REVIEWERS_JSON="${REVIEWERS_JSON}{\"type\":\"User\",\"id\":${REVIEWER_ID}},"
    else
      echo "Warning: could not resolve GitHub user '${LOGIN}' — skipping as prod reviewer." >&2
    fi
  done
  REVIEWERS_JSON="[${REVIEWERS_JSON%,}]"
  printf '{"reviewers":%s}' "$REVIEWERS_JSON" \
    | gh api -X PUT "repos/${GITHUB_REPO_FULL}/environments/prod" --input - >/dev/null \
    && echo "Required reviewers set on the 'prod' environment: ${PROD_REVIEWERS}" \
    || echo "Warning: failed to set prod required reviewers; configure them in the GitHub UI." >&2
else
  echo "PROD_REVIEWERS not set — prod promotions are NOT gated. Add required reviewers on the 'prod' environment in the GitHub UI to require approval before production deploys."
fi