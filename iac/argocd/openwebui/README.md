# openwebui

[Open WebUI](https://github.com/open-webui/open-webui) chat UI, deployed as a Helm chart via `../apps/openwebui.yaml`. `ClusterIP` Service, routed to by the in-cluster Traefik ingress controller (`templates/ingressroute.yaml`) via `HostRegexp` on the `openwebui.` subdomain prefix - reachable at `openwebui.<local_domain>` through the existing Traefik LXC (`reverse_proxy_sites.yml`), same pattern as `homepage`/`argocd`.

Migrated from the old `roles/open_webui_install` Docker Compose deployment on `gpu_host` - a deliberate fresh start, not a data migration (old chat history/accounts stayed behind on `gpu_host` and are not carried over). Ollama itself stays on `gpu_host` (GPU passthrough ties it there, outside this cluster) - this chart calls it over the LAN instead of localhost.

## The config Secret

Same pattern as `homepage/README.md`'s domain secret: this repo is public, so Ollama's real address, the Postgres connection string, and SeaweedFS credentials never live in a committed file. `templates/deployment.yaml` reads them all from one Secret named `openwebui-config` (`.Values.configSecretName`) via `envFrom` instead.

That Secret is sealed with [Sealed Secrets](https://github.com/bitnami/sealed-secrets) (`../apps/sealed-secrets.yaml` - install that first):

```sh
kubectl create secret generic openwebui-config \
  --namespace openwebui \
  --from-literal=OLLAMA_BASE_URL=http://<gpu_host-ip>:11434 \
  --from-literal=DATABASE_URL=postgresql://postgres:<postgres-password>@<rivendell-ip>:5432/openwebui \
  --from-literal=STORAGE_PROVIDER=s3 \
  --from-literal=S3_ENDPOINT_URL=http://<rivendell-ip>:8333 \
  --from-literal=S3_ACCESS_KEY_ID=<seaweedfs-access-key> \
  --from-literal=S3_SECRET_ACCESS_KEY=<seaweedfs-secret-key> \
  --from-literal=S3_BUCKET_NAME=openwebui \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
  > templates/openwebui-config-ss.yaml
```

The exact `S3_*`/`STORAGE_PROVIDER` env var names are Open WebUI's documented S3 storage config as of this chart's authoring - verify against [Open WebUI's env var docs](https://docs.openwebui.com/getting-started/env-configuration) before first deploy, this is a fast-moving project. Commit the resulting `templates/openwebui-config-ss.yaml` - it's ciphertext, safe to publish.

Before running the above:
- Create an `openwebui` database in Postgres and an `openwebui` bucket in SeaweedFS (via the `cloudbeaver` admin UI and SeaweedFS's filer UI, see `iac/ansible/roles/postgres_install`/`roles/seaweedfs_install`) - neither is created automatically.
- Argo CD's `CreateNamespace=true` (see `../apps/openwebui.yaml`) creates the `openwebui` namespace itself as part of the same sync, no manual `kubectl create namespace` step needed.

## Decommissioning the old install

Once this is confirmed working end-to-end, remove `open_webui_install` from `playbooks/gpu_services.yml`'s role list, then delete `iac/ansible/roles/open_webui_install/` - same "confirm before delete" caution as the Sealed Secrets migration to GitOps.
