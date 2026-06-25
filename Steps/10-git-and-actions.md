# 10 — Git & GitHub Actions (setup + operational gotchas)

File 02 has the workflow YAML. This file covers everything *around* it: repo setup, the `.gitignore`
that keeps you from leaking secrets, why the CI push doesn't loop, the branch-protection trap, and how
ArgoCD reads the repo. Read this before the first `git push`.

---

## Step 1 — Repo init & structure

```bash
git init -b main
git remote add origin https://github.com/henria21/skywatch-assignment.git
```
Final tree (matches the runbooks):
```
skywatch-assignment/
├── .github/workflows/ci.yml
├── .gitignore
├── .flake8
├── docker-compose.yml
├── app/{frontend,worker}/
├── terraform/
├── ansible/
├── helm/skywatch-assignment/
└── argocd/{root-app.yaml,apps/}
```

## Step 2 — `.gitignore` (do this BEFORE the first commit)

The single highest-risk thing in this project is committing a secret or state file. This list is not
optional.
```gitignore
# Terraform — state contains secrets in plaintext
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.*
terraform/*.tfvars
terraform/.terraform.lock.hcl   # optional: keep this one if you want pinned providers

# Ansible — generated inventory + the kubeconfig + vault password
ansible/inventory.ini
kubeconfig
.vault_pass
*.vault_pass*

# SSH keys
*.pem

# Python
__pycache__/
*.pyc
.venv/
.env
```
> The **ansible-vault file itself** (`group_vars/all/vault.yml`) **is committed** — it's encrypted.
> What must NEVER be committed is the **vault password** that decrypts it (`.vault_pass`). Different
> things. Encrypted-in-Git is fine; the password is not.

Verify nothing sensitive is staged before the first commit:
```bash
git add -A && git status
git ls-files | grep -E 'tfstate|tfvars|kubeconfig|\.pem|vault_pass' && echo "STOP — leak" || echo "clean"
```

## Step 3 — GHCR package permissions (one-time, after first successful push)

1. The workflow already requests `permissions: packages: write` — the default `GITHUB_TOKEN` can push
   to GHCR under the same owner with no extra secret.
2. After the first push, both packages default to **private**. In the repo's *Packages* settings, set
   `skywatch-assignment-frontend` and `skywatch-assignment-worker` to **Public**, and link each package to the repo. Public
   = K3s pulls them with no `imagePullSecret` (the chart has none — keep it that way).

## Step 4 — How the CI push does NOT create an infinite loop

Two independent safeguards, and it's worth knowing which one is actually load-bearing:

1. **GitHub's own loop-prevention (the real one):** a `git push` authenticated with the default
   `GITHUB_TOKEN` does **not** trigger another `on: push` workflow run. So the tag-bump commit, pushed
   with `GITHUB_TOKEN`, can't retrigger CI — by GitHub's design.
2. **`[skip ci]` in the commit message (belt-and-suspenders):** this only matters if you ever switch
   to pushing with a **Personal Access Token** instead of `GITHUB_TOKEN` (see Step 6), because PAT
   pushes *do* retrigger. Keep `[skip ci]` so the loop is prevented under both auth methods.

Net: with `GITHUB_TOKEN`, you're safe even without `[skip ci]`; with a PAT, `[skip ci]` is what saves
you. Keeping both is correct.

## Step 5 — The branch-protection trap (this will silently break the bump)

If you protect `main` (require PR / require reviews / disallow direct pushes), the CI's `git push` of
the tag-bump commit is **rejected** — and the failure can be quiet. Three ways out, pick one:

- **(a) Don't protect `main`.** Fine for a solo course project; trunk-based. Simplest.
- **(b) Protect `main` but allow the bump path.** Add a bypass for the actor doing the push, or have
  CI open a PR with the bump instead of pushing directly (then auto-merge). More moving parts.
- **(c) Protect `main`, push the bump to a separate branch** that ArgoCD tracks. Decouples human PRs
  from machine commits, but now your GitOps `targetRevision` isn't `main`.

Recommendation for this project: **(a)**. State it in the defense as a deliberate scope choice
("solo repo, trunk-based; in a team I'd use option (b) with a PR-based bump").

## Step 6 — `GITHUB_TOKEN` vs PAT

- Default `GITHUB_TOKEN`: enough to push to GHCR and to push commits to an **unprotected** branch. No
  setup. Use this.
- A **PAT** (stored as an Actions secret) is only needed if main is protected and you must bypass
  protection, or if you push to a different repo. PAT pushes *do* retrigger workflows → `[skip ci]`
  becomes mandatory. Avoid unless Step 5 forces it.

## Step 7 — Serialize runs so two fast pushes don't collide

The bump commit does `git push`; if `main` moved between checkout and push (two pushes close
together), the push fails non-fast-forward. Add a concurrency gate and a rebase-before-push:
```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: false      # queue, don't cancel — we don't want a half-finished push
```
and in the commit step, before `git push`:
```bash
git pull --rebase origin main || true
git push
```
> `cancel-in-progress: false` matters: cancelling a run mid-push could leave `values.yaml` bumped
> locally but not pushed. Queue them instead.

## Step 8 — ArgoCD's view of the repo (the GitOps read path)

The CI *writes* to Git; ArgoCD *reads* from it. Two cases:
- **Public repo:** ArgoCD needs no credentials. The `repoURL` in `root-app.yaml` / child apps just
  works. Keep the repo public and this is zero-config.
- **Private repo:** ArgoCD must be given repo read access — add a repository credential (an
  `argocd-repo-creds`/repository Secret in the `argocd` namespace, labelled
  `argocd.argoproj.io/secret-type: repository`, holding a deploy key or PAT). If you go private, add
  this to the Ansible bootstrap (file 04) **before** the root app is applied, or ArgoCD reports the
  source unreachable.

Recommendation: **public repo** for the course — simplest, and there are no secrets in Git anyway
(that's the whole point of file 09 §E).

## Step 9 — Optional hardening (cheap defense points)

- **Pin third-party actions to a commit SHA**, not a moving tag (`docker/build-push-action@<sha>`).
  Supply-chain hygiene; an examiner may ask.
- **`workflow_dispatch:`** trigger so you can re-run the pipeline manually without a code change —
  handy when demoing the GitOps rollout on a fresh cluster.
- **Build cache:** add `cache-from: type=gha` / `cache-to: type=gha,mode=max` to the build-push steps
  to speed repeat builds. Optional.

## The end-to-end loop (say this out loud in the demo)

```
dev: git push (code) ─▶ Actions: lint → build → push :sha to GHCR
                                   └▶ yq bumps values.yaml ─▶ bot commit [skip ci]
                                                                   │ (GITHUB_TOKEN push: no retrigger)
                                                                   ▼
                                              ArgoCD sees helm/skywatch/values.yaml change on main
                                                                   ▼
                                              rolls the new :sha image to skywatch ns (~3 min)
```
The human commits code; a machine commits the resulting image tag; ArgoCD turns that tag into a
running pod. No `kubectl` in the loop — that's the GitOps proof.

## Done when
- First commit contains **no** tfstate/tfvars/kubeconfig/pem/vault-password (Step 2 check passes).
- A push to `main` → green CI → both GHCR packages exist and are Public → bump commit appears →
  **no** second CI run is triggered.
- A PR runs lint+build only, creates no commit.
- ArgoCD shows the repo as `Successful`/connected (Settings → Repositories in the UI).
