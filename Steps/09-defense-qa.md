# 09 — Defense / Viva Q&A

Every likely examiner question, the crisp answer, and the follow-up they'll push with. Grouped by
theme. The rule throughout: **state the tradeoff, don't pretend there isn't one.** A defended
limitation scores better than a hidden one.

---

## A. Architecture & design

**Q: Why RabbitMQ at all for a synchronous weather lookup?**
For this workload it's overhead, and I say so openly. It's there for two legitimate reasons: (1) the
course requires demonstrating broker-based decoupling between frontend and workers, and (2) it gives
a real Prometheus scrape target (`:15692`). I'm not pretending it's architecturally necessary for a
single GET — it isn't.
*Follow-up "so it's pointless?"* → No: it lets the frontend and worker scale and fail independently,
and it's the integration point the course is assessing. Necessity and pedagogy are different things.

**Q: A broker is one-way (publish→consume). How does the weather get back to the browser?**
RPC pattern over RabbitMQ. The frontend declares an **exclusive, auto-named reply queue**, publishes
the job with `reply_to=<that queue>` and a unique `correlation_id`, then blocks until a message with
the matching `correlation_id` arrives on that queue (with a 15s timeout). The worker publishes its
result to `reply_to` carrying the same `correlation_id`. The whole round-trip lives inside one HTTP
request.

**Q: Why an exclusive queue per request instead of a named shared one?**
Collision-proof and self-cleaning. An empty-name `exclusive=True` queue gets a broker-assigned unique
name and is auto-deleted when the connection closes. No two requests can cross wires, and no cleanup
job is needed.
*Follow-up "do you need sticky sessions across frontend replicas?"* → No. The reply queue is bound to
the connection the publishing replica owns, so the reply returns to that same replica within the same
request. It's request-scoped, not session-scoped — kube-proxy routing is irrelevant.

**Q: Sync Flask blocks a thread per request. Why not async?**
At 2 replicas and demo traffic, gunicorn threads are never exhausted, so blocking is adequate. True
non-blocking would mean swapping Flask for Quart/FastAPI + aio-pika — a framework change the
assignment doesn't call for. Async here would be gold-plating; I chose the simplest correct option.

**Q: Where does idempotency matter, and where's your idempotency key?**
There's deliberately **no app-level idempotency key**, because the worker is stateless: it does a
pure GET to Open-Meteo and persists nothing. With `prefetch=1` and **manual ack only after the reply
is published**, a worker crash mid-flight just causes redelivery → another worker repeats the
harmless GET → at worst one duplicate reply, which the frontend discards by `correlation_id`.
Idempotency that *is* present is structural: Terraform/Helm/ArgoCD converge declaratively, Ansible
roles guard with `systemctl is-active`, and CI's bump commit carries `[skip ci]`.

---

## B. Infrastructure & sizing

**Q: Why t3.small × 3?**
The project started on free-tier t3.micro × 3, and the 1 GiB nodes were workable but left zero
headroom — every heavy moment (CRD install, repo-server rendering kube-prometheus-stack, Prometheus
startup) was an OOM risk. I applied my own stated mitigation and bumped all three to t3.small
(2 GiB): a few cents per session since the cluster is destroyed after each one, in exchange for a
demo that can't be killed by a scrape burst. The micro-era trims (resource limits, `emptyDir`,
server-side CRD apply) stay in place — they're good hygiene regardless of node size.

**Q: Why the t3 family and not t2?**
t3 is strictly better at the same price point: 2 vCPU vs 1, and it launches in *unlimited* burst
mode (never throttled), whereas t2 launches in *standard* mode and throttles to baseline once
credits drain — which happens during K3s install + image pulls + the first ArgoCD sync, exactly the
worst moment.

**Q: You hit memory pressure. Why not add a 4th node just for Prometheus?**
Because it fixes only half the problem. A 4th node helps the *runtime* memory contention on worker2,
but the two harder risks — the CRD big-bang (an API-server/etcd load on **master**) and
`repo-server` rendering the big chart (on **worker1**) — aren't on the Prometheus node, so a 4th
node doesn't touch them. Bumping all three nodes one size (micro → small) addressed every pressure
point at once; `emptyDir` everywhere (which also deletes the `ignoreDifferences` problem) had
already removed the storage-driven waste. Vertical scaling beat horizontal here.

**Q: Why swap files on Kubernetes nodes? Kubernetes famously wants swap off.**
Deliberate rule-breaking with a reason: a 2G swapfile on **master** (protects the API server/etcd
during heavy helm installs) and on **worker2** (headroom for Prometheus + Grafana). K3s tolerates
swap, and on small nodes an occasionally-slow pod beats an OOM-killed API server. In a production
cluster with properly sized nodes I'd keep swap off and rely on requests/limits alone.

---

## C. Storage & state

**Q: Why `emptyDir` for RabbitMQ and Prometheus instead of PVCs?**
The cluster is destroyed every session, with 6h Prometheus retention on a node that lives ~10 hours.
Persistence survives nothing — the volume is thrown away before the retention window even closes. So
PVCs add cost and complexity for zero benefit. `emptyDir` also removes `volumeClaimTemplates`, which
is what removed the perpetual-OutOfSync `ignoreDifferences` hack entirely.

**Q: So the broker is non-durable — what happens on a RabbitMQ restart?**
All queues and messages are lost. For the RPC pattern that's fine: reply queues are exclusive and die
with their connection anyway, and any in-flight request simply times out and the user retries. I
don't mark queues `durable` or messages persistent, because that would be cargo-culting durability
onto ephemeral storage — the whole stack is consistently ephemeral.

**Q: Why a Deployment for RabbitMQ, not a StatefulSet (the assignment said StatefulSet)?**
A StatefulSet earns its keep via stable identity for PVCs and ordered scaling. With `emptyDir` and a
single replica there's no PVC and no ordering, so the StatefulSet buys nothing — the ClusterIP
Service gives a stable DNS name on its own. The assignment also committed a secret to Git, so "the
assignment said so" isn't a design argument.

**Q: What survives a `terraform destroy`?**
Nothing in-cluster, by design. The only durable artifacts are in **Git** (manifests, Helm chart,
ArgoCD apps, CI workflow), the **Ansible vault** (the encrypted secret value), and **GHCR** (immutable
SHA-tagged images). A fresh cluster reconstructs 100% of runtime state from those three.

---

## D. GitOps

**Q: Is this "fully automated GitOps"?**
Almost — there's exactly one imperative seam: **Ansible installs ArgoCD and applies the root app.**
Something always has to install the GitOps engine. From that point on, both the app and the
monitoring stack reconcile from Git via app-of-apps.

**Q: Explain the app-of-apps and sync-waves.**
A single root Application watches `argocd/apps/` and adopts every child manifest there. Children carry
sync-wave annotations: **wave 0** installs the Prometheus operator CRDs cluster-wide; **wave 1**
deploys skywatch and the monitoring stack. ArgoCD finishes wave 0 (CRDs Established) before starting
wave 1.

**Q: Why the wave split — why not one sync?**
skywatch ships a `ServiceMonitor`, which is a CRD owned by the Prometheus operator. If it synced
before the CRDs existed it would fail with `no matches for kind "ServiceMonitor"`. Wave 0 guarantees
the CRDs land first.

**Q: Why `ServerSideApply=true` on the CRDs app?**
The Prometheus CRDs exceed the 262144-byte client-side `last-applied-configuration` annotation limit;
without server-side apply they fail outright (`metadata.annotations: Too long`). The retry-with-
backoff on that app also paces the apply, which is what the original project did by hand with
`sleep 10` between CRDs — the 1 GiB API server chokes on a big-bang apply.

**Q: Why `skipCrds: true` on the monitoring chart?**
kube-prometheus-stack would otherwise install its own CRDs in a big bang that times out on the small
API server. The CRDs already came from wave 0, so the chart skips them.

**Q: What happens if someone deletes the root app?**
With `prune: true`, deleting the root app cascades: ArgoCD prunes the children it owns, which prune
the resources *they* own — so the app and monitoring get torn down. The hand-created secret survives
(ArgoCD doesn't track it). selfHeal only repairs drift on tracked resources; it doesn't resurrect a
deliberately deleted root. So deletion is a real teardown, not auto-undone — which is acceptable
because Git is still the source of truth and re-applying the root rebuilds everything.

**Q: Why does ArgoCD not prune the secret you created out-of-band?**
Prune only removes resources ArgoCD *tracks* — ones it applied from Git, carrying its tracking
annotation. A hand-created secret has no tracking metadata, so ArgoCD ignores it entirely.

**Q: Is auto-sync on everywhere? Was it always?**
It's on (prune + selfHeal) for all apps now, but the monitoring app had it disabled for a while —
on the t3.micro nodes, selfHeal's constant re-rendering of kube-prometheus-stack hammered
repo-server and the API server. After the move to t3.small I capped `repoServer.resources`
(768Mi limit) and live-tested selfHeal for 18+ minutes — no restarts, low CPU/memory — before
re-enabling it. The point: auto-sync was disabled for a measured reason and re-enabled on evidence,
not vibes.

**Q: How do you know ArgoCD is actually ready before you apply the root app?**
Two gates in the Ansible bootstrap. Gate 1: wait until the `applications.argoproj.io` CRD is
Established — you can't apply an Application before its CRD exists. Gate 1b: wait until
repo-server, redis, and the application-controller all report Ready. Without 1b there's a real
race: the controller can query repo-server seconds before its Service endpoints propagate, get one
"connection refused", and leave the root app stuck at sync status `Unknown` forever — that state
isn't auto-retried, so a human would have to force a hard refresh. Found it by hitting it.

**Q: Why is the ServiceMonitor in the skywatch chart and not the monitoring app?**
Deliberate: the app owns its own observability contract — it declares the target it wants scraped.
The cost is the wave-0→wave-1 dependency, which the sync-waves handle. The alternative (ServiceMonitor
in the monitoring app) decouples skywatch from the operator entirely; I chose app-owns-its-metrics and
made the ordering safe rather than hiding the coupling.

---

## E. Secrets

**Q: Where do secrets enter your GitOps flow?**
They don't enter Git at all. The RabbitMQ secret is pre-provisioned **out-of-band by Ansible** from an
**ansible-vault** encrypted variable, created in the cluster before the app syncs. Plaintext never
touches disk or Git.

**Q: Then why did you delete `rabbitmq-secret.yaml` from the chart?**
If the chart also defined the secret, ArgoCD would render it (with placeholder/empty values) and
`selfHeal` would overwrite my real secret with that placeholder — guaranteed breakage. The chart must
not own a resource that's managed out-of-band.

**Q: Why not Sealed Secrets or SOPS?**
That's the more "pure" GitOps answer and I'd reach for it in production — encrypted secret committed to
Git, decrypted in-cluster by a controller. For this scope I chose vault + out-of-band create to
avoid running an extra controller on already-tight nodes. It's a conscious scope tradeoff, not an
oversight.

**Q: Downside of out-of-band secrets?**
Bootstrap ordering becomes load-bearing: the namespace and secret must exist before the first app
sync, on every from-scratch run. I enforce that with task order in Ansible (namespace → secret → root
app), not by remembering to type steps in order.

---

## F. CI/CD

**Q: Why the `[skip ci]` on the tag-bump commit?**
The CI pushes a commit that edits `values.yaml`; without `[skip ci]` that commit would retrigger CI,
which would push another commit — an infinite loop. `[skip ci]` breaks it.

**Q: Why download the mikefarah `yq` binary instead of `pip install yq`?**
They're two different, incompatible tools with the same name. The Python `yq` is a `jq` wrapper with
different syntax and no real in-place edit; only the Go `mikefarah/yq` supports `yq -i`.

**Q: Why does `values.yaml` track the SHA tag, not `latest`?**
GitOps needs an immutable, reproducible reference. `latest` is a moving pointer — ArgoCD couldn't tell
when it changed, and selfHeal could flap. The `:<sha>` tag is unique per build, so ArgoCD detects the
exact change and rolls deterministically. `latest` is pushed only as a human convenience pointer and
is never referenced by any manifest.

**Q: What does CI do on a pull request vs a push to main?**
PR: lint + build only — no GHCR push of a deploy tag, no bump commit. Push to main: full pipeline
including the bump commit. The `if: github.event_name == 'push'` guards enforce that.

---

## G. Known limitations (state these before they're asked)

- **RabbitMQ is a single-replica SPOF on emptyDir.** Non-durable by design on an ephemeral cluster.
  If the pod restarts, in-flight requests time out and retry; there's no durable state worth keeping.
- **Metrics are session-only.** No long-term Prometheus history — intentional, the node is destroyed
  nightly.
- **The GitOps engine bootstrap is imperative.** Ansible installs ArgoCD; unavoidable, and standard.
- **The cluster costs money now.** Moving off free-tier t3.micro to t3.small was the honest
  mitigation for OOM risk — cents per session against a demo that can't die mid-viva. All chart
  versions are pinned (ArgoCD Helm chart `7.3.11`, `prometheus-operator-crds` `30.0.1`,
  `kube-prometheus-stack` `87.10.1`) — the K3s-OOM lesson applied to charts.
- **Headroom is still finite.** 2 GiB nodes, with 2G swap on master (API server safety during helm
  bursts) and worker2 (Prometheus + Grafana margin). Every component carries explicit
  requests/limits; the stack fits with room to spare, but it isn't sized for real traffic.

---

## H. The 60-second summary (if they ask you to pitch the whole thing)
A weather-query pipeline where the *app* is deliberately trivial so the *delivery pipeline* can be the
star: Terraform provisions three t3.small nodes, Ansible installs K3s and bootstraps ArgoCD, GitHub
Actions builds SHA-tagged images to GHCR and commits the tag bump, and ArgoCD reconciles everything —
app and monitoring — from Git via app-of-apps with sync-waves. Every stateful piece is `emptyDir`
because the cluster is cattle, not pets: nothing in-cluster is meant to survive a destroy, and
everything needed to rebuild it lives in Git, an encrypted vault, and an image registry. The one
broker is RPC-style request/response, the one secret is out-of-Git by design, and the small-node
constraints are met with deliberate engineering (explicit resource limits on every component, TCP
probes, server-side CRD apply, readiness gates in the bootstrap, swap as a safety net) — with one
honest concession to reality: bumping micro to small when 1 GiB proved to be a demo-killing risk.
