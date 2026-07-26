# Building a Technitium DNS Terraform/OpenTofu provider (Go learning project)

Not part of the homelab's critical path — the actual DNS record management already works via `iac/ansible/playbooks/dns_record.yml` (plain `ansible.builtin.uri` calls against Technitium's REST API, no external dependency). This doc is a self-contained plan for building a proper Terraform/OpenTofu provider as a way to learn Go, which could eventually replace that Ansible playbook with a native `technitium_record` resource if it turns out well.

## Why this is a reasonable first Go/provider project

- Small, well-defined surface: one resource type (`technitium_record`), a handful of fields, one upstream REST API.
- The API is simple HTTP + query params + bearer token — no gRPC, no complex auth flows, no pagination to fight with.
- Real, referenceable prior art exists to compare against once you have a working version: [kevynb/terraform-provider-technitium](https://github.com/kevynb/terraform-provider-technitium) is the most maintained of the existing (rough) community attempts. Worth reading *after* you've built your own first pass, not before — copying it defeats the point of the exercise.

## Prerequisites

- Go installed (`go version` — 1.21+ is safe for current tooling).
- Passing familiarity with Go syntax (structs, interfaces, error handling via returned `error` values, `context.Context`) — the Plugin Framework leans on all of these constantly, so this project doubles as a way to learn them by necessity rather than reading about them in the abstract first.

## The framework to use: `terraform-plugin-framework`

HashiCorp has two provider SDKs: the older `terraform-plugin-sdk/v2` and the newer `terraform-plugin-framework`. Use the **framework** — it's the actively-developed one, has better type safety (no more `interface{}` schemas), and is what HashiCorp points new providers at. OpenTofu is a compatible fork at the protocol level, so a provider built against either SDK works with `tofu` the same as `terraform` — nothing OpenTofu-specific to worry about.

## Step 1: Scaffold the project

HashiCorp publishes a template repo for exactly this:
```sh
git clone https://github.com/hashicorp/terraform-provider-scaffolding-framework technitium
```
Rename the module path (`go.mod`), the example resource, and the provider type name throughout. This gives you a working (if pointless) provider you can `go build` and load locally before writing any real logic — get this skeleton compiling and installable first, before touching the Technitium API at all.

## Step 2: Provider configuration schema

The provider block needs three fields:
```go
type TechnitiumProviderModel struct {
    Endpoint types.String `tfsdk:"endpoint"` // e.g. http://10.10.10.53:5380
    Token    types.String `tfsdk:"token"`
    Timeout  types.Int64  `tfsdk:"timeout"`  // optional, seconds
}
```
Support both explicit HCL config and environment variables (`TECHNITIUM_API_URL` / `TECHNITIUM_API_TOKEN`) — standard practice for provider auth, lets you keep the token out of `.tf` files the same way this repo already keeps other secrets out of committed config.

## Step 3: The `technitium_record` resource

Fields, matching Technitium's actual API (see `../iac/ansible/playbooks/dns_record.yml`'s comment for the authoritative endpoint reference, and Technitium's own docs: https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md):

| Field | Type | Notes |
|---|---|---|
| `domain` | string, required | the FQDN |
| `zone` | string, optional | defaults to closest match if omitted |
| `type` | string, required | start with just `"A"` support, add others later |
| `ip_address` | string, required for A/AAAA | |
| `ttl` | int, optional | |

Implement the four CRUD methods on the resource (`Create`, `Read`, `Update`, `Delete` in the framework's `resource.Resource` interface):

- **Create**: `POST /api/zones/records/add` with `overwrite=true`.
- **Read**: `GET /api/zones/records/get?domain=...` — parse the response, populate Terraform state. This is the one thing the Ansible approach *doesn't* do (it's fire-and-forget, no drift detection) — implementing Read properly is the main practical advantage a real provider gets you over the playbook.
- **Update**: Technitium's docs don't clearly document a dedicated update-in-place endpoint for individual records (only `add` with `overwrite=true`, which replaces the whole record set for that name+type). Confirm this by testing against a real Technitium instance once it's up — worth checking whether `add?overwrite=true` is sufficient for Update too, or whether you need a Delete-then-Create pair instead. This is a genuine open question in the upstream API, not something to guess at — test it directly.
- **Delete**: same caveat — a `/api/zones/records/delete`-style endpoint should exist (the web console can delete individual records), but wasn't clearly captured in what's fetchable from the docs at the time of writing. Confirm the exact parameters by testing against a live instance, or by inspecting the web console's own network requests (browser dev tools, Network tab, delete a record via the UI and see what it actually calls).

## Step 4: Local testing without publishing anything

You don't need to publish to any registry to use this provider in `iac/opentofu/`. Add a `dev_overrides` block to `~/.terraformrc` (works for `tofu` too):
```hcl
provider_installation {
  dev_overrides {
    "registry.terraform.io/yourname/technitium" = "/path/to/your/go/bin"
  }
  direct {}
}
```
`go build` your provider to that path, and `tofu plan`/`apply` will use your local binary directly — no version pinning, no lock file entry, fast iteration. This is the right way to develop and use a homegrown provider for personal infrastructure indefinitely; you never have to publish it if you don't want to.

## Step 5 (optional, later): acceptance tests

The framework's testing helpers (`resource.Test`, `TF_ACC=1` env var) spin up a real `tofu apply`/`destroy` cycle against a real backend per test. Needs a real (or disposable) Technitium instance to run against — worth doing once the resource is stable, not while you're still iterating on the basic shape.

## Suggested build order

1. Scaffold, get a no-op provider building and loading via `dev_overrides`.
2. Provider config (endpoint/token), a trivial data source (e.g. read Technitium's server version) to prove auth works end-to-end before touching records at all.
3. `technitium_record` Create + Read only — get `tofu apply` creating one real A record.
4. Update — resolve the open question above about whether `overwrite=true` suffices.
5. Delete.
6. Only then: consider whether to actually migrate `dns_record.yml`'s call sites in `iac/opentofu/*.tf` over to this instead of the Ansible provisioner — no rush, the Ansible path keeps working in the meantime.

## References

- [Terraform Plugin Framework docs](https://developer.hashicorp.com/terraform/plugin/framework)
- [Provider scaffolding template](https://github.com/hashicorp/terraform-provider-scaffolding-framework)
- [Technitium DNS Server API docs](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md)
- [kevynb/terraform-provider-technitium](https://github.com/kevynb/terraform-provider-technitium) — read after building your own first pass
