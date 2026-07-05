# Spec/assignment.md vs. this repo — differences and reasoning

`Spec/assignment.md` describes an earlier/different variant of this course project (student
"Yariv Freifeld", repo `yfreifeld/skywatch`). This repo (`henria21/skywatch-assignment`) diverged
from it in several ways. This file records what differs and why, so the divergence reads as
deliberate rather than as documentation drift.

## Identity
- Author/repo: Spec says "Yariv Freifeld" / `github.com/yfreifeld/skywatch`. This repo is
  `henria21/skywatch-assignment`.
- Repo/chart paths: Spec uses `helm/skywatch/`, single `argocd/application.yaml`. This repo uses
  `helm/skywatch-assignment/` and an app-of-apps layout (`argocd/root-app.yaml` + `argocd/apps/*.yaml`).
- Resource names: Spec's secret is `skywatch-rabbitmq` in namespace `skywatch`. This repo's is
  `skywatch-assignment-rabbitmq` in namespace `skywatch-assignment`. Pure renaming, no behavior change.
- Images: Spec pushes `ghcr.io/<owner>/skywatch-frontend`/`skywatch-worker`. This repo pushes
  `ghcr.io/henria21/skywatch-assignment-frontend`/`-worker`.

## Changes forced by real constraints (verified in git history / commit messages)

| # | Change | Evidence | Verdict |
|---|---|---|---|
| 1 | Instance type **t3.micro → t3.small** (all 3 nodes) | Commits `24f34b9` ("prevent ArgoCD OOM crashes"), `4944e3d`/`d87db60` ("for monitoring stability") | Forced — repeated real OOM crashes on 1GB nodes running K3s+etcd+ArgoCD+kube-prometheus-stack |
| 2 | ArgoCD NodePort **30081 → 30082/30083** | This repo started on 30081 (commit `18e0c03`, matching Spec), then `13c87e5`/`a70d636` moved it after it collided with the frontend's NodePort 30080 | Forced — genuine port conflict, not a renumber for style |

## Deliberate improvements (sound engineering reasoning, not forced)

| # | Change | Reasoning |
|---|---|---|
| 3 | ArgoCD placement: Spec's 7 manual `kubectl patch` commands → this repo's single Helm `--set global.nodeSelector...` flag via Ansible | Declarative, reapplied on every playbook run instead of a one-off imperative patch that drifts on rebuild |
| 4 | RabbitMQ: Spec's **StatefulSet + PVC** (+ `ignoreDifferences` workaround for perpetual OutOfSync) → this repo's **Deployment + emptyDir**, no `ignoreDifferences` | The cluster is destroyed every session — the PVC bought zero real durability and only existed to be worked around. Removing both is strictly simpler with no functional loss. See [../Steps/05-helm-skywatch.md](../Steps/05-helm-skywatch.md). |
| 5 | Prometheus CRDs: Spec's manual `for crd in ...; kubectl apply --server-side; sleep 10` loop → this repo's dedicated `prometheus-crds` ArgoCD Application at sync-wave 0 with `ServerSideApply=true` + retry/backoff | Same server-side-apply requirement, now GitOps-managed and automatic instead of a manual per-session step |
| 6 | Alertmanager: Spec disables it entirely ("saves ~100MB RAM" on t3.micro) → this repo enables it with a 32Mi/64Mi request/limit | Justified by the t3.micro→t3.small RAM doubling; the slim limit can't reintroduce the original pressure that forced the original disable |
| 7 | Prometheus retention: Spec's **24h** → this repo's **6h** | Spec's own text assumes ~10h sessions before `terraform destroy`; 6h still covers any realistic in-session query window with less TSDB footprint on emptyDir. See [../Steps/00-START-HERE.md](../Steps/00-START-HERE.md) and [../Steps/07-observability.md](../Steps/07-observability.md). |

## Arbitrary (no forced reason) — reverted to match Spec this session

| # | Change | Notes |
|---|---|---|
| 8 | Grafana NodePort **30030 → 30090** | 30030 never actually existed in this repo except in earlier prose; Grafana went straight to 30090 (commit `409604b`) with no stated conflict — no port collision, just an unexplained pick. Since it wasn't forced by anything, **reverted to 30030** (matching Spec) in `argocd/apps/monitoring.yaml`, `CLAUDE.md`, and `Steps/00`, `Steps/07`, `Steps/08`. Confirmed no conflict: the security group opens the full NodePort range 30000-32767 (`terraform/main.tf`), and 30030 wasn't used anywhere else in the repo. |

## Regression — identified and fixed this session

| # | Change | Status |
|---|---|---|
| 9 | ArgoCD version pin: Spec pinned `v2.11.2` via a raw manifest URL. This repo's Ansible bootstrap task had **no version pin** on the `argo-cd` Helm chart (`targetRevision`/chart version was implicitly "latest"), same for `prometheus-crds` and `monitoring` (`targetRevision: "*"`) | **Fixed.** Pinned `argo-cd` chart `7.3.11` (ships ArgoCD v2.11.7 — same minor line the repo's own [../Steps/04-ansible.md](../Steps/04-ansible.md) already documented as the target) in `ansible/roles/bootstrap/tasks/main.yml`; pinned `prometheus-operator-crds` to `30.0.1` and `kube-prometheus-stack` to `87.10.1` (same underlying operator app version, so CRDs and operator stay compatible) in `argocd/apps/prometheus-crds.yaml` and `argocd/apps/monitoring.yaml`. Unpinned `"*"` meant every fresh cluster could silently pull a different version — a reproducibility risk on a "twice-from-scratch" grading gate. |

## Other doc/code mismatches fixed this session (not Spec-related, found separately)

- `CLAUDE.md` claimed `ServerSideApply` was *disabled* on `prometheus-crds` and that auto-sync was
  disabled on *both* `monitoring` and `prometheus-crds`. In reality `argocd/apps/prometheus-crds.yaml`
  has `ServerSideApply=true` **and** auto-sync enabled; only `monitoring` has auto-sync disabled.
  Corrected in `CLAUDE.md`.
- `Steps/05-helm-skywatch.md` showed the nodeSelector value as `skywatch-assignment-worker2`; the
  actual hostname (set by Ansible, `--node-name skywatch-{{ node_role }}`) and the real
  `helm/skywatch-assignment/values.yaml` both use `skywatch-worker2`. Corrected in the Steps doc.

## `monitoring` auto-sync disabled — investigated, not re-enabled

Git history (`bf87156`, `7f9a7d5`, `7702fe3`, all 2026-07-01/02) shows this toggled three times
while **worker1 was still t3.micro**: disabled once with zero resource limits on the chart,
briefly re-enabled with still-zero limits, then disabled again in the *same commit* that finally
added the slim per-component resource limits. Worker1 wasn't upgraded to t3.small until
`24f34b9`, two hours after the last disable — auto-sync was never retested after that RAM bump.

So the original constraint (worker1 hosting both the ArgoCD control plane and the monitoring
pods on 1GB) is plausibly resolved by the t3.small upgrade, but this was never verified live.
One contributing risk Steps/06 itself flagged was still open until this session: `argocd-repo-server`
had no explicit memory request/limit, despite rendering the large kube-prometheus-stack chart on
every reconcile. **Fixed:** added `repoServer.resources` (100m/256Mi request, 500m/768Mi limit) to
the ArgoCD Helm install in `ansible/roles/bootstrap/tasks/main.yml` and documented it in
`Steps/04-ansible.md` and `Steps/06-argocd-app-of-apps.md`.

Auto-sync on `monitoring` itself is left **disabled** — re-enabling it should only happen after a
live test on a real cluster, which needs a `terraform apply` run to verify.
