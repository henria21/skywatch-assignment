# 07 — Observability (Prometheus + Grafana)

**Goal:** kube-prometheus-stack running slim on t3.small nodes, Prometheus on **emptyDir**, Grafana
on NodePort 30090, and RabbitMQ metrics scraped via the ServiceMonitor from file 05.
**Prereqts:** file 06 (the `monitoring` child app + wave-0 CRDs).
**Done when:** Grafana loads at `http://<worker2-ip>:30090`, and a dashboard shows RabbitMQ queue
depth and node memory.

This is delivered **through ArgoCD** (the `monitoring` child app), not by a manual `helm install`.
Everything below is the values for that child app.

---

## Monitoring values (inline in `apps/monitoring.yaml` `helm.values`)

```yaml
prometheus:
  prometheusSpec:
    retention: 6h
    # NO storageSpec -> Prometheus falls back to emptyDir (session-only metrics, by design)
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

alertmanager:
  alertmanagerSpec:
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 100m, memory: 64Mi }

prometheusOperator:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 200m, memory: 128Mi }

grafana:
  service:
    type: NodePort
    nodePort: 30090
  adminPassword: admin
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 200m, memory: 256Mi }

kube-state-metrics:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }

nodeExporter:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { cpu: 100m, memory: 64Mi }
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
#   http://<worker2-public-ip>:30090  (admin / admin)
#   import 10991 -> queue depth changes as you submit cities through the app
```
