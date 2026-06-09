#!/usr/bin/env bash
set -euo pipefail


set -a
source .env
set +a

ENVIRONMENTS=("dev" "test" "prod")

SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
TENANT_ID=$(az account show --query "tenantId" -o tsv)
RG_STATESTORAGE="${RG_NAME}-tfstatestorage"
GITHUB_REPO_FULL="${GITHUB_OWNER}/${GITHUB_REPO}"

az account set --subscription "$SUBSCRIPTION_ID"

# Create a RG for the storage account
az group create --name "$RG_STATESTORAGE" --location "$LOCATION"

## Handle unavailable account names
az storage account check-name --name "$STORAGE_ACCOUNT_NAME"

az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RG_STATESTORAGE" \
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

az storage container create \
  --name "$BLOB_CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --public-access off \
  --auth-mode login


# Each environment gets its own RG + managed identity + OICD + scoped roles
for ENV in "${ENVIRONMENTS[@]}"; do
  ENV_RG="${RG_NAME}-${ENV}"
  ENV_MI="${MANAGED_IDENTITY_NAME}-${ENV}"
  ENV_FEDERATED_CREDENTIAL="${FEDERATED_CREDENTIAL_NAME}-${ENV}"

  az group create --name "$ENV_RG" --location "$LOCATION"

  az identity create \
    --name "$ENV_MI" \
    --resource-group "$ENV_RG" \
    --location "$LOCATION"

  # Could read json once and then query it in the other var.
  MI_CLIENT_ID=$(az identity show --name "$ENV_MI" --resource-group "$ENV_RG" --query "clientId" -o tsv)

  MI_PRINCIPAL_ID=$(az identity show --name "$ENV_MI" --resource-group "$ENV_RG" --query "principalId" -o tsv)


  az identity federated-credential create \
    --name "$ENV_FEDERATED_CREDENTIAL" \
    --identity-name "$ENV_MI" \
    --resource-group "$ENV_RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:${ENV}" \
    --audiences "api://AzureADTokenExchange"

  # Role assignment can take time to propagate, I could continously check till its propagated
  # sleep 10 works fine for now
  sleep 10

  az role assignment create \
    --assignee-object-id "$MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ENV_RG}"

  az role assignment create \
    --assignee-object-id "$MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "User Access Administrator" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ENV_RG}"

  CONTAINER_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_STATESTORAGE}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}/blobServices/default/containers/${BLOB_CONTAINER_NAME}"
  ## Maybe adapt the scope so that each MI only has access to its own TF State
  az role assignment create \
  --assignee-object-id "$MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$CONTAINER_SCOPE"

  gh variable set AZURE_CLIENT_ID       --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$MI_CLIENT_ID"
  gh variable set AZURE_TENANT_ID       --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID --env "$ENV" --repo "$GITHUB_REPO_FULL" --body "$SUBSCRIPTION_ID" # Microsoft recommends to not keep the subscription id public
done



# Variables — backend config, fine as plaintext
gh variable set TF_BACKEND_RG          --repo "$GITHUB_REPO_FULL" --body "$RG_STATESTORAGE" 
gh variable set TF_BACKEND_SA          --repo "$GITHUB_REPO_FULL" --body "$STORAGE_ACCOUNT_NAME"
gh variable set TF_BACKEND_CONTAINER   --repo "$GITHUB_REPO_FULL" --body "$BLOB_CONTAINER_NAME"