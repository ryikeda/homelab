# homepage

[Homepage](https://gethomepage.dev/) dashboard, deployed as a Helm chart via `../apps/homepage.yaml`. `ClusterIP` Service, routed to by the in-cluster Traefik ingress controller (`templates/ingressroute.yaml`, `../apps/ingress-controller.yaml`) via `HostRegexp` on the `homepage.` subdomain prefix - reachable at `homepage.<local_domain>` through the existing Traefik LXC (`reverse_proxy_sites.yml`), which forwards to the ingress controller's MetalLB IP.

## The domain Secret

This repo is public - the real domain doesn't live in any committed file. `templates/deployment.yaml` reads it from a Secret named `homepage-domain` instead.

That Secret is sealed with [Sealed Secrets](https://github.com/bitnami/sealed-secrets) (`iac/argocd/apps/sealed-secrets.yaml` - install that first) rather than applied out-of-band: encrypt it once with `kubeseal`, commit the encrypted `SealedSecret` to git, and the in-cluster controller decrypts it back into a real Secret. Only the controller's private key (never leaves the cluster) can do that, so the committed file is safe in a public repo.

```sh
kubectl create secret generic homepage-domain \
  --namespace homepage \
  --from-literal=domain=<your-actual-domain> \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
  > templates/homepage-domain-ss.yaml
```

`--dry-run=client` is purely local object generation - the `homepage` namespace doesn't need to exist yet for this to work. Commit the resulting `templates/homepage-domain-ss.yaml` - it's ciphertext, safe to publish. Argo CD's `CreateNamespace=true` (see `../apps/homepage.yaml`) creates the namespace itself as part of the same sync that applies this manifest and the rest of the chart - no manual `kubectl create namespace` step needed.

The chart wires that Secret into two places: Homepage's own `{{HOMEPAGE_VAR_DOMAIN}}` substitution inside `services.yaml` (in `templates/configmap.yaml`), and `HOMEPAGE_ALLOWED_HOSTS` in `templates/deployment.yaml` via Kubernetes' own `$(VAR)` env-var interpolation.
