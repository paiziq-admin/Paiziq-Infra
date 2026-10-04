import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("lifecycle", Path(__file__).resolve().parents[1] / "scripts/lifecycle.py")
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class FakeRunner:
    def __init__(self, fail_destroy=False, fail_delete=False, stuck=False, state_group="paiziq-dev"):
        self.calls = []
        self.fail_destroy = fail_destroy
        self.fail_delete = fail_delete
        self.stuck = stuck
        self.exists = True
        self.addresses = ["azurerm_resource_group.environment", "random_password.ingest"]
        self.state_group = state_group

    def __call__(self, *args, capture=False):
        self.calls.append(args)
        if args[:3] == ("terraform", "show", "-json"):
            return json.dumps({"values": {"root_module": {"resources": [{
                "type": "azurerm_resource_group", "values": {"name": self.state_group}}]}}})
        if args[:2] == ("terraform", "destroy"):
            if self.fail_destroy:
                raise RuntimeError("simulated Terraform failure")
            # Simulate unmanaged resources surviving a partial provider destroy.
            return ""
        if args[:3] == ("az", "group", "exists"):
            return json.dumps(self.exists)
        if args[:3] == ("az", "group", "delete"):
            if self.fail_delete:
                raise RuntimeError("simulated Azure access denial")
            self.exists = self.stuck
            return "{}"
        if args[:3] == ("terraform", "state", "list"):
            return "\n".join(self.addresses)
        if args[:3] == ("terraform", "state", "rm"):
            self.addresses = []
            return ""
        raise AssertionError(args)


class CleanupTests(unittest.TestCase):
    def test_deletes_unmanaged_resources_and_clears_state(self):
        fake = FakeRunner()
        lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertFalse(fake.exists)
        self.assertFalse(fake.addresses)
        operations = [call[:3] for call in fake.calls]
        self.assertLess(operations.index(("az", "group", "delete")), operations.index(("terraform", "state", "rm")))
        self.assertTrue(all("paiziq-prod" not in call for call in fake.calls))

    def test_recovers_from_failed_terraform_destroy(self):
        fake = FakeRunner(fail_destroy=True)
        lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertFalse(fake.exists)
        self.assertFalse(fake.addresses)

    def test_azure_delete_failure_retains_state_and_fails(self):
        fake = FakeRunner(fail_destroy=True, fail_delete=True)
        with self.assertRaises(RuntimeError):
            lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertTrue(fake.addresses)
        self.assertFalse(any(call[:3] == ("terraform", "state", "rm") for call in fake.calls))

    def test_timeout_retains_state(self):
        fake = FakeRunner(stuck=True)
        with self.assertRaisesRegex(RuntimeError, "still exists"):
            lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertTrue(fake.addresses)

    def test_already_deleted_group_is_idempotent(self):
        fake = FakeRunner(fail_destroy=True)
        fake.exists = False
        lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertFalse(any(call[:3] == ("az", "group", "delete") for call in fake.calls))
        self.assertFalse(fake.addresses)

    def test_wrong_state_rejected_before_any_mutation(self):
        fake = FakeRunner(state_group="paiziq-prod")
        with self.assertRaisesRegex(RuntimeError, "Wrong environment"):
            lifecycle.Lifecycle("dev", fake, lambda _: None).destroy()
        self.assertEqual(len(fake.calls), 1)

    def test_prod_cleanup_targets_only_prod(self):
        fake = FakeRunner(state_group="paiziq-prod")
        lifecycle.Lifecycle("prod", fake, lambda _: None).destroy()
        deletes = [call for call in fake.calls if call[:3] == ("az", "group", "delete")]
        self.assertEqual(deletes[0][deletes[0].index("--name") + 1], "paiziq-prod")
        self.assertTrue(all("paiziq-dev" not in call for call in fake.calls))

    def test_unknown_environment_rejected(self):
        with self.assertRaises(ValueError):
            lifecycle.Lifecycle("paiziq-infra")


class DeploymentTests(unittest.TestCase):
    def test_replacement_plan_is_rejected_before_stopping_backend(self):
        def run(*args, capture=False):
            if args[:3] == ("terraform", "show", "-json"):
                if len(args) == 3:
                    return "{}"
                return json.dumps({"resource_changes": [{"change": {"actions": ["delete", "create"]}}]})
            if args[:2] == ("terraform", "plan"):
                return ""
            raise AssertionError("Mutation must not run: " + str(args))
        with self.assertRaisesRegex(RuntimeError, "delete/replace"):
            lifecycle.Lifecycle("dev", run).apply()

    def test_refuses_apply_when_old_replica_does_not_stop(self):
        def run(*args, capture=False):
            if args[:3] == ("az", "group", "exists"):
                return "true"
            if args[:3] == ("az", "resource", "list"):
                return '[{"name":"paiziq-ingest-dev","type":"Microsoft.App/containerApps"}]'
            if args[:4] == ("az", "containerapp", "revision", "list"):
                return '[{"name":"old","properties":{"active":true}}]'
            if args[:4] == ("az", "containerapp", "revision", "deactivate"):
                return "{}"
            if args[:4] == ("az", "containerapp", "replica", "list"):
                return '[{"name":"still-writing"}]'
            raise AssertionError(args)
        with self.assertRaisesRegex(RuntimeError, "concurrent SQLite"):
            lifecycle.Lifecycle("dev", run, lambda _: None).stop_backend()


if __name__ == "__main__":
    unittest.main()
