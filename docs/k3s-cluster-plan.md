# k3s Cluster

Phase 1 (the cluster itself) is built and applied - `gondor`/`rohan`/`shire` are up and `Ready`. Phase 2 (Argo CD) is built, not yet applied. See `docs/roadmap.md` step 6.

## Context

The homelab roadmap's step 6 has always called for a k3s cluster ("N VMs (control plane + workers) cloned in a loop from the VM template, then bootstrapped with k3s. Node count/sizing decided once earlier steps are working") but nothing's been built yet.

Planning this out started with a Rancher hub-and-spoke design (a dedicated Rancher VM managing a separate registered "prod" cluster, matching the Portainer/gpu-box precedent). Revisited and simplified after weighing it against the actual goals:

- **Single physical Proxmox host.** Every node here is a VM on the same box - Rancher's multi-cluster management value (and k8s HA generally) doesn't buy real fault isolation at this hardware scale; a host failure takes everything down regardless of cluster topology.
- **Only one cluster planned.** Rancher's hub-and-spoke pitch is managing *multiple* downstream clusters from one pane of glass. With a single "prod" cluster, that's a whole extra VM (4 cores/8GB for Rancher + cert-manager alone) paying for a capability that isn't in use yet.
- **Explicit goal: learn k8s.** This tipped the sizing decision back toward a real multi-node cluster (control-plane + 2 workers) rather than the leanest possible single-node setup - node-level scheduling, taints/tolerations, drain/cordon, and join/leave mechanics are exactly the operational skills a single-node cluster skips. Rancher itself didn't survive the same reasoning: it's a vendor UI/multi-cluster-provisioning layer, not core k8s knowledge, so it's deferred rather than built up front. Nothing about skipping it now forecloses adding it later - Rancher can *import* an existing cluster, not just provision one from scratch.

Decided architecture:

- **OS: Ubuntu** everywhere (not Talos) - stays consistent with the rest of the SSH/Ansible-managed fleet.
- **Single cluster, no hub**: one "prod" k3s cluster, 1 control-plane + 2 workers, no HA. Ansible installs k3s directly (official `get.k3s.io` script, version-pinned) - the control-plane node generates a join token, workers install as agents pointed at it. No Rancher registration flow, no separate cluster-management VM.
- **Argo CD runs in-cluster on prod** (Phase 2, not built yet) - installed via Helm directly onto the cluster it manages, targeting `https://kubernetes.default.svc` ("in-cluster") as its destination. This is Argo CD's default, most common deployment shape - the external-cluster/hub-and-spoke registration pattern only earns its complexity once there's a second cluster to fan out to. GitOps app manifests will live at `iac/argocd/` in this repo (monorepo, not a separate repo).
- **Fully declarative where possible**: OpenTofu creates the VMs (explicit `vm_id`, static IP, `type = "host"`), Ansible drives the k3s install and (later) Argo CD's Helm install - no manual UI steps beyond what's unavoidable (see Explicitly deferred).
- **Tolkien theme, continuing `palantir`'s lead**: nodes are named `gondor` (control-plane), `rohan`/`shire` (workers) - standalone names, no `k3s-` prefix, same convention as `palantir`/`technitium`. The `k3s` inventory group (with `prod_control_plane`/`prod_workers` children) is what ties them together functionally.

Current host budget: 28 cores / 125GB total, ~13 cores / 30.5GB already committed (gpu-box/palantir/portainer/technitium/traefik) → ~15 cores / ~94GB free.

## VMIDs, IPs, sizing

Per the VMID convention (`iac/opentofu/README.md`, 300-399 reserved as one contiguous block for this cluster) and the static-IP block (`.51`-`.56` taken, DHCP starts at `.100`):

| VMID | Name | IP | Role | cores (`type=host`) | mem (dedicated/floating) | disk |
|---|---|---|---|---|---|---|
| 300 | `gondor` | `10.10.10.57/24` | control-plane | 2 | 4096/1024 MB | 20GB |
| 301 | `rohan` | `10.10.10.58/24` | worker | 2 | 8192/2048 MB | 40GB |
| 302 | `shire` | `10.10.10.59/24` | worker | 2 | 8192/2048 MB | 40GB |

Total: 6 cores / 20GB - leaves ~9 cores / ~74GB free. Control-plane stays minimal (just k3s server + Argo CD's control-plane pods); workers sized for actual workloads (Immich, Paperless, DBs).

k3s version: **`v1.34.9+k3s1`** (verified against k3s-io/k3s releases - latest overall is `v1.36.2+k3s1`, 1.34 is the more conservative/proven line for less to troubleshoot blind).

## Phase 1 - Prod cluster (built, not yet applied)

**OpenTofu** (`iac/opentofu/vm_k3s_prod.tf`):
- Three explicit resource blocks (`gondor`, `rohan`, `shire`) - same fully-spelled-out style as every other VM in this repo (no `for_each`; nothing here precedent exists for it, and three near-identical blocks reads more consistently with `vm_gpu_box.tf`/`vm_palantir.tf`/`vm_technitium.tf` than introducing a loop for two items would). `type = "host"`, static IP, explicit `vm_id`, reuses the shared `gpu_box_vendor_data` snippet.
- Each VM's `local-exec` provisioner: wait for SSH, refresh `known_hosts`, `bootstrap.yml --limit <name>`, `dns_records.yml`, then `k3s_cluster.yml` with a `--limit` that always includes `gondor` (e.g. `gondor:rohan`) so the join-token handoff (below) works within that single run.
- **Ordering**: `rohan`/`shire` both set `depends_on = [proxmox_virtual_environment_vm.gondor]` - the control-plane must exist and have generated its join token before a worker's own provisioner run tries to read it.

**Ansible**:
- `group_vars/kubernetes.yml` - shared connection vars + `k3s_version`, same shape as `gpu.yml`. `hosts.yml` has a `kubernetes` group with `prod_control_plane`/`prod_workers` children (named generically so it stays accurate if a future second cluster uses a different distro).
- `roles/k3s_install/`:
  - Common prereqs on every node: swap off (`swapoff -a` + stripped from `/etc/fstab`), `overlay`/`br_netfilter` kernel modules loaded and persisted, sysctls (`net.ipv4.ip_forward`, `net.bridge.bridge-nf-call-iptables`/`ip6tables`) via `ansible.posix.sysctl`.
  - Install is version-pinned and idempotent - `k3s --version`'s output checked against `k3s_version` before reinstalling, same idiom as `node_exporter_install`'s marker-file check.
  - Control-plane (`k3s-install.sh server --write-kubeconfig-mode 644 --disable traefik --disable servicelb`) - traefik/servicelb disabled so the existing standalone Traefik LXC stays the one ingress path, not k3s's bundled ones.
  - Workers: the control-plane play slurps `/var/lib/rancher/k3s/server/node-token` into a fact; the workers play (same run, control-plane play first) reads it via `hostvars[groups['prod_control_plane'][0]]['k3s_node_token']` for `K3S_TOKEN` (`no_log: true` on that task).
- `playbooks/k3s_cluster.yml` wraps this: one play for `prod_control_plane`, one for `prod_workers`, in that order.

**Kubeconfig**: not automated - pull it from `/etc/rancher/k3s/k3s.yaml` on `gondor` once it's up (`ssh ansible@gondor.<local_domain> sudo cat /etc/rancher/k3s/k3s.yaml`), substituting `127.0.0.1` for `gondor`'s real IP before using it remotely.

**DNS**: `gondor`, `rohan`, `shire` all have `dns_records.yml` entries, same declarative pattern as every other host.

**Fleet playbooks**: `k3s` added to `bootstrap.yml`/`health.yml`/`updates.yml`/`maintenance.yml`/`monitoring.yml`'s node_exporter play. Not added to `reboot.yml`/`shutdown.yml` yet (no drain/cordon logic).

## Phase 2 - Argo CD, in-cluster (built, not yet applied)

`playbooks/argocd_install.yml` (new `roles/argocd_install/`), run against `prod_control_plane` (`gondor`):

- Installs Helm itself first (version-pinned, `4.2.3`, same tarball-download + version-marker idiom as `node_exporter_install`), then `helm upgrade --install` for the `argo/argo-cd` chart (pinned `10.2.1`, appVersion `v3.4.5`) into the `argocd` namespace, using `gondor`'s own `/etc/rancher/k3s/k3s.yaml` as `KUBECONFIG` - no separate credential needed since it's running on the cluster it's managing.
- Default "in-cluster" destination - no external kubeconfig/Secret plumbing needed.
- `Application` resources will target `in-cluster` as their `destination`. Manifests live at `iac/argocd/` in this repo (has its own README), monorepo-style.
- "Add a workload" becomes a git commit to `iac/argocd/`, not a new Ansible role.
- **`argocd.{{ local_domain }}` via the existing Traefik LXC**, not port-forward - initially a fixed NodePort (`server.service.type=NodePort`, `nodePortHttps=30443`), superseded in Phase 3 below by MetalLB + an in-cluster ingress controller once a second NodePort service (homepage) made the "one or two NodePort services" stopgap start to hurt. Admin password still pulled manually: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- No workload/`Application` created yet - nothing decided to deploy (Immich/Paperless/etc. still TBD).

## Phase 3 - MetalLB + in-cluster Traefik ingress (built)

Two NodePort services (Argo CD, homepage) hit the exact stopgap the TODOs in `argocd_install`/`homepage` called out - a real port collision, and Traefik's upstream hardcoded to `gondor` specifically, no failover if it goes down.

- `playbooks/metallb_install.yml` (new `roles/metallb_install/`) installs MetalLB (L2/ARP mode - no BGP router here) and an `IPAddressPool`/`L2Advertisement` pair from `metallb_install_ip_range` (`local.yml`, real LAN range, gitignored).
- `iac/argocd/apps/ingress-controller.yaml` deploys Traefik in-cluster via GitOps, referencing the upstream chart directly (not a local chart, like `argocd`/`sealed-secrets` below). Gets exactly **one** MetalLB IP - new workloads register an `IngressRoute` instead of a new NodePort/LXC entry each. The IP itself is deliberately not pinned via a committed annotation (would leak the real LAN IP in a public repo) - MetalLB auto-assigns it, and it's recorded manually as `k8s_ingress_lb_ip` in `local.yml`.
- Both `argocd-server` and `homepage`'s `IngressRoute`s match `HostRegexp` on their subdomain prefix (e.g. `^homepage\..+$`) rather than the literal hostname, since the real domain can't be committed - the LXC already preserves the original `Host` header when forwarding, so this still routes correctly.
- Argo CD switched from NodePort to `ClusterIP` + `configs.params."server\.insecure"=true` (LXC already terminates real TLS at the edge, so no self-signed backend leg left to `insecure_skip_verify` on).
- Sealed Secrets moved from Ansible (`sealed_secrets_install`) to GitOps (`iac/argocd/apps/sealed-secrets.yaml`) in the same pass - no bootstrap dependency, clean fit for the workload pattern. Argo CD itself stays Ansible-installed (deliberate "break glass" choice - self-managing Argo CD risks a bad change breaking the tool that would fix it).

## Explicitly deferred

- **Rancher** - no longer part of the initial build. Adopt later via Rancher's "import existing cluster" flow if/when there's a second cluster to justify a management plane, or if the UI itself becomes independently useful. Doesn't require having provisioned differently from the start.
- **Storage beyond k3s's bundled `local-path-provisioner`** on prod - default fine until real stateful workloads exist.
- **Reboot/shutdown fleet integration** - once drain/cordon logic exists.
- **HA for the control-plane** - single point of failure accepted at homelab scale (moot anyway on one physical host); revisit if this ever needs to be more production-like.

## Verification

Phase 1 - done:

1. ~~`tofu plan`/`apply` - expect **3 to add** (`gondor`, `rohan`, `shire`).~~ Applied.
2. ~~`kubectl get nodes` shows all 3 `Ready`.~~ Confirmed - all 3 `Ready`, correct roles.
3. `dig` all 3 DNS records against Technitium (`10.10.10.53`) - resolve correctly.
4. On each node: `free -h` shows 0 swap, `sysctl net.ipv4.ip_forward` = 1, `br_netfilter` loaded.
5. Re-run `tofu apply` - expect **0 to add/change**.
6. `ansible-playbook playbooks/health.yml --limit kubernetes` - confirms all 3 nodes are cleanly onboarded into existing fleet ops tooling.

Phase 2 - when applied:

7. `ansible-playbook playbooks/argocd_install.yml` completes; `kubectl -n argocd get pods` shows the Argo CD components `Running`.
8. Port-forward (`kubectl -n argocd port-forward svc/argocd-server 8080:443`) and log in with the initial admin secret - UI reachable, empty/clean state ready for the first real `Application`.
9. Re-run `ansible-playbook playbooks/argocd_install.yml` - idempotent, no unexpected changes (Helm release stays at the pinned chart version).
