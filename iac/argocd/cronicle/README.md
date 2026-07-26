# cronicle

[Cronicle](https://github.com/jhuckaby/Cronicle) job scheduler, deployed as a Helm chart via `../apps/cronicle.yaml`. `ClusterIP` Service, routed to by the in-cluster Traefik ingress controller (`templates/ingressroute.yaml`) via `HostRegexp` on the `cronicle.` subdomain prefix - reachable at `cronicle.<local_domain>` through the existing Traefik LXC, same pattern as `homepage`/`argocd`.

Runs here rather than on `rivendell` (the DB/bucket VM) deliberately: Cronicle's own state isn't irreplaceable the way the actual DB/bucket data is - losing it means redefining jobs, not losing data - and it's genuinely stateless once pointed at SeaweedFS for storage, which is exactly the profile that benefits from this cluster's GitOps/IngressRoute setup. See `docs/k3s-cluster-plan.md` for the full reasoning.

## The S3 Secret

Same pattern as `homepage/README.md`'s domain secret: this repo is public, so SeaweedFS's endpoint/credentials never live in a committed file. `templates/deployment.yaml`'s init container reads them from a Secret named `cronicle-s3` (`.Values.s3SecretName`) instead.

That Secret is sealed with [Sealed Secrets](https://github.com/bitnami/sealed-secrets) (`../apps/sealed-secrets.yaml` - install that first) rather than applied out-of-band:

```sh
kubectl create secret generic cronicle-s3 \
  --namespace cronicle \
  --from-literal=S3_ENDPOINT=http://<rivendell-ip>:8333 \
  --from-literal=S3_ACCESS_KEY=<seaweedfs-access-key> \
  --from-literal=S3_SECRET_KEY=<seaweedfs-secret-key> \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
  > templates/cronicle-s3-ss.yaml
```

Commit the resulting `templates/cronicle-s3-ss.yaml` - it's ciphertext, safe to publish. Argo CD's `CreateNamespace=true` (see `../apps/cronicle.yaml`) creates the `cronicle` namespace itself as part of the same sync, no manual `kubectl create namespace` step needed.

Before running the above, create a dedicated `cronicle` bucket in SeaweedFS (filer/admin UI, see `iac/ansible/roles/seaweedfs_install`) matching `values.yaml`'s `storage.bucket` - Cronicle doesn't create its own bucket.

## Backup jobs

The actual `pg_dump`/`mongodump`/S3 sync backup jobs are **not** committed anywhere in this repo - Cronicle stores job definitions in its own storage (SeaweedFS, per the Secret above), not files, so there's nothing to template. Define these once through Cronicle's web UI after it's deployed (Shell Script plugin, weekly schedule):

- **`pg_dump`**: `PGPASSWORD=<postgres-password> pg_dump -h <rivendell-ip> -U postgres -Fc <db> > /tmp/dump.sql && rsync /tmp/dump.sql <nas-server>:<nas-export>/postgres/`
- **`mongodump`**: `mongodump --uri="mongodb://<user>:<password>@<rivendell-ip>:27017" --archive=/tmp/dump.archive && rsync /tmp/dump.archive <nas-server>:<nas-export>/mongodb/`
- **S3 bucket backup**: `aws --endpoint-url http://<rivendell-ip>:8333 s3 sync s3://<bucket> <nas-server-mount-or-second-target>` (the AWS CLI works against any S3-compatible endpoint, not just AWS itself - no SeaweedFS-specific tooling needed)

Reaching the NAS is deliberately left to these runtime-defined job scripts (`rsync`/`ssh`, entered once via the UI) rather than a static NFS volume in `templates/deployment.yaml` - a k8s `nfs` volume's `server`/`path` fields can't be sourced from a Secret the way env vars can, so the only way to keep the NAS's real address out of this public repo is to keep it out of the committed manifests entirely, same reasoning as the domain/LAN-IP handling everywhere else in `iac/argocd/`.
