#!/usr/bin/env bash
set -euo pipefail


set -a
source .env
set +a

ENVIRONMENTS=("dev" "test" "prod")

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
REGISTRANT_ROLE="Resource Provider Registrant"
if [ -z "$(az role definition list --name "$REGISTRANT_ROLE" --query "[0].roleName" -o tsv)" ]; then
  az role definition create --role-definition '{
    "Name": "'"$REGISTRANT_ROLE"'",
    "Description": "Register resource providers/features at subscription scope. No resource access.",
    "Actions": ["*/register/action"],
    "AssignableScopes": ["/subscriptions/'"$SUBSCRIPTION_ID"'"]
  }'
  sleep 10  # let the new role definition propagate before it can be assigned
fi


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
    --role "$REGISTRANT_ROLE" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}"

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