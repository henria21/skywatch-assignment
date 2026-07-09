#!/usr/bin/env bash
set -e

INVENTORY="$(dirname "$0")/ansible/inventory.ini"

WORKER1=$(grep "node_role=worker$" "$INVENTORY" | awk '{print $1}')
WORKER2=$(grep "node_role=worker2" "$INVENTORY" | awk '{print $1}')

# kubectl lives inside WSL (snap); from Git Bash go through a WSL login shell
if command -v kubectl &>/dev/null; then
  kc() { kubectl "$@"; }
else
  kc() { wsl.exe -e bash -lc "kubectl $*"; }
fi
ARGOCD_PASS=$(kc get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

HTML="$(dirname "$0")/links.html"
cat > "$HTML" <<EOF
<!DOCTYPE html>
<html>
<head><title>SkyWatch Links</title>
<style>
  body { font-family: sans-serif; max-width: 600px; margin: 60px auto; background: #111; color: #eee; }
  h1 { color: #7cf; }
  a { display: block; margin: 16px 0; padding: 14px 20px; background: #1e1e2e; border-radius: 8px;
      color: #7cf; text-decoration: none; font-size: 1.1em; border: 1px solid #333; }
  a:hover { background: #2a2a3e; }
  .note { color: #888; font-size: 0.85em; margin-top: 4px; }
</style>
</head>
<body>
<h1>SkyWatch — Current Session</h1>
<a href="http://${WORKER2}:30080" target="_blank">Frontend — http://${WORKER2}:30080</a>
<a href="http://${WORKER1}:30082" target="_blank">ArgoCD — http://${WORKER1}:30082</a>
<p class="note">ArgoCD login: admin / ${ARGOCD_PASS:-run: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath=\'{.data.password}\' | base64 -d}</p>
<a href="http://${WORKER2}:30030" target="_blank">Grafana — http://${WORKER2}:30030</a>
<p class="note">Grafana login: admin / admin</p>
</body>
</html>
EOF

echo "Generated: $HTML"
echo ""
echo "  Frontend : http://${WORKER2}:30080"
echo "  ArgoCD   : http://${WORKER1}:30082  (admin / ${ARGOCD_PASS:-<see kubectl command>})"
echo "  Grafana  : http://${WORKER2}:30030  (admin / admin)"

# Open in browser (WSL uses wslpath, Git Bash uses cygpath)
if command -v explorer.exe &>/dev/null; then
  # explorer.exe returns 1 even on success
  if command -v wslpath &>/dev/null; then
    explorer.exe "$(wslpath -w "$HTML")" || true
  elif command -v cygpath &>/dev/null; then
    explorer.exe "$(cygpath -w "$HTML")" || true
  fi
fi
