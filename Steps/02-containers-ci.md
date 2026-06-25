# 02 — Containers, GHCR & CI

**Goal:** every push to `main` lints, builds both images, pushes to GHCR, and bumps the image tags
in `helm/skywatch/values.yaml` via an automated commit.
**Prereqts:** file 01 passing; a GitHub repo at `henria21/skywatch-assignment`.
**Done when:** one push produces two GHCR images tagged with the commit SHA, and a follow-up
auto-commit updates `values.yaml` — without triggering an infinite CI loop.

---

## Step 1 — Multi-stage Dockerfiles

`app/frontend/Dockerfile`:
```dockerfile
FROM python:3.11-slim AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "-w", "4", "--threads", "4", "app:app"]
```

`app/worker/Dockerfile`:
```dockerfile
FROM python:3.11-slim AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "worker.py"]
```

> Keep images public so K3s needs no `imagePullSecret`. (GHCR packages default to private — after
> the first push, set `skywatch-assignment-frontend` and `skywatch-assignment-worker` to **Public** in the repo's Packages settings.)

## Step 2 — flake8 config

`.flake8`:
```ini
[flake8]
max-line-length = 120
exclude = .git,__pycache__
```

## Step 3 — `.github/workflows/ci.yml`

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: write        # needed for the tag-bump commit
  packages: write        # needed to push to GHCR

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Lint
        run: |
          pip install flake8
          flake8 app/frontend/app.py app/frontend/rpc_client.py app/worker/worker.py

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute short SHA
        id: sha
        run: echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - name: Build & push frontend
        uses: docker/build-push-action@v6
        with:
          context: ./app/frontend
          push: true
          tags: |
            ghcr.io/henria21/skywatch-assignment-frontend:${{ steps.sha.outputs.tag }}
            ghcr.io/henria21/skywatch-assignment-frontend:latest

      - name: Build & push worker
        uses: docker/build-push-action@v6
        with:
          context: ./app/worker
          push: true
          tags: |
            ghcr.io/henria21/skywatch-assignment-worker:${{ steps.sha.outputs.tag }}
            ghcr.io/henria21/skywatch-assignment-worker:latest

      # Only bump + commit on pushes to main, never on PRs
      - name: Update Helm image tags
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
          chmod +x /usr/local/bin/yq
          yq -i '.frontend.image.tag = "${{ steps.sha.outputs.tag }}"' helm/skywatch-assignment/values.yaml
          yq -i '.worker.image.tag   = "${{ steps.sha.outputs.tag }}"' helm/skywatch-assignment/values.yaml

      - name: Commit tag bump
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          git config user.name  "ci-bot"
          git config user.email "ci-bot@users.noreply.github.com"
          if ! git diff --quiet helm/skywatch-assignment/values.yaml; then
            git commit -am "ci: bump image tags to ${{ steps.sha.outputs.tag }} [skip ci]"
            git push
          fi
```

## Why each guard exists (don't remove them)

- **`[skip ci]`** breaks the loop: the bump commit would otherwise retrigger CI forever.
- **`if: github.event_name == 'push'...`** keeps PRs to lint+build only — PRs must never push a
  bump commit.
- **`git diff --quiet`** makes the commit step idempotent: re-running with no real change is a no-op,
  not an empty commit.
- **mikefarah `yq` via wget**, not `pip install yq` — they are two different incompatible tools that
  share a name; only the Go binary supports `yq -i` in-place edits.
- **deploy the `:<sha>` tag, never `:latest`** in `values.yaml`. `latest` is pushed only as a
  convenience pointer; ArgoCD must track the immutable SHA for reproducible, self-healing rollouts.

## Done when

- A push to `main` yields `ghcr.io/henria21/skywatch-assignment-frontend:<sha>` and `-worker:<sha>` in GHCR.
- A second auto-commit appears: `ci: bump image tags to <sha> [skip ci]`.
- That bump commit does **not** start another CI run (check the Actions tab — no new run).
- Open a PR with a no-op change → CI lints+builds but creates **no** commit.
