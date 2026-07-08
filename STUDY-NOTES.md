# SkyWatch — Defense Study Notes

> One-line pitch: *the app is deliberately trivial so the delivery pipeline can be the star.*
> Terraform → Ansible → Docker/GHCR → GitHub Actions → Helm → ArgoCD → Prometheus/Grafana.

---

## 1. Big picture

```
Browser ──HTTP──▶ Flask frontend ──AMQP publish──▶ RabbitMQ ──consume──▶ Python worker ──HTTPS──▶ Open-Meteo
                       ▲                                                        │
                       └────────────── AMQP reply (RPC, correlation_id) ────────┘
```

- **Graded artifact = the pipeline, not the app.**
- Everything reconciles from Git except **one imperative seam**: Ansible installs ArgoCD and applies the root app. (Something always has to install the GitOps engine.)
- Everything stateful is `emptyDir` — the cluster is **cattle, not pets**; it's destroyed every session.

### What survives `terraform destroy`? (memorize)
Nothing in-cluster. Only three durable artifacts:
1. **Git** — manifests, Helm chart, ArgoCD apps, CI workflow
2. **Ansible vault** — the encrypted RabbitMQ secret value
3. **GHCR** — immutable SHA-tagged images

A fresh cluster rebuilds 100% of runtime state from those three.

---

## 2. Cluster layout (3 × t3.small, eu-west-1, K3s v1.29.5+k3s1)

| Node | Hostname | Runs |
|---|---|---|
| Master | `skywatch-master` | K3s server + etcd only — tainted `NoSchedule` at install (`--node-taint`), 2G swap |
| Worker 1 | `skywatch-worker` | ArgoCD pods + repo-server |
| Worker 2 | `skywatch-worker2` | All 5 app pods (nodeSelector) + monitoring stack |

**Why t3.small, not t3.micro?** t3.micro (1 GiB) OOMed repeatedly under K3s + etcd + ArgoCD + kube-prometheus-stack (real commits: "prevent ArgoCD OOM crashes"). t3.small = 2 GiB, minimum viable. ~$0.023/hr/node ≈ $0.69 per 10h session.

**Why t3 over t2?** Same price tier, t3 has 2 vCPU and launches *unlimited* burst mode (never throttled); t2 throttles once credits drain — exactly during K3s install + image pulls + first sync.

### Ports (memorize)
| Service | Port | Node |
|---|---|---|
| Frontend | NodePort **30080** | worker2 |
| ArgoCD | HTTP **30082** / HTTPS **30083** | worker1 |
| Grafana | NodePort **30030**, admin/admin | worker2 |
| Prometheus | ClusterIP 9090 only | worker2 |
| RabbitMQ | AMQP 5672 / mgmt 15672 / metrics **15692** | worker2 |
| K3s API | 6443 | master |

(ArgoCD started on 30081, matching the spec — moved to 30082/30083 after a genuine port conflict with the frontend's NodePort; not a stylistic renumber. Grafana's 30030 matches the spec; an unexplained 30090 detour was reverted.)

---

## 3. App layer — the RPC pattern (most-asked topic)

A broker is one-way, so how does the answer get back? **RPC over RabbitMQ:**

1. Frontend opens a short-lived connection **per request** (thread-safe at demo scale; pika connections are NOT thread-safe to share).
2. Declares an **exclusive, auto-named reply queue** (broker-assigned name, auto-deleted when the connection closes → collision-proof, self-cleaning, no sticky sessions needed).
3. Publishes to `weather_jobs` with `reply_to=<reply queue>` + unique `correlation_id`.
4. Blocks up to **15 s** waiting for a message with the matching `correlation_id`.
5. Worker calls Open-Meteo (geocoding → forecast), publishes result to `reply_to` with the same `correlation_id`, **then** acks.

Worker discipline: `prefetch=1`, **manual ack only AFTER the reply is published**. Crash mid-flight → redelivery → another worker repeats a harmless GET → at worst a duplicate reply, discarded by `correlation_id`. That's why **no app-level idempotency key is needed** — the worker is stateless.

- Frontend: sync Flask + gunicorn (4 workers × 4 threads). Async would be gold-plating at 2 replicas / demo traffic.
- Replicas: frontend ×2, worker ×2, RabbitMQ ×1.
- Workers CrashLoop on startup until RabbitMQ is ready — normal, they have a reconnect loop.
- Env contract read by the code: `RABBITMQ_HOST`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`. Host = `localhost`→compose, `skywatch-assignment-rabbitmq` (Service name) → k8s.

---

## 4. CI/CD — GitHub Actions

Push to `main`: **lint (flake8) → build both images → push to GHCR (`:sha7` + `:latest`) → yq bumps the two tag fields in `values.yaml` → bot commit `[skip ci]`**. PRs: lint + build only, never a bump commit (guarded by `if: github.event_name == 'push'`).

Key gotchas (each is a likely question):
- **Deploy the `:sha` tag, never `:latest`.** GitOps needs an immutable reference; `latest` is a moving pointer ArgoCD can't diff, selfHeal could flap. `latest` is pushed only as a human convenience.
- **Infinite-loop prevention — two layers:** (1) the real one: pushes made with the default `GITHUB_TOKEN` don't retrigger `on: push` workflows, by GitHub design; (2) `[skip ci]` is belt-and-suspenders, load-bearing only if you switch to a PAT (PAT pushes DO retrigger).
- **mikefarah `yq` (Go binary via wget), never `pip install yq`** — two incompatible tools share the name; only the Go one supports `yq -i` in-place edits.
- `git diff --quiet` makes the bump commit idempotent (no empty commits).
- Branch protection on `main` would silently reject the bump push → deliberately unprotected (solo, trunk-based; in a team: CI opens a PR with the bump).
- Concurrency group with `cancel-in-progress: false` (queue, don't cancel mid-push); `git pull --rebase` before push.
- GHCR packages default to **private** after first push → manually set both to **Public** so K3s pulls without an `imagePullSecret` (the chart has none, deliberately).

---

## 5. Terraform

- 3 × EC2 via `for_each` over an instance-type map; Ubuntu 22.04 AMI looked up **dynamically** (owner 099720109477 = Canonical) — no hard-coded AMI.
- One security group: SSH 22, K3s API 6443, NodePort range 30000–32767 — all restricted to **my IP /32**; intra-cluster = SG **self-reference** rule (`self = true`).
- `local_file` renders `ansible/inventory.ini` from a template → Terraform hands off to Ansible automatically.
- Never committed: `terraform.tfstate` (contains secrets in plaintext!), `terraform.tfvars`, `.terraform/`.

**Classic failure:** worker can't reach master:6443 → inventory used the master's **public** IP. Intra-VPC traffic to a public IP egresses via the IGW and bypasses the SG self-rule. Fix: `K3S_URL` uses the master's **private** IP.

---

## 6. Ansible

Roles: `k3s_master`, `k3s_worker`, `bootstrap` (+ swap on worker2).

- **Idempotency guard:** `systemctl is-active k3s` / `k3s-agent` check before install — re-running the playbook on a live cluster changes nothing. (Historically, a `removes:`-guarded uninstall wiped a live cluster.)
- Master install flags: pinned `INSTALL_K3S_VERSION=v1.29.5+k3s1`, `--disable traefik`, `--tls-san <public_ip>` (so laptop `kubectl` passes TLS), `--node-taint node-role.kubernetes.io/control-plane=:NoSchedule` (taint at install → no separate kubectl step).
- Workers join with `K3S_URL` + `K3S_TOKEN` as **environment variables** — the installer reads env vars, not CLI flags.
- **Never run with `--limit`**: skipping the master play means the `k3s_token` fact is never set → join fails.
- Kubeconfig fetched to repo root, server rewritten `127.0.0.1` → master public IP.
- Vault: `group_vars/all/vault.yml` **is committed (encrypted)**; the vault **password** never is. `.vault_pass` must live on the Linux FS (WSL/NTFS permission issue) or use `--ask-vault-pass`.

### Bootstrap order (enforced by task order, not memory)
1. Install ArgoCD via **Helm** (chart 7.3.11 → ArgoCD v2.11.x) with values: nodeSelector→worker1, NodePorts 30082/30083, `repoServer.resources` capped (100m/256Mi req, 500m/768Mi limit), Dex + notifications disabled.
2. **Gate 1:** wait for `applications.argoproj.io` CRD Established **AND** repo-server/redis/application-controller Ready. (The readiness half was missing originally → `skywatch-root` stuck at `Unknown` because the controller queried repo-server before its endpoints existed. Fixed with three `k8s_info` wait loops.)
3. Create namespace `skywatch-assignment` (**before** the secret).
4. Create the secret from vault vars.
5. Apply `argocd/root-app.yaml`.

Readiness gates rule: **never `sleep`, always wait-until-Ready.**

---

## 7. The secret contract (one typo = CrashLoop)

One Secret, `skywatch-assignment-rabbitmq`, in namespace `skywatch-assignment`, created **by Ansible, out-of-band** — 4 keys:

| Key | Consumer | Mechanism |
|---|---|---|
| `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` | RabbitMQ container | `envFrom` secretRef |
| `rabbitmq-username` / `rabbitmq-password` | frontend + worker | `secretKeyRef` → env |

Why out-of-Git: plaintext never touches disk or Git. Why `rabbitmq-secret.yaml` was **deleted from the chart**: if the chart rendered a placeholder secret, ArgoCD selfHeal would overwrite the real one → guaranteed breakage. A resource managed out-of-band must not also be owned by the chart.
Why ArgoCD doesn't prune it: prune only touches resources ArgoCD *tracks* (applied from Git with its tracking annotation); a hand-created secret is invisible to it.
Why not Sealed Secrets/SOPS: the "purer" answer for production — skipped here to avoid an extra controller on small nodes. **Conscious scope tradeoff, not an oversight.**
Downside to admit: bootstrap ordering becomes load-bearing (namespace → secret → root app), enforced by Ansible task order.

---

## 8. Helm chart (`helm/skywatch-assignment`)

- frontend Deployment ×2 (NodePort 30080, `/healthz` readiness probe), worker Deployment ×2 (no ports, **no readiness probe** — consumer, not server), RabbitMQ **Deployment** ×1 + ClusterIP Service, ServiceMonitor.
- All pods pinned to worker2 via `nodeSelector: kubernetes.io/hostname: skywatch-worker2`.
- CI rewrites the two `image.tag` fields; everything else static.

Three things **deliberately absent** (don't let them creep back):
1. `rabbitmq-secret.yaml` (see §7).
2. PVCs / `volumeClaimTemplates` — RabbitMQ on `emptyDir`.
3. `ignoreDifferences` — it existed only to paper over API-server-defaulted fields in `volumeClaimTemplates` (perpetual OutOfSync); no PVC → nothing to ignore.

Key decisions:
- **Deployment, not StatefulSet** (assignment said StatefulSet): a StatefulSet earns its keep via stable identity for PVCs + ordered scaling. No PVC, single replica → it buys nothing; the ClusterIP Service alone gives the stable DNS name.
- **emptyDir everywhere**: cluster destroyed every session; persistence survives nothing. Queues/messages also **non-durable** — marking them durable on an ephemeral broker would be cargo-cult.
- **TCP probe on 5672**, not exec `rabbitmq-diagnostics ping`: the exec probe stalls when the Erlang memory-watermark alarm fires on a small node; TCP is instant. (Compose still uses the exec ping — laptop has RAM.)
- **Bitnami subchart removed**: Bitnami deleted all images from Docker Hub (404s, new OCI registry needs auth) → inline templates with official `rabbitmq:3.13-management`. Lesson: vendor registries can vanish.

---

## 9. GitOps — app-of-apps + sync-waves

```
skywatch-root (applied once by Ansible, watches argocd/apps/, recurse)
├── prometheus-crds   wave 0   chart prometheus-operator-crds 30.0.1, ServerSideApply=true, retry/backoff
├── skywatch-assignment  wave 1   this repo, helm/skywatch-assignment, ns skywatch-assignment
└── monitoring        wave 1   kube-prometheus-stack 87.10.1, skipCrds: true, inline values
```

All apps: `automated: { prune: true, selfHeal: true }`, `CreateNamespace=true`.

- **Why the wave split:** skywatch ships a `ServiceMonitor` — a CRD owned by the Prometheus operator. Synced before the CRDs exist → `no matches for kind "ServiceMonitor"`. Wave 0 must be Healthy before wave 1 starts.
- **Why `ServerSideApply=true` (mandatory):** the Prometheus CRDs exceed the **262144-byte** client-side `last-applied-configuration` annotation limit → `metadata.annotations: Too long` without it. Retry/backoff replaces the spec's manual `kubectl apply --server-side; sleep 10` loop.
- **Why `skipCrds: true` on monitoring:** the chart's own big-bang CRD install times out the small API server; CRDs already came from wave 0.
- **ServiceMonitor lives in the app chart** (not the monitoring app): the app owns its observability contract; cost = the wave dependency, which the waves make safe.
- **Delete the root app?** Prune cascades: children pruned, then their resources — a real teardown, not auto-undone. The hand-made secret survives (untracked). Acceptable: Git is still the source of truth; re-apply root and everything rebuilds.
- **Chart pins:** `"*"`/latest was a real regression — every fresh cluster could pull a different version, breaking the twice-from-scratch gate. Now pinned: argo-cd 7.3.11, crds 30.0.1, kps 87.10.1.
- Failure mode to know: monitoring stuck `comparison failed` = repo-server OOM rendering the big chart on worker1 → that's why `repoServer.resources` is capped in the ArgoCD install.
- **monitoring auto-sync history:** disabled in the t3.micro era ("API hammering" fear), re-enabled 2026-07-05 after an 18+ min live test on t3.small (repo-server ~50Mi, controller 387Mi, 0 restarts, nodes 61–69% memory).

**The GitOps loop (say out loud):** human pushes code → Actions builds + pushes `:sha` → machine commits the tag bump → ArgoCD sees `values.yaml` change → rolls the new image in ~3 min. **No `kubectl` in the loop.**

---

## 10. Observability

- kube-prometheus-stack via the `monitoring` ArgoCD app (never manual `helm install`).
- Prometheus: **emptyDir** (no storageSpec), retention **6h** (spec had 24h; sessions are ~10h, 6h covers any in-session query with less TSDB footprint), slim resources.
- Alertmanager: **enabled** with tiny limits (spec disabled it to save ~100MB — justified re-enable after the RAM doubling), ClusterIP only.
- Grafana: NodePort 30030, admin/admin. Dashboards: **10991** (RabbitMQ-Overview), **1860** (Node Exporter Full).

**RabbitMQ metrics chain (sanity-check answer):** `rabbitmq:3.13-management` enables the `rabbitmq_prometheus` plugin by default → `:15692` → Service names the port `prometheus` → ServiceMonitor scrapes `port: prometheus` every 30s → Prometheus selects the ServiceMonitor via label `release: kube-prometheus-stack`. Label mismatch = first suspect when queue metrics are missing.

---

## 11. Validation & teardown (grading gate)

**Twice-from-scratch**: two independent runs must reach working app + Grafana with **zero manual edits**; re-running the playbook on a live cluster reports nothing changed; `terraform destroy` leaves `terraform state list` empty. Any manual fix Run 2 needed belongs in code.

Three readiness gates (never sleep):
1. Application CRD Established + ArgoCD components Ready → else `no matches for kind "Application"`.
2. Root app Synced+Healthy (covers wave 0→1) → else ServiceMonitor errors.
3. Frontend Available + Prometheus Ready → else CrashLoop on the projector.

### Symptom → first suspect (memorize this table)
| Symptom | First suspect |
|---|---|
| Worker can't reach master:6443 | public IP in inventory — must be **private** |
| `kubectl` TLS error from laptop | missing `--tls-san <public_ip>` |
| Frontend/worker CrashLoop | secret name/keys mismatch, or namespace after secret |
| `no matches for kind "ServiceMonitor"` | wave order broke — CRDs not Healthy first |
| `metadata.annotations: Too long` | `ServerSideApply=true` missing |
| monitoring `comparison failed` | repo-server OOM — bump its memory |
| skywatch OutOfSync forever | PVC or `rabbitmq-secret.yaml` crept back into the chart |
| Grafana missing RabbitMQ metrics | ServiceMonitor `release:` label mismatch |
| `skywatch-root` Unknown after bootstrap | controller raced repo-server → hard refresh patch |

---

## 12. Defense one-liners (the honest asterisks)

- **Why RabbitMQ for a synchronous lookup?** "For this workload it's overhead, and I say so. It's pedagogical decoupling the course assesses, plus a real Prometheus scrape target. Necessity and pedagogy are different things."
- **Fully automated GitOps?** "One imperative seam: Ansible installs ArgoCD and applies the root app. Everything after reconciles from Git."
- **Secrets in GitOps?** "They don't enter Git. Ansible pre-provisions from an encrypted vault. Sealed Secrets if I wanted them Git-managed."
- **Your SPOF?** "RabbitMQ — single replica, emptyDir. Non-durable by design on an ephemeral cluster; in-flight requests time out and retry."
- **Sticky sessions across frontend replicas?** "No — the reply queue is bound to the publishing replica's own connection, request-scoped. kube-proxy routing is irrelevant."
- Rule of the whole defense: **state the tradeoff; a defended limitation scores better than a hidden one.**
