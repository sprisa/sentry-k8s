# Architecture

This chart deploys the full Sentry self-hosted stack as plain Kubernetes
objects. This document describes what each component does and how a request and
its data flow through the system. For the persistence model (what each store
holds and the S3/R2-vs-filesystem trade-off), see the
[Persistence & data ownership](./README.md#persistence--data-ownership) section
of the README.

## Request & data flow

```mermaid
flowchart TD
    Client[SDK / Browser]

    subgraph routing [Routing - bundled nginx, single ClusterIP]
        NGINX["nginx :80<br/>regex split"]
    end

    subgraph edge [Ingest edge]
        REL[relay :3000]
    end

    subgraph app [Sentry app]
        WEB[web :9000<br/>Django UI + API]
        ING[ingest consumers]
        PPF[post-process forwarders]
        SUB[subscription consumers]
        TS[task system<br/>taskbroker/scheduler/worker]
    end

    subgraph analytics [Analytics - Snuba]
        SAPI[snuba-api :1218]
        SCON[snuba consumers]
        SREP[snuba-replacer]
    end

    subgraph stores [Datastores]
        KF[(Kafka)]
        CH[(ClickHouse)]
        PG[(PostgreSQL)]
        RD[(Redis)]
        MC[(Memcached)]
        OBJ[(S3 / R2 or filesystem<br/>filestore/nodestore/replays/profiles)]
    end

    Client -->|/api/{id}/, /api/store/| NGINX --> REL
    Client -->|UI, REST API| NGINX --> WEB
    REL -->|envelopes| KF
    KF --> ING
    ING --> OBJ
    ING --> KF
    KF --> SCON --> CH
    SCON --> SREP --> CH
    WEB -->|queries| SAPI --> CH
    KF --> PPF --> TS
    KF --> SUB
    WEB --> PG
    WEB --> RD
    WEB --> MC
    WEB --> OBJ
```

1. **SDKs** send events/envelopes to `/api/{project_id}/...` and `/api/store/`.
   The bundled **nginx** proxy regex-splits that ingest traffic to **relay** and
   sends UI/REST traffic to **web**.
2. **relay** rate-limits and PII-scrubs at the edge, then publishes to **Kafka**.
3. **Sentry ingest consumers** read Kafka, normalize/process events, write raw
   payloads to **nodestore** (S3/R2 or DB) and attachments to **filestore**, and
   forward analytics to Kafka for Snuba.
4. **Snuba consumers** write those streams into **ClickHouse** tables;
   **snuba-api** answers all of Sentry's analytical queries.
5. **post-process forwarders** run alert rules, integrations, and grouping after
   an event is stored, dispatching async work through the **task system**.
6. **web** (Django) serves the dashboard/API, reading relational state from
   **PostgreSQL**, caches/counters from **Redis**/**Memcached**, and analytics
   from **snuba-api**.

## Component catalog

### Routing
- **nginx (routing proxy)** — single entrypoint and the only thing your external
  ingress needs to target. Replicates the self-hosted `nginx.conf` regex rules
  (`/api/store/`, `^/api/[1-9]\d*/`, `^~ /api/0/relays/` → relay; `/`,
  `/_assets/`, `/_static/` → web) with `client_max_body_size 100m` and
  `X-Forwarded-Proto`. Avoids controller-specific regex annotations so the chart
  is portable across ingress controllers (or none).

### Request / ingest path
- **relay** — receives SDK events/envelopes at the edge, applies rate limiting
  and PII scrubbing, then forwards to Kafka. Decouples spiky client traffic from
  the backend. Runs in `managed` mode and generates `credentials.json` via an
  init container.
- **web (Sentry)** — the Django app: UI, REST API, auth, project/issue
  management, serves the dashboard. uWSGI on port 9000.

### Stream processing (Kafka consumers)
- **ingest consumers** (events, attachments, transactions, replay-recordings,
  occurrences, profiles, monitors, feedback) — pull raw messages off Kafka,
  normalize/process, persist event payloads, and hand analytics to Snuba.
- **post-process-forwarders** (errors, transactions, issue-platform) — run
  post-processing (alert rules, integrations, grouping) after an event is stored.
- **subscription consumers** — power alerting / metric-alert evaluation.
- **process spans/segments**, **monitors clock-tick/tasks**, **uptime-results** —
  feature-complete pipelines for tracing spans, cron monitors, and uptime checks.

### Analytics layer (Snuba)
- **snuba-api** — query service in front of ClickHouse; Sentry queries all event
  analytics through it (port 1218).
- **snuba consumers** (errors, transactions, outcomes, metrics, replays,
  profiling, generic-metrics, eap-items, …) — write the corresponding event
  streams from Kafka into ClickHouse tables.
- **snuba-replacer** — applies mutations (merges, deletes, reprocessing) to
  ClickHouse.

### Task system
- **taskbroker** (Rust, SQLite-backed StatefulSet) — durable task queue broker,
  exposes gRPC on 50051. SQLite DB persists via a `volumeClaimTemplate`.
- **taskscheduler** — enqueues scheduled/periodic tasks.
- **taskworker** — executes async work (notifications, digests, cleanup subtasks).
- **launchpad** (feature-complete) — profiling-related task worker.

### Supporting services
- **vroom** (feature-complete) — profiling service; processes flamegraph/profile
  data (port 8085).
- **symbolicator** (opt-in) — resolves native/minified stack traces using debug
  symbols (port 3021).
- **uptime-checker** (feature-complete) — performs uptime probe checks.
- **cleanup** (CronJob) — deletes data older than `sentry.eventRetentionDays`.
- **bootstrap (Job)** — one-time, hook-free DB init/migration: waits for infra,
  runs `snuba bootstrap` + `snuba migrations migrate`, `sentry upgrade
  --create-kafka-topics`, and creates the initial superuser.

### Datastores
- **ClickHouse** — bundled, first-class StatefulSet (no Altinity operator).
  Optional ClickHouse Keeper + sharding/replication for HA.
- **PostgreSQL**, **Kafka** (KRaft), **Redis**, **Memcached** — bundled Bitnami
  subcharts, each replaceable by an external/managed service.

## Initialization without Helm hooks

Ordering is achieved with a plain `Job` + per-pod init containers rather than
hook weights:

- `templates/secrets.yaml` generates `SENTRY_SECRET_KEY`,
  `SENTRY_SYSTEM_SECRET_KEY`, and `LAUNCHPAD_RPC_SHARED_SECRET` once and
  preserves them across upgrades via `lookup` (and `helm.sh/resource-policy:
  keep`).
- `templates/jobs/bootstrap-job.yaml` runs the migration steps as **sequential
  init containers** (each can use a different image: snuba, then sentry), then a
  trivial main container marks completion. The Job name embeds the Sentry image
  tag so a version bump creates a fresh Job; `ttlSecondsAfterFinished` cleans up.
- Every app workload has a `wait-for-infra` init container that blocks until its
  ClickHouse/Kafka/Redis/Postgres dependencies accept connections. On a fresh
  install, app pods may restart a few times until the bootstrap Job has created
  the schema — this is the documented trade-off for being hook-free (and thus
  Pulumi/Terraform-friendly).

## Component gating (presets)

Each component is switched independently by its
own `enabled` flag, and the [`examples/`](./examples) files are presets that set
those flags. The chart defaults are the errors-only set:

- **errors-only** (default): web, relay, snuba-api + errors/outcomes/replacer/
  group-attributes/events-subscription consumers, taskbroker/scheduler/worker,
  ingest-events/attachments, post-process-forwarder-errors,
  subscription-consumer-events, cleanup.
- **feature-complete** (example): everything above plus transactions, replays,
  metrics, generic-metrics, profiling, EAP, monitors, uptime, spans/segments,
  launchpad, vroom (symbolicator stays opt-in).

Because gating is per-component you can build any intermediate set (e.g. errors +
transactions). Separately, `sentry.selfHostedErrorsOnly` (Sentry's
`SENTRY_SELF_HOSTED_ERRORS_ONLY`) controls whether the performance/replays/etc.
product surfaces are shown — set it `false` when you enable those pipelines.
