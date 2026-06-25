# SkyWatch — Implementation Runbook (START HERE)

This folder is a **sequential build plan**. Do the files in order. Each file is self-contained,
ends with a **Done when** gate, and must pass that gate before you move to the next file.

> **For the AI coding assistant executing this:** Do **one file at a time**. Do **not** re-open
> or re-litigate any decision in the "Locked decisions" table below — they were debated and
> settled deliberately. If a file says `emptyDir`, do not "improve" it to a PVC. If it says
> `t3.micro`, do not upgrade it. When a step is ambiguous, prefer the **simplest correct** option
> and leave a `# TODO(human):` comment rather than inventing new architecture.

---

## What we're building

A weather-query pipeline deployed by a fully GitOps pipeline, as a DevOps course project.

```
Browser ──HTTP──▶ Flask frontend ──AMQP publish──▶ RabbitMQ ──consume──▶ Python worker ──HTTPS──▶ Open-Meteo
                       ▲                                                        │
                       └────────────── AMQP reply (RPC, correlation_id) ────────┘
```

The graded artifact is the **pipeline** (Terraform → Ansible → Docker/GHCR → GitHub Actions →
Helm → ArgoCD → Prometheus/Grafana), not the app. The app is intentionally small.

## Build order (files)

| # | File | Layer | Can be built/tested in isolation? |
|---|---|---|---|
| 0 | `00-START-HERE.md` | — | (this file) |
| 1 | `01-app-layer.md` | App + docker-compose | **Yes** — runs fully on your laptop |
| 2 | `02-containers-ci.md` | Dockerfiles, GHCR, GitHub Actions | Yes (needs a GitHub repo) |
| 3 | `03-terraform.md` | AWS infra | Yes (needs AWS creds) |
| 4 | `04-ansible.md` | K3s + bootstrap (installs ArgoCD) | Needs #3 |
| 5 | `05-helm-skywatch.md` | App Helm chart | Renders offline; deploys via #6 |
| 6 | `06-argocd-app-of-apps.md` | GitOps root + children | Needs #4, #5 |
| 7 | `07-observability.md` | Prometheus/Grafana child app | Needs #6 |
| 8 | `08-validate-teardown.md` | Twice-from-scratch gate | Needs all |

**Start with `01`.** You can complete and verify the entire app on your laptop before any cloud
resource exists. Never debug the message round-trip and K3s networking at the same time.

---

## Locked decisions (do NOT change these)

| Decision | Value | Why (one line) |
|---|---|---|
| Instance type | **t3.micro × 3** | Free-tier eligible; 2 vCPU + unlimited burst beats t2.micro for $0 |
| App language | **Python (Flask + plain worker)** | Language is incidental for a DevOps course; keep as assignment specifies |
| Frontend↔worker pattern | **RabbitMQ RPC** (reply_to + correlation_id) | Weather query is request/response; RPC carries the answer back |
| Reply queue | **Exclusive, auto-named, per request** | Collision-proof, self-cleaning; no sticky sessions needed |
| Frontend concurrency | **Sync Flask, blocking thread per request** | 2 replicas at demo scale never exhaust gunicorn threads; async not needed |
| Frontend replicas | **2** | Each request opens its own connection+reply queue, so replicas are independent |
| Worker replicas | **2**, `prefetch=1`, **manual ack after reply** | Crash mid-flight → redelivery → harmless duplicate GET; no idempotency key needed |
| RabbitMQ storage | **emptyDir** (non-durable) | Cluster is destroyed every session; persistence survives nothing |
| RabbitMQ workload kind | **Deployment** (not StatefulSet) | No PVC → no need for stable identity; ClusterIP Service fronts the single replica |
| Prometheus storage | **emptyDir** | Same reason; 24h retention on a 10h node is meaningless |
| `ignoreDifferences` (VCT) | **Removed entirely** | It existed only for `volumeClaimTemplates`; no PVCs → nothing to ignore |
| Queue/message durability | **Non-durable, non-persistent** | Consistent with emptyDir broker; marking durable would be cargo-cult |
| Secret delivery | **Pre-created out-of-band by Ansible** from **ansible-vault** | Stays out of Git; applied before app sync; plaintext never on disk |
| `rabbitmq-secret.yaml` in chart | **Deleted from the chart** | If left in, ArgoCD selfHeal overwrites the real secret with placeholder |
| GitOps model | **App-of-apps** (root → children) with **sync-waves** | Lets ArgoCD manage monitoring too; only ArgoCD install stays imperative |
| Prometheus CRDs | **Separate child app, wave 0, `ServerSideApply=true`, retry backoff** | Big CRDs need server-side apply + paced retry on a 1 GiB API server |
| ArgoCD install | **Helm chart, via Ansible** | `nodeSelector` + NodePort become values; deletes the `kubectl patch` loop |

## The honest asterisks (have these sentences ready for the defense)

- **"Fully automated GitOps"** has exactly one imperative seam: **Ansible installs ArgoCD and
  applies the root app.** Something always has to install the GitOps engine. Everything after that —
  app *and* monitoring — is reconciled from Git.
- **Secrets are intentionally out-of-Git**, pre-provisioned by Ansible from an encrypted vault.
  "If I wanted them Git-managed I'd use Sealed Secrets." Say that; don't pretend it's automatic.
- **The broker is non-durable** and **metrics are session-only.** By design — the cluster is
  destroyed nightly. Nothing in-cluster survives `terraform destroy`; the only durable artifacts
  are in Git (manifests/charts) and in the Ansible vault (the secret value).

---

## Global conventions

- **GitHub owner / repo:** `henria21/skywatch-assignment`. Images: `ghcr.io/henria21/skywatch-assignment-frontend`,
  `ghcr.io/henria21/skywatch-assignment-worker`.
- **Namespaces:** app in `skywatch-assignment`, ArgoCD in `argocd`, monitoring in `monitoring`.
- **NodePorts:** frontend `30080`, ArgoCD `30081`, Grafana `30030`.
- **Region:** `eu-west-1`. **K3s:** pinned `v1.29.5+k3s1`.
- **GHCR images are PUBLIC** → no `imagePullSecret` needed. (If you make them private, you must add
  one; the chart does not include it. Keep them public to avoid that.)

## The secret name contract (memorize — one typo = CrashLoop)

A single Kubernetes Secret named **`skywatch-assignment-rabbitmq`** in namespace `skywatch-assignment`, created by Ansible.
It must contain **exactly** these keys:

| Key | Consumed by | How |
|---|---|---|
| `RABBITMQ_DEFAULT_USER` | RabbitMQ container | `envFrom` |
| `RABBITMQ_DEFAULT_PASS` | RabbitMQ container | `envFrom` |
| `rabbitmq-username` | frontend + worker | `secretKeyRef` → env `RABBITMQ_USERNAME` |
| `rabbitmq-password` | frontend + worker | `secretKeyRef` → env `RABBITMQ_PASSWORD` |

The app code reads three env vars: **`RABBITMQ_HOST`**, **`RABBITMQ_USERNAME`**, **`RABBITMQ_PASSWORD`**.
`RABBITMQ_HOST` is `localhost` in compose, `skywatch-assignment-rabbitmq` (the Service name) in k8s.

## Readiness gates (used in 04/06/08 — never `sleep`, always wait-until-Ready)

1. Before applying the root app: `applications.argoproj.io` CRD **Established** AND argocd
   `application-controller`/`repo-server`/`redis` **Ready**.
2. After root app: root Application reports **Synced + Healthy** (transitively covers wave 0 CRDs
   then wave 1 apps).
3. Before declaring "up": frontend Deployment **Available** AND Prometheus pod **Ready**.
