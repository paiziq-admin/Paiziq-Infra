#!/usr/bin/env bash
# After dev recreation, refresh the existing app repository's deployment token.
# Run locally using your own Azure and GitHub owner/admin logins.
set -euo pipefail
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-8406cce0-3a67-4d8e-b536-965b930989af}"
az account set --subscription "$SUBSCRIPTION_ID"
# Pipe directly: do not print the token or store it in a file/command argument.
token="$(az staticwebapp secrets list -g paiziq-dev -n paiziq-dashboard-dev \
  --query properties.apiKey -o tsv --only-show-errors)"
if [ -z "$token" ] || [ "$token" = null ]; then
  echo 'Azure did not return a deployment token; leaving the GitHub secret unchanged.' >&2
  exit 1
fi
printf '%s' "$token" | gh secret set AZURE_STATIC_WEB_APPS_API_TOKEN --repo paiziq-admin/Paiziq-Dashboard
unset token
printf 'Updated the dashboard CI deployment token for the current dev app.\n'
printf 'Use the current backend/dashboard URLs in the spin-up workflow summary.\n'
