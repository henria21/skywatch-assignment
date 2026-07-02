# SkyWatch Assignment — Claude Context

## What this is
DevOps course assignment: a weather-query pipeline deployed via full GitOps on AWS K3s.
3× t3.micro EC2 instances (master + worker1 + worker2). Extremely resource-constrained.

## Cluster architecture
- **master** (skywatch-master): K3s server + etcd. 2G swap added for stability.
- **worker1** (skywatch-worker): K3s agent. Runs ArgoCD pods.
- **worker2** (skywatch-worker2): K3s agent. Runs all app pods (nodeSelector enforced).

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
- t3.micro has 1 GiB RAM — K3s crashes under heavy load. Swap helps but doesn't eliminate it.
- `prometheus-operator-crds` with `ServerSideApply=true` crashes the API server. **ServerSideApply is disabled** in `argocd/apps/prometheus-crds.yaml`.
- ArgoCD auto-sync is disabled on `monitoring` and `prometheus-crds` apps to prevent constant API hammering.
- `skywatch-worker2` is a Kubernetes node hostname — do NOT rename it.
- The ansible `.vault_pass` file must live on the Linux filesystem (not `/mnt/c/`) due to WSL/NTFS permission issues. Use `--ask-vault-pass` or `~/vault_pass`.

## App pods
All 5 pods run on `skywatch-worker2` via nodeSelector (`kubernetes.io/hostname: skywatch-worker2`):
- frontend ×2 (NodePort 30080) — ArgoCD uses 30082/30083
- worker ×2 (connects to RabbitMQ)
- rabbitmq ×1

Workers crash on startup until RabbitMQ is ready — this is normal, they recover.

## After fresh cluster — manual steps needed
1. Enable auto-sync on `prometheus-crds` once (to install CRDs), then it self-manages
2. Trigger manual sync of `skywatch-assignment` if it's in backoff after 5 failed retries:
   ```bash
   kubectl patch application skywatch-assignment -n argocd --type merge \
     -p '{"operation":{"initiatedBy":{"username":"kubectl"},"sync":{"revision":"HEAD"}}}'
   ```

## GitOps loop
Push to `main` → GitHub Actions bumps image tag in `values.yaml` → ArgoCD auto-deploys within ~3 min.
