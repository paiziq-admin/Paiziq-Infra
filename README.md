# Paiziq infrastructure

Terraform lifecycle management for the Paiziq dashboard and SDK backend in Azure.

| Manual GitHub workflow | Application resource group | Result |
| --- | --- | --- |
| [Spin up dev](https://github.com/paiziq-admin/Paiziq-Infra/actions/workflows/spin-up-dev.yml) | `paiziq-dev` | Import or create resources, deploy both applications, verify the hosted backend and dashboard |
| [Spin up prod](https://github.com/paiziq-admin/Paiziq-Infra/actions/workflows/spin-up-prod.yml) | `paiziq-prod` | Create an isolated production environment and deploy both applications |
| [Clean up dev](https://github.com/paiziq-admin/Paiziq-Infra/actions/workflows/clean-up-dev.yml) | `paiziq-dev` | Delete every resource in the group and the group itself |
| [Clean up prod](https://github.com/paiziq-admin/Paiziq-Infra/actions/workflows/clean-up-prod.yml) | `paiziq-prod` | Delete every resource in the group and the group itself |

Exactly four workflows, all `workflow_dispatch` only. Pushes and pull requests do not create or delete Azure resources. Run workflows from `main` through **Actions → workflow → Run workflow**. Create and cleanup share one concurrency group per environment, so they cannot overlap within this repository. Both environments can exist independently when the subscription quota permits it.

## What gets created

Each application group contains:

- A Free Azure Static Web App hosting the dashboard.
- A Consumption Azure Container Apps environment and backend app: 0.5 vCPU / 1 GiB, one replica, HTTPS on port 8800.
- A Basic Azure Container Registry with admin authentication disabled.
- Standard LRS storage with a 5 GiB Azure Files share for `/data/paiziq.sqlite`.
- A runtime managed identity with `AcrPull`, and SDK CI role assignments scoped to that environment.

Application group metadata, the registry and dashboard use `centralus`; the backend and storage use `eastus2`, matching the existing dev deployment. Production has its own registry, storage, app, dashboard and generated credentials. There is no provisioned VNet, dedicated node pool, paid log workspace or unused database service.

The existing backend uses SQLite. Both environments intentionally have one replica and one Uvicorn worker, with a brief interruption during backend deployment to avoid concurrent writers on Azure Files. The `prod` environment is isolated but is not a highly available database architecture. The Free dashboard tier has no production SLA. Registry, storage and the always-running backend incur Azure charges.

## One-time setup by the subscription Owner

The application groups are disposable. Terraform state and CI identities live separately in **`paiziq-infra`**, a small persistent management group. This extra management group is required by the chosen Azure state backend; cleanup never removes it. It holds the state storage account and two deployment identities, so destroying both application groups does not erase their state history or break authentication for recreation.

The current subscription is `8406cce0-3a67-4d8e-b536-965b930989af`, tenant `4a384267-1d1e-4008-b8ba-10d00c3b5f71`. On 2026-10-04 the ARM subscription API returned **Warned**, and the existing Container Apps cluster reported **ManagedClusterSuspended**. Azure CLI's cached `az account show` said Enabled, so it was not sufficient to establish that deployments were available. The signed-in user had Contributor access, which cannot grant CI roles. The Owner must restore the subscription and run bootstrap before live workflows can work. The previous trial quota also allowed only one Container Apps environment; the Owner must resolve that limit to run dev and prod together.

Install Azure CLI and GitHub CLI, log into both, then run this once from this repository:

```bash
az login --tenant 4a384267-1d1e-4008-b8ba-10d00c3b5f71
gh auth login
bash scripts/bootstrap.sh
```

The script checks the live subscription state and the signed-in user's Owner role before creating anything. It creates an encrypted, private Azure Blob state store, enables blob versioning and seven-day soft deletion, registers resource providers and configures passwordless GitHub OIDC authentication. It is repeatable. If the globally unique state account name is taken by another owner, rerun with `STATE_ACCOUNT=<unique-lowercase-name>`.

Bootstrap configures these nonsecret repository variables:

| Variable | Purpose |
| --- | --- |
| `AZURE_CLIENT_ID` | Persistent infrastructure identity client ID |
| `AZURE_TENANT_ID` | Azure tenant |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |
| `TF_STATE_STORAGE_ACCOUNT` | Persistent state storage account |
| `TF_STATE_CONTAINER` | `tfstate` |
| `SDK_CI_PRINCIPAL_ID` | Persistent SDK deployment identity principal ID |

The infrastructure identity gets subscription `Contributor`, `Role Based Access Control Administrator` and `AcrPush`, plus `Storage Blob Data Contributor` on the state container. These grants allow creating groups, managing environment-scoped roles, publishing bootstrap images, and using the OIDC backend. Limit write access to this infrastructure repository to trusted maintainers: its workflows have infrastructure and role-management privileges. GitHub environments `dev` and `prod` accept deployments only from `main`; Azure federated credentials trust those two repository/environment subjects.

Bootstrap also creates a persistent SDK CI identity in `paiziq-infra`, trusts the SDK repository's `main` branch, and updates that repository's Azure login variables. This replaces the old SDK deployment identity inside `paiziq-dev`, which would otherwise be deleted during cleanup. Terraform grants the new SDK identity Contributor on each application group and AcrPush on its registry. Until a spin-up workflow applies those assignments, SDK CI has no environment deployment access.

Terraform itself is not needed for bootstrap. Local infrastructure checks need Terraform **1.16.5** and Python **3.10+**. CI installs the pinned Terraform version. Provider versions and Linux/macOS checksums are committed in `.terraform.lock.hcl`.

## Spin up or adopt an environment

1. Run **Spin up dev** or **Spin up prod** from `main`.
2. The workflow checks the infrastructure code, builds/checks dashboard `main`, and builds/smoke-tests SDK `main` before changing Azure.
3. Matching existing resources are imported instead of duplicated. For the existing dev app, current ingest and Fernet keys are read directly from Azure into a mode-0600, ignored temporary file. The workflow refuses adoption if it cannot preserve both keys. Values are masked, never added to GitHub repository secrets, and the temporary file is removed afterward.
4. An intentional targeted apply creates the registry first, the actual backend image is pushed, then a full saved-plan apply creates/configures all resources. A plan that would delete or replace any existing resource fails for inspection. There is no automatic replacement of existing database storage.
5. Existing active backend revisions are stopped and their replicas must reach zero before the new revision starts. The dashboard is uploaded to the selected Static Web App. Hosted smoke checks verify health, rejection of missing/invalid API keys and dashboard CORS; the dashboard URL must serve successfully too.
6. The workflow summary provides the current dashboard, backend and `/health` URLs, and the exact source commits deployed.

Infrastructure spin-up deploys the current `main` of both public application repositories. Re-running spin-up updates the running apps as well as reconciling infrastructure; Terraform owns the app configuration and bootstrap image selection. Normal application pushes continue using the application repositories' existing CI pipelines. Do not run application deployments while a lifecycle workflow is operating: GitHub concurrency locks do not extend across repositories. Dev uses `paiziq-dev-env-recovery-eastus2` and `paiziq-ingest-dev-recovery`: the original Container Apps environment remained suspended after subscription reactivation. The old app is stopped; both environments are inside `paiziq-dev`, so cleanup removes them together.

After **dev recreation**, refresh the existing dashboard repository's deployment token using your local authorized Azure and GitHub logins:

```bash
bash scripts/configure-app-repos.sh
```

Static Web App API tokens and default hostnames can change when resources are recreated. The script pipes the new token directly into the dashboard repository secret without printing it. No GitHub admin PAT is stored in this infrastructure repository. This step is necessary because a repository's `GITHUB_TOKEN` cannot administer a different repository's secrets.

The SDK deployment helper discovers its live backend hostname and configured dashboard CORS origin after deploying. This repository's spin-up also uses live Terraform outputs, so recreation does not leave smoke checks pointing at deleted hostnames. Existing application workflows deploy to **dev**; this repository's prod spin-up deploys prod directly and does not silently change the application's promotion policy.

Runtime ingest/Fernet keys stay in Container Apps and sensitive Terraform state. A recreated environment gets fresh keys and an empty database; the prior sandbox login key will not work. Retrieve keys only through an authorized local Azure session. Connect the dashboard to the backend URL shown in the workflow summary. Infrastructure spin-up does not seed demos or customer data.

## Cleanup semantics

**Cleanup permanently deletes the selected environment's database, images, dashboard, backend and resource group, including resources created outside Terraform.** Export any data you intend to retain before running it.

Each cleanup uses that environment's remote state key (`dev.tfstate` or `prod.tfstate`), rejects state pointing at the other environment or subscription, and attempts `terraform destroy`. It then deletes the entire selected Azure resource group if anything remains, even if Terraform destroy failed. It polls Azure for up to 30 minutes and reports success only after Azure confirms that the group does not exist. Only then are remaining tracked state entries removed, including generated credentials, allowing a clean subsequent spin-up. An already-deleted group is handled idempotently.

If Azure denies deletion, a resource lock blocks it, Azure is unavailable, or the group remains at the deadline, the workflow **fails and preserves remaining state**. It does not claim cleanup succeeded. The opposite application's group and the persistent `paiziq-infra` management group are outside cleanup scope. State version history remains in the management store for recovery; it is not a backup of the application database.

## State and local validation

The AzureRM backend uses GitHub OIDC and Entra authentication, not storage account keys. Azure encrypts state at rest and access is restricted to authorized identities. State contains runtime secrets, so do not publish state files or saved plans as workflow artifacts. Dev/prod use separate blob keys and Terraform locking.

```bash
make check
# Optional additional workflow syntax check, with actionlint installed:
actionlint
```

Checks cover Terraform formatting/schema validation, mocked dev/prod plans, environment validation, cleanup recovery, deletion failures/timeouts, wrong-state protection, idempotence and refusal to overlap SQLite writers. They do not create or destroy Azure resources. Infrastructure files can be reviewed and validated while the subscription is suspended; successful live spin-up/cleanup still requires a working subscription and the bootstrap grants.

References: [AzureRM backend authentication](https://developer.hashicorp.com/terraform/language/backend/azurerm), [AzureRM resource group deletion behavior](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block), [Azure subscription states](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/subscription-states).
