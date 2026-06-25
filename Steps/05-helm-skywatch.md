# 05 — Helm Chart (`helm/skywatch-assignment`)

**Goal:** the app chart — frontend (NodePort 30080), worker ×2, RabbitMQ as a **Deployment** on
**emptyDir**, a ServiceMonitor, and the secret consumed by `envFrom`/`secretKeyRef`.
**Prereqts:** the secret name contract (file 00). The secret itself is created by Ansible (file 04),
**not** by this chart.
**Done when:** `helm template helm/skywatch-assignment` renders with no errors and contains no
`rabbitmq-secret.yaml` and no `volumeClaimTemplates`.

> **Three things deliberately absent from this chart** (do not add them back):
> 1. `rabbitmq-secret.yaml` — Ansible creates it out-of-band; a template here would let selfHeal
>    overwrite the real secret with a placeholder.
> 2. `volumeClaimTemplates` / PVCs — RabbitMQ runs on `emptyDir`.
> 3. No `ignoreDifferences` anywhere (that lived in the ArgoCD Application, file 06) — there are no
>    PVCs left to diff.

---

## Layout

```
helm/skywatch-assignment/
  Chart.yaml
  values.yaml
  templates/
    _helpers.tpl
    frontend-deployment.yaml
    frontend-service.yaml
    worker-deployment.yaml
    rabbitmq-deployment.yaml
    rabbitmq-service.yaml
    servicemonitor.yaml
```

## `Chart.yaml`
```yaml
apiVersion: v2
name: skywatch-assignment
description: SkyWatch weather pipeline
version: 0.1.0
appVersion: "1.0"
# No dependencies — RabbitMQ is inline templates (Bitnami subchart was removed; its images
# were pulled from Docker Hub. Official rabbitmq:3.13-management is used directly.)
```

## `values.yaml`
CI rewrites the two `tag` fields (file 02).
```yaml
frontend:
  image: { repository: ghcr.io/henria21/skywatch-assignment-frontend, tag: latest }
  replicas: 2
  nodePort: 30080
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 250m, memory: 128Mi }

worker:
  image: { repository: ghcr.io/henria21/skywatch-assignment-worker, tag: latest }
  replicas: 2
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 250m, memory: 128Mi }

rabbitmq:
  image: rabbitmq:3.13-management
  resources:
    requests: { cpu: 100m, memory: 200Mi }
    limits:   { cpu: 400m, memory: 350Mi }

# Pin the whole app to worker2
nodeSelector:
  kubernetes.io/hostname: skywatch-assignment-worker2

secretName: skywatch-assignment-rabbitmq
rabbitmqHost: skywatch-assignment-rabbitmq   # = the ClusterIP Service name
```

## `templates/_helpers.tpl`
```yaml
{{- define "skywatch-assignment.rabbitEnv" -}}
- name: RABBITMQ_HOST
  value: {{ .Values.rabbitmqHost | quote }}
- name: RABBITMQ_USERNAME
  valueFrom: { secretKeyRef: { name: {{ .Values.secretName }}, key: rabbitmq-username } }
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ .Values.secretName }}, key: rabbitmq-password } }
{{- end -}}
```

## `templates/rabbitmq-deployment.yaml`
**Deployment, not StatefulSet** (no PVC → no need for stable identity). **emptyDir** for `/var/lib/rabbitmq`.
**TCP probe** on 5672 (the exec `rabbitmq-diagnostics ping` stalls when the memory watermark alarm
fires on a 1 GiB node).
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skywatch-assignment-rabbitmq
  labels: { app.kubernetes.io/name: skywatch-assignment-rabbitmq }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: skywatch-assignment-rabbitmq } }
  template:
    metadata: { labels: { app.kubernetes.io/name: skywatch-assignment-rabbitmq } }
    spec:
      nodeSelector: {{ .Values.nodeSelector | toYaml | nindent 8 }}
      containers:
        - name: rabbitmq
          image: {{ .Values.rabbitmq.image }}
          envFrom:
            - secretRef: { name: {{ .Values.secretName }} }   # RABBITMQ_DEFAULT_USER/PASS
          ports:
            - { name: amqp, containerPort: 5672 }
            - { name: management, containerPort: 15672 }
            - { name: prometheus, containerPort: 15692 }
          readinessProbe:
            tcpSocket: { port: 5672 }
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: 5672 }
            initialDelaySeconds: 30
            periodSeconds: 20
          resources: {{ .Values.rabbitmq.resources | toYaml | nindent 12 }}
          volumeMounts:
            - { name: data, mountPath: /var/lib/rabbitmq }
      volumes:
        - name: data
          emptyDir: {}        # non-durable broker — by design
```

## `templates/rabbitmq-service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: skywatch-assignment-rabbitmq
  labels: { app.kubernetes.io/name: skywatch-assignment-rabbitmq }
spec:
  selector: { app.kubernetes.io/name: skywatch-assignment-rabbitmq }
  ports:
    - { name: amqp, port: 5672, targetPort: 5672 }
    - { name: management, port: 15672, targetPort: 15672 }
    - { name: prometheus, port: 15692, targetPort: 15692 }
```

## `templates/frontend-deployment.yaml` (worker is the same pattern, no service/ports)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: skywatch-assignment-frontend }
spec:
  replicas: {{ .Values.frontend.replicas }}
  selector: { matchLabels: { app: skywatch-assignment-frontend } }
  template:
    metadata: { labels: { app: skywatch-assignment-frontend } }
    spec:
      nodeSelector: {{ .Values.nodeSelector | toYaml | nindent 8 }}
      containers:
        - name: frontend
          image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
          ports: [{ containerPort: 5000 }]
          env: {{ include "skywatch-assignment.rabbitEnv" . | nindent 12 }}
          readinessProbe: { httpGet: { path: /healthz, port: 5000 }, initialDelaySeconds: 5 }
          resources: {{ .Values.frontend.resources | toYaml | nindent 12 }}
```
> `worker-deployment.yaml`: identical shape, `name: skywatch-assignment-worker`, `replicas:
> {{ .Values.worker.replicas }}`, the worker image, the same `skywatch-assignment.rabbitEnv`, **no ports, no
> readinessProbe** (it's a consumer, not a server).

## `templates/frontend-service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata: { name: skywatch-assignment-frontend }
spec:
  type: NodePort
  selector: { app: skywatch-assignment-frontend }
  ports:
    - { port: 5000, targetPort: 5000, nodePort: {{ .Values.frontend.nodePort }} }
```

## `templates/servicemonitor.yaml`
Scrapes RabbitMQ's built-in Prometheus endpoint (`rabbitmq_prometheus` plugin, port 15692, on by
default in the `-management` image).
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: skywatch-assignment-rabbitmq
  labels: { release: kube-prometheus-stack }   # so the stack's Prometheus selects it
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: skywatch-assignment-rabbitmq }
  endpoints:
    - { port: prometheus, interval: 30s }
```
> **Cross-app dependency note (see file 06):** this `ServiceMonitor` is a CRD owned by the Prometheus
> operator. It only resolves if the Prometheus CRDs exist first. That is exactly why the CRDs are a
> separate **sync-wave 0** app and skywatch is **wave 1**. We keep the ServiceMonitor here (skywatch
> declares its own scrape target); the wave ordering makes it safe.

## Done when

```bash
helm template helm/skywatch-assignment | grep -c "kind: PersistentVolumeClaim"   # -> 0
helm template helm/skywatch-assignment | grep -c "rabbitmq-secret"               # -> 0
helm lint helm/skywatch-assignment                                                # passes
```
