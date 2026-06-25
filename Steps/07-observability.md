# 07 — Observability (Prometheus + Grafana)

**Goal:** kube-prometheus-stack running slim on worker2, Prometheus on **emptyDir**, Alertmanager
off, Grafana on NodePort 30030, and RabbitMQ metrics scraped via the ServiceMonitor from file 05.
**Prereqts:** file 06 (the `monitoring` child app + wave-0 CRDs).
**Done when:** Grafana loads at `http://<worker2-ip>:30030`, and a dashboard shows RabbitMQ queue
depth and node memory.

This is delivered **through ArgoCD** (the `monitoring` child app), not by a manual `helm install`.
Everything below is the values for that child app.

---

## Monitoring values (inline in `apps/monitoring.yaml` `helm.values`, or `helm/monitoring/values.yaml`)

```yaml
# Alertmanager off — saves ~100Mi on a 1Gi node, and we have no alert routes.
alertmanager:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 24h
    retentionSize: 400MB          # hard cap so emptyDir can't fill worker2's disk
    # NO storageSpec -> Prometheus falls back to emptyDir (session-only metrics, by design)
    nodeSelector:
      kubernetes.io/hostname: skywatch-worker2
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
    # Select ServiceMonitors with this release label (matches file 05's label)
    serviceMonitorSelector:
      matchLabels: { release: kube-prometheus-stack }

grafana:
  nodeSelector:
    kubernetes.io/hostname: skywatch-worker2
  service:
    type: NodePort
    nodePort: 30030
  adminPassword: "skywatch-grafana"
  resources:
    requests: { cpu: 50m, memory: 96Mi }
    limits:   { cpu: 200m, memory: 128Mi }
  persistence:
    enabled: false                 # session-only; consistent with the rest of the stack

# node-exporter is a DaemonSet across all 3 nodes by default — keep it; it's cheap and gives
# the node-memory panels you'll demo.

# Trim components you won't demo to save RAM (optional but recommended on 1Gi):
kubeStateMetrics:
  enabled: true
prometheusOperator:
  resources:
    limits: { cpu: 200m, memory: 200Mi }
```

## Why these choices
- **emptyDir Prometheus** removes the StatefulSet PVC that would otherwise reintroduce the perpetual
  OutOfSync you killed by dropping `ignoreDifferences`. Persistence buys nothing on a node destroyed
  nightly with 24h retention.
- **`retentionSize: 400MB`** is the safety cap: emptyDir lives on the node's disk, and a runaway TSDB
  on a 1Gi box is a real way to wedge worker2 at hour 9. At your scrape volume (a handful of targets)
  the TSDB is only megabytes — the cap is insurance, not a constraint you'll hit.
- **`serviceMonitorSelector`** must match the label you put on the ServiceMonitor (file 05:
  `release: kube-prometheus-stack`). If queue metrics don't show up, this label mismatch is the first
  thing to check.

## RabbitMQ metrics path (sanity check)
`rabbitmq:3.13-management` enables the `rabbitmq_prometheus` plugin by default → exposes `:15692`.
The Service (file 05) names that port `prometheus`. The ServiceMonitor (file 05) scrapes
`port: prometheus`. Prometheus selects the ServiceMonitor via the release label. Chain complete.

## Grafana dashboards to import (IDs)
- **RabbitMQ-Overview** (Grafana.com dashboard `10991`) — queue depth, message rates, consumers.
- **Node Exporter Full** (`1860`) — per-node CPU/memory; shows worker2 under load.
- Kubernetes cluster dashboards ship with the stack.

## Done when

```bash
# Prometheus targets healthy
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
#   open :9090/targets -> skywatch-rabbitmq target is UP
# Grafana
#   http://<worker2-public-ip>:30030  (admin / skywatch-grafana)
#   import 10991 -> queue depth changes as you submit cities through the app
```
