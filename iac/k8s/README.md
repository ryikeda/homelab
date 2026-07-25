# k8s manifests

GitOps manifests for the k3s cluster (`gondor`/`rohan`/`shire`), reconciled by Argo CD running in-cluster (`iac/ansible/playbooks/argocd_install.yml`). See `docs/k3s-cluster-plan.md` for the full cluster design.

Argo CD's destination for everything here is `in-cluster` - it's managing the same cluster it runs in, no external kubeconfig/Secret needed.

## Adding a workload

1. Add manifests (or a Helm values file) under a new subdirectory here.
2. Declare an Argo CD `Application` resource pointing at that path, `destination.server: https://kubernetes.default.svc`.
3. Commit - Argo CD reconciles automatically. No Ansible role needed for the workload itself.
