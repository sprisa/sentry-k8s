# sentry-k8s

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/sentry-k8s)](https://artifacthub.io/packages/helm/sentry-k8s/sentry-k8s)

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
helm install sentry oci://ghcr.io/sprisa/sentry-k8s \
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
helm install sentry oci://ghcr.io/sprisa/sentry-k8s \
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

## Presets (example values)

Every component is gated by its own
`enabled` flag, and the files in [`examples/`](./examples) are ready-made presets
that toggle those flags for you. The chart defaults are the errors-only set.

| Preset | What runs | Example values |
| --- | --- | --- |
| **Errors only** (default, lightweight) | Error tracking: web, relay, snuba errors/outcomes, taskbroker, ingest-events/attachments, cleanup | [`examples/values-errors-only.yaml`](./examples/values-errors-only.yaml) |
| **Errors + transactions** | Adds the performance/tracing pipeline | [`examples/values-errors-transactions.yaml`](./examples/values-errors-transactions.yaml) |
| **Feature complete** | Full parity: replays, metrics, profiling, EAP, monitors, uptime, spans, launchpad, vroom | [`examples/values-feature-complete.yaml`](./examples/values-feature-complete.yaml) |

```bash
helm install sentry oci://ghcr.io/sprisa/sentry-k8s \
  -n sentry --create-namespace -f examples/values-errors-transactions.yaml
```

To build errors + transactions on top of the defaults, surface the performance
product (`sentry.selfHostedErrorsOnly: false`) and turn on just the
transaction-path components:

```yaml
sentry:
  selfHostedErrorsOnly: false   # show the performance/transactions UI
  transactions: { enabled: true }
  postProcessForwarderTransactions: { enabled: true }
  subscriptionConsumerTransactions: { enabled: true }
snuba:
  transactionsConsumer: { enabled: true }
  subscriptionConsumerTransactions: { enabled: true }
```

`sentry.selfHostedErrorsOnly` maps directly to Sentry's
`SENTRY_SELF_HOSTED_ERRORS_ONLY` setting: `true` (default) hides the
performance/replays/etc. product surfaces; set it `false` once you enable those
pipelines.

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

## Bundled datastores & HA

Postgres, Redis, Kafka and Memcached are **first-class in-tree templates** (no
Bitnami or other subcharts). They use the same images Sentry self-hosted ships
and are overridable via each block's `image.repository` / `image.tag`:

| Store | Image (default) | HA support | Default |
| --- | --- | --- | --- |
| **PostgreSQL** | `postgres:16` | single-node only — use `externalPostgresql` (managed/operator) for HA | single-node |
| **Kafka** | `confluentinc/cp-kafka:7.6.6` | multi-broker KRaft (native) | single-node |
| **Redis** | `redis:6.2.20-alpine` | Sentinel auto-failover (+ HAProxy master router) | standalone |
| **Memcached** | `memcached:1.6.26-alpine` | none (pure cache; single node) | single-node |

Defaults run everything single-node. Enable HA where it's supported:

```yaml
# Kafka: multi-broker. replicas must be ODD (controller quorum); set RF/minISR
# so auto-created topics survive a broker loss (otherwise HA is cosmetic).
kafka:
  replicas: 3
  replicationFactor: 3
  minInsyncReplicas: 2

# Redis: Sentinel HA. Adds a sentinel sidecar per pod + an HAProxy deployment;
# the `<release>-redis-master` Service always points at the live master, so even
# non-Sentinel-aware clients (Snuba) follow failover transparently.
redis:
  architecture: replication
  replicas: 3
  sentinel:
    enabled: true
```

Notes:
- **Postgres** is the relational source of truth and hardest to fail over safely;
  the chart keeps it single-node. For production HA, set `postgresql.enabled:
  false` and point `externalPostgresql.*` at a managed cluster (RDS, Cloud SQL,
  CloudNativePG/Crunchy). Postgres is rarely the bottleneck — ClickHouse does the
  heavy querying. Postgres uses password auth (auto-generated secret; override
  via `postgresql.auth.password` or `postgresql.auth.existingSecret`).
- **Redis** must stay on the 6.2.x line — Sentry tracks Redis 6.2 and has known
  incompatibilities with Redis 7 / Valkey.
- **Kafka** changing `replicas` after first boot needs manual KRaft quorum steps;
  pick your broker count up front.
- **Memcached** is a pure cache; running >1 replica behind one Service VIP is not
  real sharding (it round-robins), so it stays single-node.

When a datastore runs in HA mode (Kafka `replicas>1`, Redis replication/Sentinel,
or clustered ClickHouse), the chart automatically adds a **PodDisruptionBudget**
(`maxUnavailable: 1`, tune via `<store>.pdb`) and a **soft pod anti-affinity** so
replicas spread across nodes. Setting an explicit `<store>.affinity` overrides the
default anti-affinity; set `<store>.pdb.enabled: false` to skip the PDB.

To use external/managed datastores instead, set `<store>.enabled: false` and fill
the matching `externalPostgresql` / `externalRedis` / `externalKafka` block.

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
  useSsl: false
  from: sentry@example.com
```

## SSO (OIDC, e.g. Clerk / Okta / Auth0)

Sentry self-hosted gets SSO through the generic [`sentry-auth-oidc`](https://github.com/siemens/sentry-auth-oidc)
plugin. You can install it without baking a custom image via `sentry.extraPipPackages`,
then point it at your IdP from `sentry.config`:

```yaml
sentry:
  # Installed into PYTHONUSERBASE on every Sentry pod by an init container.
  extraPipPackages:
    - "sentry-auth-oidc==9.1.1"
  config: |
    import os
    OIDC_ISSUER = "Clerk"
    OIDC_SCOPE = "openid email profile"
    OIDC_DOMAIN = "https://clerk.example.com"   # plugin appends /.well-known/openid-configuration
    OIDC_CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
    OIDC_CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
  web:
    env:
      - name: OIDC_CLIENT_ID
        valueFrom: { secretKeyRef: { name: sentry-oidc, key: client-id } }
      - name: OIDC_CLIENT_SECRET
        valueFrom: { secretKeyRef: { name: sentry-oidc, key: client-secret } }
```

On the IdP side, register an OAuth/OIDC client with redirect URI
`https://<your-sentry-host>/auth/sso/` and the `openid email profile` scopes.
After deploy, log in as the bootstrap admin and finish linking under
**Org Settings → Auth**. (`OIDC_DOMAIN` must serve `/.well-known/openid-configuration`;
if your provider doesn't, set `OIDC_AUTHORIZATION_ENDPOINT` / `OIDC_TOKEN_ENDPOINT` /
`OIDC_USERINFO_ENDPOINT` / `OIDC_ISSUER` explicitly instead.)

`extraPipPackages` installs at pod startup, which slows starts and requires
network access from the pods; for air-gapped or latency-sensitive setups, bake a
custom image (`FROM ghcr.io/getsentry/sentry:<appVersion>` + `pip install`) and
set `images.sentry.repository`/`tag` instead.

## Image versioning

`Chart.yaml` `appVersion` (`26.5.0`) is the single coherent Sentry version. All
getsentry images (`sentry`, `snuba`, `relay`, `symbolicator`, `vroom`,
`taskbroker`, `uptime-checker`, `launchpad`) default to `:<appVersion>` so they
stay compatible. Override per-image via `images.<svc>.tag`.

## Running the tests

```bash
helm test sentry -n sentry
```

This runs CLI-only `helm test` pods: HTTP health checks for web (`/_health/`),
snuba-api (`/health`) and ClickHouse (`/ping`), plus TCP connectivity checks for
the bundled Postgres, Redis and Kafka. They use `helm.sh/hook: test`, which is
never applied during install/upgrade and is dropped by Pulumi — so the chart
stays hook-free for
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

- `sentry.selfHostedErrorsOnly`, `sentry.eventRetentionDays`, `sentry.system.url`
- `sentry.jsSdk.setupAssets` — proxy JS SDK bundles through nginx with local cache
  instead of loading from the CDN directly (only affects plain `<script>` projects
  without a bundler; see [JS SDK Loader](#js-sdk-loader))
- `sentry.jsSdk.defaultSdkUrl` — CDN URL template used when `setupAssets` is `true`
- per-component blocks (`enabled`, `replicas`, `resources`, `nodeSelector`,
  `affinity`, `tolerations`, `autoscaling`, …)
- `clickhouse.*` (layout, keeper, settings/profiles, persistence)
- `kafka` / `redis` / `postgresql` / `memcached` (bundled) and their
  `external*` counterparts
- `filestore` / `replay` / `nodestore` / `mail` storage backends
- `nginx` routing proxy and the optional `ingress`

### JS SDK Loader

Sentry can serve the browser JS SDK bundles itself instead of loading them from
`browser.sentry-cdn.com`. This applies **only to projects using the JS Loader**
[`<script>` snippet](https://docs.sentry.io/platforms/javascript/install/lazy-load-sentry/)
— plain HTML pages without a build system. Projects using `@sentry/browser` via
npm/yarn are unaffected.

```yaml
sentry:
  jsSdk:
    setupAssets: true
```

- **`setupAssets: false` (default)** — Sentry returns a lightweight no-op loader
  that redirects to the CDN.
- **`setupAssets: true`** — nginx proxies `/js-sdk/*` requests to
  `browser.sentry-cdn.com` with a local cache (1 GB, 1-year TTL). The first
  request after deploy fetches from the CDN; subsequent ones serve from nginx's
  ephemeral storage. No init container, no PVC, no download script.
- **`defaultSdkUrl`** — URL template for the SDK bundles. Defaults to an absolute
  URL constructed from `sentry.system.url` (e.g. `https://sentry.example.com/js-sdk/%s/bundle%s.min.js`).
  Set explicitly only if you need a different CDN/distribution layer. `%s` is
  replaced by the SDK version and bundle variant.

## Development & releasing (maintainers)

Common workflows are wrapped in a [Taskfile](./Taskfile.yml) (install
[go-task](https://taskfile.dev): `brew install go-task`). Run `task` to list
them:

| Task | What it does |
| --- | --- |
| `task lint` | `helm lint` |
| `task template EXAMPLE=feature-complete` | Render one preset |
| `task test-render` | Render all example presets to confirm they template cleanly |
| `task package` | Package the versioned `.tgz` |
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
# 1. bump `version:` in Chart.yaml (and `appVersion:` if required), then
#    COMMIT AND PUSH to main — `gh release create` tags the remote's HEAD.
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
