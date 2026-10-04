#!/usr/bin/env bash
# One-time management-plane setup. Run as the subscription Owner.
set -euo pipefail
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-8406cce0-3a67-4d8e-b536-965b930989af}"
MANAGEMENT_GROUP=paiziq-infra
STATE_ACCOUNT="${STATE_ACCOUNT:-paiziqtf8406cce0}"
INFRA_REPO=paiziq-admin/Paiziq-Infra
SDK_REPO=paiziq-admin/Paiziq-sdk
az account set --subscription "$SUBSCRIPTION_ID"
state="$(az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID?api-version=2022-12-01" --query state -o tsv)"
if [ "$state" != Enabled ]; then
  echo "Subscription state is $state. Ask the Owner to restore it before bootstrap." >&2
  exit 1
fi
# Owner is required for the subscription-wide grants below. Azure also enforces
# this permission on each assignment; no attempt to bypass access controls.
TENANT_ID="$(az account show --query tenantId -o tsv)"
SCOPE="/subscriptions/$SUBSCRIPTION_ID"
OWNER_USER="$(az ad signed-in-user show --query id -o tsv)"
owner_grants="$(az role assignment list --assignee "$OWNER_USER" --scope "$SCOPE" --include-inherited \
  --query "length([?roleDefinitionName=='Owner'])" -o tsv)"
if [ "$owner_grants" = 0 ]; then
  echo 'Run bootstrap with a subscription Owner account; role-assignment permissions are required.' >&2
  exit 1
fi
az group create -n "$MANAGEMENT_GROUP" -l centralus --tags application=paiziq managed_by=bootstrap --output none
az storage account create -g "$MANAGEMENT_GROUP" -n "$STATE_ACCOUNT" -l centralus \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false --output none
az storage account blob-service-properties update -g "$MANAGEMENT_GROUP" --account-name "$STATE_ACCOUNT" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 7 \
  --enable-container-delete-retention true --container-delete-retention-days 7 --output none
STORAGE_ID="$(az storage account show -g "$MANAGEMENT_GROUP" -n "$STATE_ACCOUNT" --query id -o tsv)"
# Use ARM to create the state container; no account-key extraction is needed.
az rest --method put --url "https://management.azure.com$STORAGE_ID/blobServices/default/containers/tfstate?api-version=2025-06-01" \
  --body '{"properties":{"publicAccess":"None"}}' --output none
for identity in paiziq-infra-github paiziq-apps-github; do
  az identity create -g "$MANAGEMENT_GROUP" -n "$identity" -l centralus --output none
done
INFRA_CLIENT="$(az identity show -g "$MANAGEMENT_GROUP" -n paiziq-infra-github --query clientId -o tsv)"
INFRA_PRINCIPAL="$(az identity show -g "$MANAGEMENT_GROUP" -n paiziq-infra-github --query principalId -o tsv)"
SDK_CLIENT="$(az identity show -g "$MANAGEMENT_GROUP" -n paiziq-apps-github --query clientId -o tsv)"
SDK_PRINCIPAL="$(az identity show -g "$MANAGEMENT_GROUP" -n paiziq-apps-github --query principalId -o tsv)"
assign_role() {
  local principal="$1" role="$2" scope="$3" count
  count="$(az role assignment list --assignee "$principal" --scope "$scope" --all \
    --query "length([?roleDefinitionName=='$role' && scope=='$scope'])" -o tsv)"
  if [ "$count" = 0 ]; then
    az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --output none
  fi
}
assign_role "$INFRA_PRINCIPAL" Contributor "$SCOPE"
assign_role "$INFRA_PRINCIPAL" 'Role Based Access Control Administrator' "$SCOPE"
assign_role "$INFRA_PRINCIPAL" 'Storage Blob Data Contributor' "$STORAGE_ID/blobServices/default/containers/tfstate"
# Identity role assignment listing is not a data-plane operation. Contributor
# already allows pushes only once the registry-scoped AcrPush grant exists.
# Infra needs to publish the initial backend image into either environment.
assign_role "$INFRA_PRINCIPAL" AcrPush "$SCOPE"
for environment in dev prod; do
  name="github-$environment"
  subject="repo:$INFRA_REPO:environment:$environment"
  if az identity federated-credential show -g "$MANAGEMENT_GROUP" --identity-name paiziq-infra-github -n "$name" --output none 2>/dev/null; then
    az identity federated-credential update -g "$MANAGEMENT_GROUP" --identity-name paiziq-infra-github -n "$name" \
      --issuer https://token.actions.githubusercontent.com --subject "$subject" --audiences api://AzureADTokenExchange --output none
  else
    az identity federated-credential create -g "$MANAGEMENT_GROUP" --identity-name paiziq-infra-github -n "$name" \
      --issuer https://token.actions.githubusercontent.com --subject "$subject" --audiences api://AzureADTokenExchange --output none
  fi
  gh api --method PUT "repos/$INFRA_REPO/environments/$environment" --input - <<'JSON' >/dev/null
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
  branches="$(gh api "repos/$INFRA_REPO/environments/$environment/deployment-branch-policies" --jq '[.branch_policies[] | select(.name == "main" and .type == "branch")] | length')"
  if [ "$branches" = 0 ]; then
    gh api --method POST "repos/$INFRA_REPO/environments/$environment/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  fi
done
if ! az identity federated-credential show -g "$MANAGEMENT_GROUP" --identity-name paiziq-apps-github -n github-sdk-main --output none 2>/dev/null; then
  az identity federated-credential create -g "$MANAGEMENT_GROUP" --identity-name paiziq-apps-github -n github-sdk-main \
    --issuer https://token.actions.githubusercontent.com --subject "repo:$SDK_REPO:ref:refs/heads/main" \
    --audiences api://AzureADTokenExchange --output none
fi
for provider in Microsoft.App Microsoft.ContainerRegistry Microsoft.Storage Microsoft.Web Microsoft.ManagedIdentity; do
  az provider register --namespace "$provider" --wait --output none
done
# Only public identifiers go to GitHub variables. Runtime keys stay in Azure.
gh variable set AZURE_CLIENT_ID --repo "$INFRA_REPO" --body "$INFRA_CLIENT"
gh variable set AZURE_TENANT_ID --repo "$INFRA_REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$INFRA_REPO" --body "$SUBSCRIPTION_ID"
gh variable set TF_STATE_STORAGE_ACCOUNT --repo "$INFRA_REPO" --body "$STATE_ACCOUNT"
gh variable set TF_STATE_CONTAINER --repo "$INFRA_REPO" --body tfstate
gh variable set SDK_CI_PRINCIPAL_ID --repo "$INFRA_REPO" --body "$SDK_PRINCIPAL"
# Switch existing app CI away from the identity inside the disposable dev group.
gh variable set AZURE_CLIENT_ID --repo "$SDK_REPO" --body "$SDK_CLIENT"
gh variable set AZURE_TENANT_ID --repo "$SDK_REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$SDK_REPO" --body "$SUBSCRIPTION_ID"
printf 'Bootstrap complete. Run Spin up dev or Spin up prod in %s.\n' "$INFRA_REPO"
