# 06 — ArgoCD App-of-Apps (GitOps root + children + sync-waves)

**Goal:** one root Application (applied by Ansible) that owns three children — Prometheus CRDs
(wave 0), skywatch (wave 1), monitoring (wave 1) — so ArgoCD manages the app **and** observability.
**Prereqts:** files 04 (ArgoCD installed) and 05 (skywatch chart in Git).
**Done when:** the root app is Synced+Healthy, all three children appear, and a CI tag-bump commit
rolls a new image automatically within ~3 minutes.

This is the structure that shrinks the imperative surface to exactly two acts (install ArgoCD, apply
root) — both done by Ansible.

---

## Layout

```
argocd/
  root-app.yaml
  apps/
    prometheus-crds.yaml      # wave 0
    skywatch.yaml             # wave 1
    monitoring.yaml           # wave 1
```

## `root-app.yaml` — the one thing Ansible applies
Points at `argocd/apps/` with directory recursion: drop a child manifest in that folder and ArgoCD
adopts it.
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: skywatch-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/henria21/skywatch-assignment
    targetRevision: main
    path: argocd/apps
    directory: { recurse: true }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
```

## `apps/prometheus-crds.yaml` — WAVE 0
Installs **only** the Prometheus operator CRDs, cluster-wide, before anything references them.
`ServerSideApply=true` is **mandatory** (the CRDs exceed the client-side last-applied annotation
limit and otherwise fail with `metadata.annotations: Too long`). Retry-with-backoff is the paced
apply that the assignment did by hand with `sleep 10`.
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus-crds
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: prometheus-operator-crds
    targetRevision: "*"          # pin to a real version in practice
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
    retry:
      limit: 5
      backoff: { duration: 10s, factor: 2, maxDuration: 2m }
```

## `apps/skywatch.yaml` — WAVE 1
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: skywatch-assignment
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://github.com/henria21/skywatch-assignment
    targetRevision: main
    path: helm/skywatch-assignment
  destination:
    server: https://kubernetes.default.svc
    namespace: skywatch-assignment
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
    # NO ignoreDifferences — no PVCs to diff anymore.
```

## `apps/monitoring.yaml` — WAVE 1
kube-prometheus-stack with `helm.skipCrds: true` (CRDs come from wave 0). Full values live in file 07.
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "*"          # pin in practice
    helm:
      skipCrds: true             # CRDs already applied by wave 0
      valueFiles: []             # inline values OR reference helm/monitoring/values.yaml (file 07)
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
    retry:
      limit: 5
      backoff: { duration: 15s, factor: 2, maxDuration: 3m }
```
> To use a values file from your own repo for monitoring, switch this child to a **multi-source**
> Application (one source = the chart, one = your repo with `helm/monitoring/values.yaml`). For
> scope, inline `helm.values:` is simpler — see file 07.

## Why the wave split is non-negotiable
- skywatch's `ServiceMonitor` (file 05) is a CRD owned by the operator. If skywatch synced before the
  CRDs, that resource dies with `no matches for kind "ServiceMonitor"`.
- The monitoring chart would normally install its own CRDs in a big bang that times out the 1 GiB
  API server. `skipCrds: true` + a dedicated wave-0 CRD app with ServerSideApply + retry solves both.

## The watch-this failure mode on 1 GiB
`argocd-repo-server` (pinned to worker1) runs `helm template` to render kube-prometheus-stack, which
is a **large** chart. If repo-server OOMs mid-render you get a cryptic `comparison failed` with no
obvious cause. Give repo-server a memory request/limit in the ArgoCD Helm values (file 04) and check
there first if monitoring won't sync.

## Done when

- `kubectl get applications -n argocd` shows `skywatch-root`, `prometheus-crds`, `skywatch-assignment`,
  `monitoring` — root Synced+Healthy.
- Wave 0 reaches Healthy **before** wave 1 starts (watch the ArgoCD UI sync order).
- App reachable at `http://<worker2-public-ip>:30080`.
- Push a trivial change → CI bumps the tag → ArgoCD rolls the new image within ~3 min, zero manual
  steps. That round trip is the core GitOps proof.
