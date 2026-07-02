# 08 — Validate & Teardown (the grading gate)

**Goal:** prove the whole thing comes up from nothing, twice, and tears down cleanly. Re-runnability
is itself a grading criterion — and it's exactly what your "destroy-every-session" workflow needs.
**Prereqts:** files 01–07 all committed to Git.
**Done when:** two independent from-scratch runs both reach a working app + Grafana, and
`terraform destroy` leaves nothing behind.

---

## The full session quick-start (one ordered sequence)

```bash
# 1. Infra (~2 min)
cd terraform && terraform apply -auto-approve

# 2. K3s + ArgoCD + secret + root app (~4 min) — single playbook, idempotent
cd ../ansible && ansible-playbook -i inventory.ini playbook.yml --ask-vault-pass
export KUBECONFIG=$(pwd)/../kubeconfig

# 3. Wait for CRDs and app (auto-synced by ArgoCD):
until kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; do echo "$(date +%H:%M:%S) waiting for CRDs..."; sleep 10; done && echo "CRDs ready"
kubectl -n skywatch-assignment rollout status deploy/skywatch-assignment-frontend --timeout=180s

# 4. Generate clickable links (reads inventory.ini + fetches ArgoCD password automatically)
cd .. && bash show-links.sh
#    Opens links.html in browser with current IPs for Frontend, ArgoCD, Grafana
cd ansible

# 5. Open ArgoCD UI and sync 'monitoring' manually (auto-sync disabled to prevent API hammering)
#    Click monitoring → Sync → Synchronize

# 6. Wait for monitoring pods to come up (~5-10 min):
until kubectl get applications -n argocd 2>/dev/null | grep "^monitoring" | grep -q "Synced.*Healthy"; do echo "$(date +%H:%M:%S) waiting..."; sleep 10; done && echo "monitoring ready"

# 7. Use it
#    App:     http://<worker2-public-ip>:30080
#    Grafana: http://<worker2-public-ip>:30090  (admin / admin)

# 8. Pre-destroy sanity check — wait for Grafana then confirm everything is green
until kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null | grep -q "3/3.*Running"; do echo "$(date +%H:%M:%S) waiting for Grafana..."; sleep 10; done && echo "Grafana ready"
kubectl get applications -n argocd
kubectl get pods -n skywatch-assignment
kubectl get pods -n monitoring
#   All 4 apps: Synced + Healthy
#   All 5 app pods: Running
#   All monitoring pods: Running
#   Frontend works:  http://<worker2-public-ip>:30080
#   Grafana works:   http://<worker2-public-ip>:30090

# 9. Teardown (stay in free tier)
cd ../terraform && terraform destroy -auto-approve
```

## Readiness gates (the three "don't proceed until Ready" checkpoints)

| Gate | What you wait on | Failure if skipped |
|---|---|---|
| 1 | `applications.argoproj.io` CRD Established + ArgoCD controller/repo/redis Ready | `kubectl apply root-app` fails: `no matches for kind "Application"` |
| 2 | Root app **Synced+Healthy** (covers wave 0 → wave 1) | skywatch ServiceMonitor errors: `no matches for kind "ServiceMonitor"` |
| 3 | frontend Deployment Available + Prometheus pod Ready | "demo works on my machine" but the projector shows CrashLoop |

Gate 1 is enforced inside the Ansible bootstrap (file 04). Gates 2–3 are the `kubectl wait` lines
above.

## Twice-from-scratch checklist (run the quick-start, destroy, run it again)

- [ ] Run 1: app returns weather for "Tokyo", "London", a non-existent city errors gracefully.
- [ ] Run 1: Grafana RabbitMQ dashboard shows queue activity while you submit cities.
- [ ] Run 1: push a code change → CI bumps tag → ArgoCD rolls it within ~3 min, no manual step.
- [ ] `terraform destroy` removes all 3 instances + SG; `terraform state list` is empty.
- [ ] Run 2 (fresh IPs): everything above passes again with **zero manual edits** to any file.
- [ ] Re-running `ansible-playbook` on the live Run-2 cluster reports nothing **changed**.

If Run 2 needs a manual fix that Run 1 didn't, that fix belongs in code — find it and commit it.

## "What survives a destroy?" — the answer to have ready
Nothing in-cluster survives, and that's intentional. The only durable artifacts are:
- **Git:** all manifests, the Helm chart, the ArgoCD apps, the CI workflow.
- **Ansible vault:** the RabbitMQ secret value (encrypted, never in Git, never plaintext on disk).
- **GHCR:** the built images (immutable, SHA-tagged).

A fresh cluster reconstructs 100% of runtime state from those three. The broker is non-durable and
metrics are session-only — by design, because the node dies nightly.

## Common cold-start failures and where to look first

| Symptom | First suspect |
|---|---|
| Worker can't reach master:6443 | inventory used public IP — must be master **private** IP |
| `kubectl` TLS error from laptop | `--tls-san <public_ip>` missing at install (file 04) |
| Frontend/worker CrashLoop on boot | secret name/keys mismatch, or namespace created after secret |
| `no matches for kind "ServiceMonitor"` | wave ordering broke — CRDs (wave 0) not Healthy before skywatch |
| `metadata.annotations: Too long` on CRDs | `ServerSideApply=true` missing on prometheus-crds app |
| monitoring app stuck `comparison failed` | repo-server OOM rendering the big chart — bump its memory |
| ArgoCD shows skywatch OutOfSync forever | a PVC or `rabbitmq-secret.yaml` crept back into the chart |
| Grafana has no RabbitMQ metrics | ServiceMonitor `release:` label ≠ `serviceMonitorSelector` |

## Defense one-liners (memorize)
- **Why RabbitMQ for a synchronous lookup?** "It's pedagogical decoupling for the course and a real
  Prometheus scrape target; for this workload it's overhead, and I say so."
- **Is it fully automated GitOps?** "One imperative seam: Ansible installs ArgoCD and applies the
  root app. After that, app and monitoring both reconcile from Git."
- **Where do secrets enter GitOps?** "They don't. Pre-provisioned out-of-Git by Ansible from an
  encrypted vault. Sealed Secrets if I wanted them Git-managed."
- **What's your SPOF?** "RabbitMQ, single replica, emptyDir — non-durable by design on an ephemeral
  cluster; in-flight requests just time out and retry."
