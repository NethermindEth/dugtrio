# Dugtrio Fanout Scheduler — Build & Staging Deploy Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Docker image from the completed `feat/race-scheduler` branch via GitHub Actions (pushing to JFrog), open a PR to merge the feature into dugtrio `master`, then deploy via ArgoCD to OVH staging (`angkor-rpc-gateway` namespace).

**Architecture:** Two separate PRs — one in the dugtrio repo (code + GHA workflow), one in the argocd repo (deployment). Image is built by GitHub Actions using the shared `NethermindEth/github-workflows` workflow and pushed to JFrog `angkor-oci-local-staging`. ArgoCD uses the `ethpandaops/ethereum-helm-charts` dugtrio chart which mounts config via ConfigMap. The `fanoutPaths` setting routes blob-sidecar requests to all ready endpoints in a race.

**Tech Stack:** Go 1.25, Docker, `ethereum-helm-charts` dugtrio chart v0.0.7, Kustomize, ArgoCD, OVH staging cluster.

---

## Task 1: Verify tests pass on feat/race-scheduler

**Files:**
- Read: `proxy/racecall_test.go`, `pool/beaconpool_test.go`

**Step 1: Run full test suite with race detector**

```bash
cd .
go test -race ./...
```

Expected: all tests PASS, no race conditions detected.

**Step 2: Verify build**

```bash
go build ./...
```

Expected: PASS with no errors or warnings.

---

## Task 2: Add GHA docker build/push workflow to dugtrio

**Files:**
- Create: `.github/workflows/docker-build-push.yml`

**Step 1: Create the workflow file**

```yaml
name: Docker Build and Push

on:
  push:
    branches: [feat/race-scheduler]
  workflow_dispatch:

permissions:
  id-token: write
  attestations: write
  contents: read

jobs:
  build:
    uses: NethermindEth/github-workflows/.github/workflows/docker-build-push-jfrog.yaml@main
    with:
      repo_name: "angkor-oci-local-staging"
      image_name: "dugtrio"
      context: "."
      dockerfile_path: "./Dockerfile"
      run_trivy: false
```

**Step 2: Commit the workflow file**

```bash
cd .
git add .github/workflows/docker-build-push.yml
git commit -m "chore(dugtrio): add GHA docker build/push workflow for staging"
```

**Step 3: Push branch to trigger the workflow**

```bash
git push origin feat/race-scheduler
```

Expected: GHA workflow `Docker Build and Push` is triggered on GitHub Actions.

**Step 4: Wait for the workflow to complete and note the image tag**

```bash
gh run list --workflow=docker-build-push.yml --limit 1
gh run watch
```

Expected: workflow completes successfully. The image is pushed to:
`nethermind.jfrog.io/angkor-oci-local-staging/dugtrio:<tag>`

Note the exact image tag from the GHA run output — it will be used in Task 5.

---

## Task 3: Open PR for dugtrio feature branch

**Step 1: Verify branch is up to date**

```bash
cd .
git status
git log --oneline master..HEAD
```

Expected: clean working tree, all feature commits listed.

**Step 2: Push branch to remote**

```bash
git push origin feat/race-scheduler
```

**Step 3: Create PR**

```bash
gh pr create \
  --title "chore(dugtrio): add fanout scheduler for latency-sensitive beacon paths" \
  --body "Fans out matching requests to all ready endpoints and returns first 2xx response, reducing p99 latency on blob-sidecar fetches on the block proposal path." \
  --base master \
  --head feat/race-scheduler
```

Expected: PR URL printed. Note it for reference.

---

## Task 4: Create ArgoCD deployment branch

**Step 1: Switch to argocd repo and sync main**

```bash
cd ~/argocd
git checkout main
git pull origin main
```

Expected: local main is up to date.

**Step 2: Create fresh feature branch**

```bash
git checkout -b chore/dugtrio-ovh-staging-rpc-gateway
```

---

## Task 5: Add dugtrio kustomization and values

**Upstream endpoints:**
- **beacon-1** (primary): `http://l1-stack-hoodi-execution-beacon-fallback-0.l1-stack-hoodi-execution-beacon-fallback:5052` — direct beacon API on the Hoodi lighthouse pod (headless service, bypasses HAProxy).
- **beacon-2** (secondary): QuickNode Hoodi beacon URL from the existing `l1-stack-hoodi-secrets` K8s secret (key: `FALLBACK_BEACON_URL`), synced from Infisical path `/apps/rpc-gateway/l1-stack-hoodi`.

**Prerequisite — env var expansion in dugtrio config (dugtrio PR):**

dugtrio does not expand env vars in its YAML config by default. Add `os.ExpandEnv` in `utils/config.go` before YAML decode so `$VAR` refs in the config file are resolved at startup:

```go
// in readConfigFile, after os.ReadFile:
content = []byte(os.ExpandEnv(string(content)))
```

This allows `url: "$QUICKNODE_HOODI_BEACON_URL"` in the config to be resolved from the pod's env.

**Files:**
- Create: `ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio/kustomization.yaml`
- Create: `ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio/values.yaml`

**Step 1: Create the directory**

```bash
mkdir -p ~/argocd/ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio
```

**Step 2: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: angkor-rpc-gateway

helmCharts:
  - name: dugtrio
    repo: https://ethpandaops.github.io/ethereum-helm-charts
    version: 0.0.7
    releaseName: dugtrio
    namespace: angkor-rpc-gateway
    valuesFile: values.yaml
```

**Step 3: Create values.yaml**

The QN URL is injected via `extraEnv` from the existing `l1-stack-hoodi-secrets` secret and expanded in the config via `os.ExpandEnv` (see prerequisite above).

```yaml
image:
  repository: nethermind.jfrog.io/angkor-oci-local-staging/dugtrio
  tag: "REPLACE_WITH_TAG_FROM_GHA"
  pullPolicy: Always
imagePullSecrets:
  - name: artifactory-secret-angkor

extraEnv:
  - name: QUICKNODE_HOODI_BEACON_URL
    valueFrom:
      secretKeyRef:
        name: l1-stack-hoodi-secrets
        key: FALLBACK_BEACON_URL

config: |
  logging:
    outputLevel: "info"
  server:
    host: "0.0.0.0"
    port: "8080"
  endpoints:
    - name: local-hoodi-beacon
      url: "http://l1-stack-hoodi-execution-beacon-fallback-0.l1-stack-hoodi-execution-beacon-fallback:5052"
    - name: quicknode-hoodi-beacon
      url: "$QUICKNODE_HOODI_BEACON_URL"
  pool:
    schedulerMode: "rr"
    followDistance: 10
    maxHeadDistance: 2
  proxy:
    callTimeout: 10s
    sessionTimeout: 10m
    stickyEndpoint: true
    fanoutPaths:
      - "^/eth/v1/beacon/blob_sidecars/.*"
  frontend:
    enabled: true
    title: "Dugtrio (staging)"
  metrics:
    enabled: true

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

service:
  type: ClusterIP
```

**Step 4: Replace the image tag placeholder**

```bash
IMAGE_TAG=<tag from GHA output>
gsed -i "s/REPLACE_WITH_TAG_FROM_GHA/${IMAGE_TAG}/" \
  ~/argocd/ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio/values.yaml
```

**Step 5: Verify kustomize renders cleanly**

```bash
cd ~/argocd
kubectl kustomize \
  ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio \
  --enable-helm
```

Expected: rendered Kubernetes manifests printed (StatefulSet, ConfigMap, Service, ServiceAccount). No errors.

---

## Task 6: Commit and open ArgoCD PR

**Step 1: Commit the deployment files**

```bash
cd ~/argocd
git add ovh/clusters/apps-staging-1/angkor-rpc-gateway/dugtrio/
git commit -m "chore(dugtrio): deploy fanout scheduler to OVH staging rpc-gateway"
```

**Step 2: Push branch**

```bash
git push origin chore/dugtrio-ovh-staging-rpc-gateway
```

**Step 3: Create PR**

```bash
gh pr create \
  --repo NethermindEth/argocd \
  --title "chore(dugtrio): deploy fanout scheduler to OVH staging rpc-gateway" \
  --body "Adds Dugtrio beacon proxy with fanout scheduler to OVH staging, targeting angkor-rpc-gateway namespace. Image built via GHA and pushed to angkor-oci-local-staging." \
  --base main \
  --head chore/dugtrio-ovh-staging-rpc-gateway
```

Expected: PR URL printed.

---

## Task 7: Verify ArgoCD sync (post-merge)

After both PRs are merged:

**Step 1: Check ArgoCD application is created**

```bash
kubectl config use-context ovh-apps-staging-1
kubectl get application -n argocd | grep dugtrio
```

Expected: application `apps-stg-1-angproj232-dugtrio` appears.

**Step 2: Check pod is running**

```bash
kubectl get pods -n angkor-rpc-gateway | grep dugtrio
```

Expected: `dugtrio-0` pod in `Running` state.

**Step 3: Smoke-test the proxy**

```bash
DUGTRIO_POD=$(kubectl get pod -n angkor-rpc-gateway -l app.kubernetes.io/name=dugtrio -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n angkor-rpc-gateway $DUGTRIO_POD -- \
  wget -qO- http://localhost:8080/eth/v1/node/version
```

Expected: JSON response with beacon node version from one of the configured endpoints.
