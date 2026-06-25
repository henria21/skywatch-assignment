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

# 3. Let ArgoCD reconcile (wave 0 CRDs -> wave 1 app+monitoring). Watch, don't sleep:
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=180s
kubectl -n skywatch rollout status deploy/skywatch-frontend --timeout=180s
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=240s

# 4. Use it
#    App:     http://<worker2-public-ip>:30080
#    ArgoCD:  https://<master-public-ip>:30081
#    Grafana: http://<worker2-public-ip>:30030

# 5. Teardown (stay in free tier)
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
