# sentry-k8s

A self-contained Helm chart for **Sentry self-hosted** on Kubernetes, with a
**first-class bundled ClickHouse** (no external provisioning) and every required service wired up. One `helm install` brings up the whole stack.

## Why this chart

- **Pulumi- & Terraform-friendly — no Helm hooks.** Initialization (DB
  migrations, Kafka topics, superuser) runs as a plain Kubernetes `Job` with
  sequential init containers, **not** Helm lifecycle hooks. This matters:
  - Pulumi's `k8s.helm.v3.Chart` renders templates client-side and **silently
    drops `helm.sh/hook` resources** — so hook-based DB init in other Sentry
    charts simply never runs.
  - Terraform's `helm_release` does run hooks, but hook Jobs cause apply
    timeouts and state drift, so teams routinely disable them.

  Every object this chart emits is a first-class resource Pulumi and Terraform
  can see, diff, and manage. (The only `helm.sh/hook` usage is the `helm test`
  pods, which are CLI-only and never applied on install/upgrade.)
- **Bundled ClickHouse**, single-node by default, HA (sharding/replication +
  ClickHouse Keeper) opt-in — no operator or CRDs.
- **Plain Kubernetes only.** No Contour `HTTPProxy`, cert-manager, or
  oauth2-proxy in the chart. It emits Deployments, StatefulSets, Services,
  ConfigMaps, Secrets, Jobs, CronJobs, PVCs, and an optional `networking.k8s.io/v1`
  Ingress. TLS/auth/DNS stay external, pointed at the chart's single nginx
  ClusterIP.
- **Good defaults + full configurability** for every component (resources,
  probes, `nodeSelector`, `affinity`, `tolerations`, autoscaling).

See [ARCHITECTURE.md](./ARCHITECTURE.md) for what each component does and how
requests/data flow through the system.

## Install

The chart is published as an **OCI artifact** to GitHub Container Registry.

```bash
helm install sentry oci://ghcr.io/sprisa/sentry-k8s --version 0.1.0 \
  --namespace sentry --create-namespace \
  --set sentry.system.url=https://sentry.example.com \
  --set user.email=admin@example.com \
  --set user.password=changeme-please \
  --set global.storageClass=longhorn
```

Browse available versions: `helm show chart oci://ghcr.io/sprisa/sentry-k8s`.

Use a profile preset (recommended over `--set` for anything non-trivial):

```bash
curl -fsSLO https://raw.githubusercontent.com/sprisa/sentry-k8s/main/examples/values-feature-complete.yaml
helm install sentry oci://ghcr.io/sprisa/sentry-k8s --version 0.1.0 \
  -n sentry --create-namespace -f values-feature-complete.yaml
```

> **Pulumi / Terraform** consume the same OCI URL directly — see
> [Using it from Pulumi](#using-it-from-pulumi) and
> [Using it from Terraform](#using-it-from-terraform).

The bootstrap `Job` runs migrations with no hooks. On a fresh install some app
pods may restart a few times until it finishes — this is expected (see
[Initialization without Helm hooks](./ARCHITECTURE.md#initialization-without-helm-hooks)).

Reach the UI through the bundled nginx proxy:

```bash
kubectl -n sentry port-forward svc/sentry-nginx 8080:80
# open http://localhost:8080
```

Point your own Ingress / Contour `HTTPProxy` / load balancer at the
`sentry-nginx` Service (port 80).

## Profile presets

`sentry.profile` sets the default `enabled` state for every component. Each
component also has its own `enabled` flag, so you can build intermediate sets.

| Preset | `sentry.profile` | What runs | Example values |
| --- | --- | --- | --- |
| **Errors only** (default, lightweight) | `errors-only` | Error tracking: web, relay, snuba errors/outcomes, taskbroker, ingest-events/attachments, cleanup | [`examples/values-errors-only.yaml`](./examples/values-errors-only.yaml) |
| **Errors + transactions** | `errors-only` + toggles | Adds the performance/tracing pipeline | [`examples/values-errors-transactions.yaml`](./examples/values-errors-transactions.yaml) |
| **Feature complete** | `feature-complete` | Full parity: replays, metrics, profiling, EAP, monitors, uptime, spans, launchpad, vroom | [`examples/values-feature-complete.yaml`](./examples/values-feature-complete.yaml) |

```bash
helm install sentry oci://ghcr.io/sprisa/sentry-k8s --version 0.1.0 \
  -n sentry --create-namespace -f examples/values-errors-transactions.yaml
```

To build errors + transactions on top of the default `errors-only` profile, turn
on just the transaction-path components:

```yaml
sentry:
  profile: errors-only
  transactions: { enabled: true }
  postProcessForwarderTransactions: { enabled: true }
  subscriptionConsumerTransactions: { enabled: true }
snuba:
  transactionsConsumer: { enabled: true }
  subscriptionConsumerTransactions: { enabled: true }
```

## ClickHouse: single-node vs HA

Single-node is the default and needs nothing extra. For larger deployments, set
the layout and the chart **auto-enables ClickHouse Keeper**, templates
`remote_servers` + `macros` into `config.xml`, and switches Snuba to clustered
mode:

```yaml
clickhouse:
  layout:
    shardsCount: 2
    replicasCount: 2
  clusterName: sentry
  keeper:
    enabled: true       # auto-on when shards/replicas > 1
    replicaCount: 3
```

Tuning maps cleanly onto ClickHouse config:

```yaml
clickhouse:
  settings:                                   # -> config.xml (server level)
    max_server_memory_usage_to_ram_ratio: "0.75"
  profiles:                                   # -> users.xml (per-profile)
    default/max_memory_usage: "8589934592"
    default/max_bytes_before_external_group_by: "6442450944"
    default/max_bytes_before_external_sort: "6442450944"
```

To bring your own ClickHouse instead, set `clickhouse.enabled: false` and fill in
`externalClickhouse.*`.

## Persistence & data ownership

The chart separates **durable object/blob data** (best on S3/R2 for HA) from
**stateful databases** (local PVCs or external managed services). Recommended HA
posture: push blobs to **S3/R2** and keep only the databases on persistent
volumes.

| Store | Kind | What it holds | Backend | If wiped |
| --- | --- | --- | --- | --- |
| **filestore** | object | release files, **source maps**, **debug files (DIFs)**, event **attachments** | S3/R2 (HA) or filesystem PVC | lose uploaded artifacts |
| **nodestore** | object | **raw event payloads** (full event JSON) | S3/R2 (`sentry-nodestore-s3`) or Postgres (default) | lose raw event bodies |
| **replays** | object | session replay segments (rrweb) | S3/R2 or filestore | lose replays |
| **profiles** | object | profiling/flamegraph data (written by vroom) | S3/R2 or filesystem PVC | lose profiles |
| **ClickHouse** | database | searchable **telemetry**: errors, transactions, outcomes, metrics, replay metadata, profiling indexes, spans — powers Discover/dashboards/search | PVC (or external/HA) | lose analytics history |
| **PostgreSQL** | database | relational source of truth: orgs, projects, teams, users, **DSNs**, dashboards, alert rules, issue metadata, integrations | PVC (or external) | catastrophic — back this up |
| **Kafka** | streaming buffer | in-flight event/transaction/outcome/metric messages (24h) | PVC | lose un-processed events |
| **Redis** | cache + coordination | rate-limit/quota counters, TSDB counters, buffers, locks | PVC | lose rate-limit/processing state |
| **Memcached** | pure cache | config/object cache | none (ephemeral) | nothing — regenerates |
| **taskbroker** | database | Rust task-queue state (SQLite) | PVC (StatefulSet) | lose ~in-flight tasks |
| **symbolicator / vroom caches** | cache | downloaded symbols, profile scratch | PVC (perf only) | re-downloads |

### Filesystem vs S3/R2 (the trade-off)

- **S3/R2 (recommended, HA):** filestore/nodestore/replays/profiles go to
  external object storage → highly available, no large RWX volumes, survives
  cluster loss. Set `filestore.backend: s3` (plus `replay`, `nodestore`,
  `filestore.profiles`) with an `existingSecret` holding `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` (works great with Cloudflare R2 via `endpointUrl`).
- **Filesystem (simple/dev):** blobs live on a PVC. On a single node,
  `ReadWriteOnce` + `filestore.filesystem.persistence.persistentWorkers: true`
  works if web/worker/cron pods are pinned to the same node (via `nodeSelector`).
  For multi-node you must use `ReadWriteMany`. Simplest to start, least HA.

## Mail

Disabled by default. Enable SMTP:

```yaml
mail:
  enabled: true
  host: smtp.example.com
  port: 587
  username: apikey
  password: ""          # or existingSecret
  useTls: true
  from: sentry@example.com
```

## Image versioning

`Chart.yaml` `appVersion` (`26.5.0`) is the single coherent Sentry version. All
getsentry images (`sentry`, `snuba`, `relay`, `symbolicator`, `vroom`,
`taskbroker`, `uptime-checker`, `launchpad`) default to `:<appVersion>` so they
stay compatible. Override per-image via `images.<svc>.tag`.

## Running the tests

```bash
helm test sentry -n sentry
```

This runs CLI-only `helm test` pods (web `/_health/`, snuba-api `/health`,
ClickHouse `/ping`). They use `helm.sh/hook: test`, which is never applied during
install/upgrade and is dropped by Pulumi — so the chart stays hook-free for
deploys.

## Using it from Pulumi

```ts
import * as k8s from "@pulumi/kubernetes";

const sentry = new k8s.helm.v3.Chart("sentry", {
  chart: "oci://ghcr.io/sprisa/sentry-k8s",
  version: "0.1.0",
  namespace: "sentry",
  values: {
    sentry: { profile: "errors-only", system: { url: "https://sentry.example.com" } },
    user: { email: "admin@example.com", existingSecret: "sentry-admin" },
    global: { storageClass: "longhorn" },
    clickhouse: {
      persistence: { size: "100Gi" },
      nodeSelector: { "kubernetes.io/hostname": "datastore-node-1" },
      settings: { max_server_memory_usage_to_ram_ratio: "0.75" },
    },
  },
});

// Front it with your existing ingress (Contour HTTPProxy, oauth2-proxy, etc.)
// pointing at Service "sentry-nginx" on port 80
```

Because there are no Helm hooks, Pulumi manages the bootstrap `Job` and every
other resource directly.

## Using it from Terraform

```hcl
resource "helm_release" "sentry" {
  name             = "sentry"
  namespace        = "sentry"
  create_namespace = true
  chart            = "oci://ghcr.io/sprisa/sentry-k8s"
  version          = "0.1.0"

  values = [yamlencode({
    sentry     = { profile = "errors-only", system = { url = "https://sentry.example.com" } }
    user       = { email = "admin@example.com", existingSecret = "sentry-admin" }
    global     = { storageClass = "longhorn" }
    clickhouse = { persistence = { size = "100Gi" } }
  })]
}
```

No `wait_for_jobs`/hook gymnastics needed — initialization is a normal Job.

## Configuration

The full value surface is documented inline in [`values.yaml`](./values.yaml).
Highlights:

- `sentry.profile`, `sentry.eventRetentionDays`, `sentry.system.url`
- per-component blocks (`enabled`, `replicas`, `resources`, `nodeSelector`,
  `affinity`, `tolerations`, `autoscaling`, …)
- `clickhouse.*` (layout, keeper, settings/profiles, persistence)
- `kafka` / `redis` / `postgresql` / `memcached` (bundled) and their
  `external*` counterparts
- `filestore` / `replay` / `nodestore` / `mail` storage backends
- `nginx` routing proxy and the optional `ingress`

## Development & releasing (maintainers)

Common workflows are wrapped in a [Taskfile](./Taskfile.yml) (install
[go-task](https://taskfile.dev): `brew install go-task`). Run `task` to list
them:

| Task | What it does |
| --- | --- |
| `task deps` | Pull pinned dependencies from `Chart.lock` into `charts/` (extracted, as Helm v4 needs) |
| `task lint` | `helm lint` |
| `task template EXAMPLE=feature-complete` | Render one profile |
| `task test-render` | Render all example profiles to confirm they template cleanly |
| `task package` | Package the versioned `.tgz` (vendors dependencies) |
| `task login` | `helm registry login ghcr.io` (needs `GHCR_TOKEN`) |
| `task notes` | Preview the changelog `task publish` will generate for this version |
| `task publish` | Package + push to `oci://ghcr.io/sprisa` **and** cut a GitHub Release with grouped notes |
| `task pull-check` | Verify the published version is publicly pullable |

Release notes are generated from **Conventional Commits** since the previous
`v*` tag by [`scripts/release-notes.sh`](./scripts/release-notes.sh) (git-cliff
style: grouped by `feat`/`fix`/… with commit links, and squash-merged `(#123)`
PR refs turned into links). Preview them anytime with `task notes`.

Cutting a release:

```bash
# 1. bump `version:` in Chart.yaml (and `appVersion:` if the Sentry version changed),
#    then COMMIT AND PUSH to main — `gh release create` tags the remote's HEAD.
git commit -am "release: v0.2.0" && git push

# 2. authenticate: Helm to GHCR (PAT w/ write:packages) + the GitHub CLI for the release
export GHCR_TOKEN=ghp_xxx          # and GHCR_USER=<your-gh-login> if it isn't `sprisa`
task login
gh auth login                      # one-time; needed for the GitHub Release step

# 3. push the OCI artifact + create the tagged GitHub Release (notes auto-generated)
task publish
```

`task publish` pushes `ghcr.io/sprisa/sentry-k8s:<version>`, then runs
`gh release create v<version>` with notes built from Conventional Commits to tag
the commit, publish the changelog, and attach the packaged `.tgz`. Version is
driven entirely by `Chart.yaml`; no `gh-pages`/`index.yaml` to maintain.

The **first** publish creates a *private* GHCR package. Make it public once at
`https://github.com/users/sprisa/packages/container/sentry-k8s/settings` so
anonymous `helm install oci://…` works. Versioning is driven entirely by
`Chart.yaml`; there is no `gh-pages` branch or `index.yaml` to maintain.
