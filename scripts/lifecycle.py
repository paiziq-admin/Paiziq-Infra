#!/usr/bin/env python3
"""Environment lifecycle. No shell interpolation and no secret-bearing output."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = {name: f"paiziq-{name}" for name in ("dev", "prod")}
SECRET_FILE = ROOT / ".adopted.auto.tfvars.json"


class Runner:
    def __call__(self, *args, capture=False):
        result = subprocess.run(args, cwd=ROOT, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
        if result.returncode:
            # Captured commands can contain secrets; never echo their output.
            raise RuntimeError(f"{' '.join(args[:3])} failed (exit {result.returncode})")
        return result.stdout.strip() if capture else ""


class Lifecycle:
    def __init__(self, environment, run=None, sleep=time.sleep):
        if environment not in ENVIRONMENTS:
            raise ValueError("Only dev and prod are supported")
        self.environment = environment
        self.group = ENVIRONMENTS[environment]
        self.run = run or Runner()
        self.sleep = sleep
        self.varfile = f"-var-file=environments/{environment}.tfvars.json"

    def az(self, *args):
        return self.run("az", *args, "--only-show-errors", "--output", "json", capture=True)

    def exists(self):
        value = json.loads(self.az("group", "exists", "--name", self.group))
        if type(value) is not bool:
            raise RuntimeError("Azure returned an invalid resource group existence response")
        return value

    def verify_state(self):
        """Reject a misconfigured backend containing the opposite environment."""
        state = json.loads(self.run("terraform", "show", "-json", capture=True))
        def resources(module):
            yield from module.get("resources", [])
            for child in module.get("child_modules", []):
                yield from resources(child)
        for resource in resources(state.get("values", {}).get("root_module", {})):
            if not resource["type"].startswith("azurerm_"):
                continue
            values = resource.get("values", {})
            group = values.get("resource_group_name")
            if resource["type"] == "azurerm_resource_group":
                group = values.get("name")
            arm_id = str(values.get("id", "")).lower()
            scope = str(values.get("scope", "")).lower()
            subscription = os.environ.get("ARM_SUBSCRIPTION_ID")
            for identifier in (arm_id, scope):
                if (subscription and identifier.startswith("/subscriptions/")
                        and not identifier.startswith(f"/subscriptions/{subscription.lower()}/")):
                    raise RuntimeError("Wrong subscription in Terraform state; refusing any mutation")
                if "/resourcegroups/" in identifier and f"/resourcegroups/{self.group.lower()}/" not in identifier + "/":
                    raise RuntimeError("Wrong environment in Terraform state; refusing any mutation")
            if (group and group != self.group) or (
                "/resourcegroups/" in arm_id and
                f"/resourcegroups/{self.group.lower()}/" not in arm_id + "/"
            ):
                raise RuntimeError("Wrong environment in Terraform state; refusing any mutation")

    def destroy(self):
        self.verify_state()
        terraform_failed = False
        try:
            self.run("terraform", "destroy", "-auto-approve", "-input=false", self.varfile)
        except RuntimeError:
            terraform_failed = True
            print("Terraform destroy failed; attempting deletion of the entire selected group.", flush=True)
        # This also removes resources that were created outside Terraform.
        if self.exists():
            self.az("group", "delete", "--name", self.group, "--yes", "--no-wait")
        for _ in range(180):
            if not self.exists():
                break
            self.sleep(10)
        else:
            raise RuntimeError(f"{self.group} still exists; preserving state and failing cleanup")
        # Removal of state is safe ONLY after Azure has confirmed group deletion.
        addresses = self.run("terraform", "state", "list", capture=True).splitlines()
        if addresses:
            self.run("terraform", "state", "rm", *addresses)
        # Fail if state cannot actually be cleared; do not claim a clean lifecycle.
        if self.run("terraform", "state", "list", capture=True):
            raise RuntimeError("Group deleted, but environment state still contains resources")
        print(f"Verified: {self.group} deleted; environment state is empty."
              + (" Recovered from Terraform destroy failure." if terraform_failed else ""), flush=True)

    def adopt(self):
        self.verify_state()
        if not self.exists():
            return
        subscription = os.environ["ARM_SUBSCRIPTION_ID"]
        base = f"/subscriptions/{subscription}/resourceGroups/{self.group}"
        registry = f"paiziq{self.environment}acr8406cce0"
        storage = "paiziqdevdata8406cce02" if self.environment == "dev" else "paiziqproddata8406cce0"
        env = f"paiziq-{self.environment}-env-eastus2"
        app = f"paiziq-ingest-{self.environment}"
        items = json.loads(self.az("resource", "list", "--resource-group", self.group))
        ids = {item["id"].lower(): item["id"] for item in items}
        app_id = f"{base}/providers/Microsoft.App/containerApps/{app}"
        if app_id.lower() in ids:
            # Retrieve existing runtime secrets on EVERY apply. Never rotate an
            # encryption key while retaining its encrypted SQLite database.
            secret_items = json.loads(self.az("containerapp", "secret", "list", "--name", app,
                                             "--resource-group", self.group, "--show-values"))
            secrets = {item["name"]: item.get("value") for item in secret_items}
            if not secrets.get("ingest-keys"):
                raise RuntimeError("Cannot preserve the existing ingest keys; refusing adoption")
            # If an existing service has no Fernet key, require manual inspection
            # rather than inventing one and risking encrypted records.
            if not secrets.get("secrets-key"):
                raise RuntimeError("Cannot preserve the existing encryption key; inspect before adoption")
            if os.environ.get("GITHUB_ACTIONS") == "true":
                for value in (secrets["ingest-keys"], secrets["secrets-key"]):
                    escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                    print(f"::add-mask::{escaped}")
            descriptor = os.open(SECRET_FILE, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w") as output:
                json.dump({"existing_ingest_keys": secrets["ingest-keys"],
                           "existing_secrets_key": secrets["secrets-key"]}, output)
        mappings = {
            "azurerm_resource_group.environment": base,
            "azurerm_container_registry.backend": f"{base}/providers/Microsoft.ContainerRegistry/registries/{registry}",
            "azurerm_storage_account.data": f"{base}/providers/Microsoft.Storage/storageAccounts/{storage}",
            "azurerm_container_app_environment.backend": f"{base}/providers/Microsoft.App/managedEnvironments/{env}",
            "azurerm_static_web_app.dashboard": f"{base}/providers/Microsoft.Web/staticSites/paiziq-dashboard-{self.environment}",
            "azurerm_container_app.backend": app_id,
            "azurerm_user_assigned_identity.pull": f"{base}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/paiziq-{self.environment}-registry-pull",
        }
        ids[base.lower()] = base
        account_id = mappings["azurerm_storage_account.data"]
        if account_id.lower() in ids:
            shares = json.loads(self.az("storage", "share-rm", "list", "--resource-group", self.group,
                                       "--storage-account", storage))
            for share in shares:
                if share["name"] == "paiziq-ingest-data":
                    sid = f"{account_id}/fileServices/default/shares/paiziq-ingest-data"
                    ids[sid.lower()] = sid
                    mappings["azurerm_storage_share.data"] = sid
        env_id = mappings["azurerm_container_app_environment.backend"]
        if env_id.lower() in ids:
            mounts = json.loads(self.az("containerapp", "env", "storage", "list", "--name", env,
                                       "--resource-group", self.group))
            for mount in mounts:
                if mount["name"] == "paiziq-data":
                    mid = f"{env_id}/storages/paiziq-data"
                    ids[mid.lower()] = mid
                    mappings["azurerm_container_app_environment_storage.data"] = mid
        # Import matching RBAC assignments when recovering lost state.
        roles = json.loads(self.az("role", "assignment", "list", "--resource-group", self.group,
                                  "--all"))
        pull = next((i.get("identity", {}).get("principalId") or i.get("properties", {}).get("principalId")
                     for i in items if i["id"].lower() == mappings["azurerm_user_assigned_identity.pull"].lower()), None)
        if not pull and mappings["azurerm_user_assigned_identity.pull"].lower() in ids:
            identity = json.loads(self.az("identity", "show", "--name", f"paiziq-{self.environment}-registry-pull",
                                          "--resource-group", self.group))
            pull = identity["principalId"]
        sdk = os.environ.get("TF_VAR_sdk_ci_principal_id")
        for address, principal, role, scope in (
            ("azurerm_role_assignment.pull", pull, "AcrPull", mappings["azurerm_container_registry.backend"]),
            ("azurerm_role_assignment.sdk_push[0]", sdk, "AcrPush", mappings["azurerm_container_registry.backend"]),
            ("azurerm_role_assignment.sdk_deploy[0]", sdk, "Contributor", base),
        ):
            matches = [r for r in roles if r.get("principalId") == principal and principal
                       and r.get("roleDefinitionName") == role and r.get("scope", "").lower() == scope.lower()]
            if matches:
                mappings[address] = matches[0]["id"]
                ids[matches[0]["id"].lower()] = matches[0]["id"]
        tracked = set(self.run("terraform", "state", "list", capture=True).splitlines())
        for address, arm_id in mappings.items():
            if address not in tracked and arm_id.lower() in ids:
                self.run("terraform", "import", "-input=false", self.varfile, address, ids[arm_id.lower()])

    def apply(self, foundation=False):
        self.verify_state()
        plan = ROOT / "environment.tfplan"
        args = ["terraform", "plan", "-input=false", self.varfile, f"-out={plan}"]
        if foundation:
            args += ["-target=azurerm_container_registry.backend"]
        self.run(*args)
        data = json.loads(self.run("terraform", "show", "-json", str(plan), capture=True))
        if any("delete" in change["change"]["actions"] for change in data.get("resource_changes", [])):
            raise RuntimeError("Spin-up would delete/replace an existing resource; refusing apply. Inspect drift first.")
        if not foundation:
            self.stop_backend()
        self.run("terraform", "apply", "-input=false", str(plan))
        plan.unlink(missing_ok=True)

    def stop_backend(self):
        if not self.exists():
            return
        app = f"paiziq-ingest-{self.environment}"
        items = json.loads(self.az("resource", "list", "--resource-group", self.group))
        if not any(i["name"] == app and i["type"].lower() == "microsoft.app/containerapps" for i in items):
            return
        revisions = json.loads(self.az("containerapp", "revision", "list", "--name", app,
                                       "--resource-group", self.group))
        for revision in revisions:
            if not revision.get("properties", {}).get("active"):
                continue
            name = revision["name"]
            self.az("containerapp", "revision", "deactivate", "--name", app,
                    "--resource-group", self.group, "--revision", name)
            for _ in range(60):
                replicas = json.loads(self.az("containerapp", "replica", "list", "--name", app,
                                              "--resource-group", self.group, "--revision", name))
                if not replicas:
                    break
                self.sleep(2)
            else:
                raise RuntimeError("Old replicas remain; refusing concurrent SQLite writers")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=["adopt", "foundation", "apply", "destroy"])
    parser.add_argument("environment", choices=ENVIRONMENTS)
    args = parser.parse_args()
    lifecycle = Lifecycle(args.environment)
    try:
        if args.operation == "foundation":
            lifecycle.apply(foundation=True)
        else:
            getattr(lifecycle, args.operation)()
    finally:
        # Other workflow steps need adoption overrides until the full apply.
        if args.operation in ("apply", "destroy"):
            SECRET_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
