# Argo CD manifests

GitOps manifests for the k3s cluster (`gondor`/`rohan`/`shire`), reconciled by Argo CD running in-cluster (`iac/ansible/playbooks/argocd_install.yml`). See `docs/k3s-cluster-plan.md` for the full cluster design.

Argo CD's destination for everything here is `in-cluster` - it's managing the same cluster it runs in, no external kubeconfig/Secret needed. Repo is public, so Argo CD pulls it over plain HTTPS - no deploy key/credentials to manage.

`root.yaml` is the one-time bootstrap - applied once by hand (`kubectl apply -f iac/argocd/root.yaml`), it's an `Application` that watches `apps/` and auto-applies whatever shows up there (`syncPolicy.automated`, `prune`/`selfHeal` on). Everything after that first apply is pure GitOps.

## Adding a workload

Each workload is its own local Helm chart (see `homepage/` for the shape: `Chart.yaml`, `values.yaml`, `templates/`) - Argo CD auto-detects a `Chart.yaml` at a source path and treats it as Helm, no explicit config needed. Plain manifests without a `Chart.yaml` work too (Argo CD falls back to applying them directly), but the chart shape keeps operational bits (image tag, replicas, ports) out of hardcoded values and in one place (`values.yaml`).

1. Add a chart under a new subdirectory here (`templates/` for the manifests, `values.yaml` for anything that should be parameterized - never real secrets/domains, this repo is public).
2. Add a file under `apps/` - an Argo CD `Application` resource pointing at that subdirectory.
3. Commit - `root.yaml`'s automated sync picks it up (polls by default, no webhook - this cluster isn't publicly reachable yet). No Ansible role, no manual `kubectl`/`argocd` command needed for the workload itself.

**Keeping secrets out of git**: this repo is public. Anything sensitive (API keys, the actual domain, credentials) goes through [Sealed Secrets](https://github.com/bitnami/sealed-secrets) (`iac/ansible/playbooks/sealed_secrets_install.yml`) - encrypt with `kubeseal`, commit the resulting `SealedSecret` (ciphertext, safe to publish), reference the real Secret it decrypts to from the chart via `valueFrom: secretKeyRef`. Never a plain `Secret` or a real value in `values.yaml`/`templates/`. See `homepage/README.md` for a worked example.

## Linting

`.github/workflows/ci.yml` runs `helm lint` on every chart under this directory plus `yamllint` on the plain manifests (`root.yaml`, `apps/*.yaml`, each chart's `Chart.yaml`/`values.yaml` - `templates/` is excluded, since Helm's Go-template syntax isn't valid YAML on its own). Run the same checks locally with `helm lint <chart-dir>` and `yamllint -c .yamllint .`.
