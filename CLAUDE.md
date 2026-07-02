# SkyWatch Assignment — Claude Context

## What this is
DevOps course assignment: a weather-query pipeline deployed via full GitOps on AWS K3s.
3× t3.small EC2 instances (master + worker1 + worker2). Resource-constrained.

## Cluster architecture
- **master** (skywatch-master): t3.small. K3s server + etcd. 2G swap added for stability.
- **worker1** (skywatch-worker): t3.small. Runs ArgoCD pods + monitoring stack.
- **worker2** (skywatch-worker2): t3.small. Runs all app pods (nodeSelector enforced).

## To spin up the cluster
```bash
cd terraform && terraform apply
cd ../ansible && ansible-playbook playbook.yml -i inventory.ini --ask-vault-pass
```

## To tear down
```bash
cd terraform && terraform destroy
```

## Security — NEVER commit
- `terraform.tfstate`, `terraform.tfvars`
- `ansible/.vault_pass`
- `*.pem` / kubeconfig files
- `group_vars/all/vault.yml` is committed (encrypted); vault PASSWORD is never committed

## GHCR images must remain PUBLIC — no imagePullSecret in the Helm chart

## Known issues / constraints
- `prometheus-operator-crds` with `ServerSideApply=true` crashes the API server on small clusters. **ServerSideApply is disabled** in `argocd/apps/prometheus-crds.yaml`.
- ArgoCD auto-sync is disabled on `monitoring` and `prometheus-crds` apps to prevent constant API hammering.
- `skywatch-worker2` is a Kubernetes node hostname — do NOT rename it.
- The ansible `.vault_pass` file must live on the Linux filesystem (not `/mnt/c/`) due to WSL/NTFS permission issues. Use `--ask-vault-pass` or `~/vault_pass`.
- Always `git pull --rebase` before `git push` — CI creates tag-bump commits between pushes.

## App pods
All 5 pods run on `skywatch-worker2` via nodeSelector (`kubernetes.io/hostname: skywatch-worker2`):
- frontend ×2 (NodePort **30080**)
- worker ×2 (connects to RabbitMQ)
- rabbitmq ×1

Workers crash on startup until RabbitMQ is ready — this is normal, they recover.

## Monitoring (kube-prometheus-stack on worker2)
- Grafana: NodePort **30090** — login `admin` / `admin`
- Prometheus: ClusterIP only (9090)
- Alertmanager: ClusterIP only (9093)
- `monitoring` app auto-sync is disabled in git; sync manually from ArgoCD UI when needed

## ArgoCD
- HTTP NodePort **30082**, HTTPS **30083** (on worker1)
- Dex and notifications disabled to save RAM

## After fresh cluster — manual steps needed
1. `prometheus-crds` has auto-sync enabled — CRDs install automatically on first sync
2. Trigger manual sync of `skywatch-assignment` via ArgoCD UI if it's stuck in backoff
3. Sync `monitoring` manually from ArgoCD UI (auto-sync disabled to prevent API hammering)

## GitOps loop
Push to `main` → GitHub Actions bumps image tag in `values.yaml` → ArgoCD auto-deploys within ~3 min.
