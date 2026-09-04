# MinIO Virtual Lab Setup

## Overview

This guide deploys a **MinIO** container that:
- Runs in the **same Docker network as your k3d SAS Viya deployment** (namespace `edu`)
- Exposes a standard S3 API on port `9000`
- Is reachable by SAS Viya pods at `http://minio:9000` (by container hostname)
- Uses logical region name **`lux`** matching the Eurostat LFS SAS code

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Docker Desktop / Docker Engine | ≥ 24 | Running and accessible |
| k3d | ≥ 5 | SAS Viya cluster already deployed in namespace `edu` |
| Docker Compose plugin | ≥ 2.20 | `docker compose version` |

---

## Step 1 — Find Your k3d Network Name

k3d creates a Docker bridge network for each cluster. Find it:

```bash
docker network ls | grep k3d
```

Example output:
```
NETWORK ID     NAME          DRIVER    SCOPE
a3f1c2d4e5b6   k3d-viya      bridge    local
```

The network name is `k3d-viya` (pattern: `k3d-<cluster-name>`).

---

## Step 2 — Set the Network Name

Export the variable before running Compose (or add it to a `.env` file):

```bash
# Option A — shell export
export K3D_NETWORK=k3d-viya

# Option B — .env file in the same directory as docker-compose.yml
echo "K3D_NETWORK=k3d-viya" > .env
```

---

## Step 3 — Start MinIO

```bash
cd 02-minio-setup

# Start MinIO in the background
docker compose up -d

# Watch logs until healthy
docker compose logs -f minio
```

Expected output when ready:
```
minio  | API: http://minio:9000  http://172.20.0.5:9000
minio  | Console: http://minio:9001  http://172.20.0.5:9001
minio  | Documentation: https://min.io/docs/minio/linux/index.html
minio  | Status: 1 Online, 0 Offline.
```

---

## Step 4 — Create Buckets

Run the one-shot init container to create the LFS buckets:

```bash
docker compose run --rm minio-init
```

This creates:
- `lfs-acc-01` — input data bucket (mirrors the Eurostat `/lfs-acc-01` path)
- `lfs-output-01` — results bucket

---

## Step 5 — Upload Sample Data (Optional)

Use the `mc` (MinIO Client) tool to upload test files:

```bash
# Attach to the mc tool via a temporary container
docker run --rm -it \
  --network ${K3D_NETWORK:-k3d-viya} \
  quay.io/minio/mc:RELEASE.2024-06-10T16-44-15Z \
  /bin/sh

# Inside the container:
mc alias set local http://minio:9000 minioadmin minioadmin
mc cp /path/to/dicofile.sas7bdat local/lfs-acc-01/dataiess/minidb/quar/dicofile.sas7bdat
mc ls local/lfs-acc-01/dataiess/minidb/quar/
```

Or from your Windows host (no extra container needed):

```powershell
# Download mc for Windows from https://dl.min.io/client/mc/release/windows-amd64/mc.exe
.\mc.exe alias set local http://localhost:9000 minioadmin minioadmin
.\mc.exe cp .\dicofile.sas7bdat local/lfs-acc-01/dataiess/minidb/quar/dicofile.sas7bdat
```

---

## Step 6 — Register Credentials in SAS Viya

SAS Viya stores S3 credentials in its **Credential Store** so they never appear in SAS code.
Run this once as a SAS Administrator in SAS Studio or the SAS Environment Manager API:

```sas
/* -----------------------------------------------------------------------
   Register MinIO credentials in the SAS Viya Credential Store.
   Run as an Administrator once per environment.
   Replace access_key / secret_key with your MinIO credentials.
   ----------------------------------------------------------------------- */

proc pwencode in='minioadmin' method=sas002;   /* encode the secret for the log */
run;

/* Use SAS Environment Manager UI:
   Administration → Security → Credentials
   → New Credential Domain

   Domain ID  : LFS_S3_Auth
   Domain Type: AWS
   Profile    : P01
   Access Key : minioadmin          (MinIO root user or dedicated service account)
   Secret Key : minioadmin          (MinIO root password or dedicated secret)
*/
```

Alternatively use the SAS Viya REST API or the `sas-admin` CLI:

```bash
# sas-admin CLI (run from a machine with access to SAS Viya)
sas-admin --profile viya credentials create-domain \
  --domain-id  LFS_S3_Auth \
  --domain-type AWS \
  --description "MinIO LFS credentials" \
  --access-key minioadmin \
  --secret-key minioadmin
```

---

## Network Topology

```
┌─────────────────────────────────────────────────────┐
│  Docker network: k3d-viya                           │
│                                                     │
│  ┌─────────────────┐      ┌───────────────────┐    │
│  │  k3d node(s)    │      │  minio container  │    │
│  │  namespace: edu │      │  hostname: minio  │    │
│  │                 │      │  port: 9000 (API) │    │
│  │  SAS Viya pods  │─────▶│  port: 9001 (UI)  │    │
│  │  (Compute, CAS) │      │  region:  lux     │    │
│  └─────────────────┘      └───────────────────┘    │
│                                    │                │
└────────────────────────────────────│────────────────┘
                                     │
                              ┌──────▼──────┐
                              │  Host port  │
                              │  9000/9001  │
                              │  (browser,  │
                              │   mc tool)  │
                              └─────────────┘
```

SAS Viya pods reach MinIO at:
```
http://minio:9000
```

Your browser / Windows host reaches MinIO at:
```
http://localhost:9000   (API)
http://localhost:9001   (Console UI)
```

---

## Verify Connectivity from a SAS Pod

```bash
# Get a shell inside any running SAS pod
kubectl exec -it -n edu deployment/sas-compute-server -- /bin/bash

# Test MinIO reachability
curl -I http://minio:9000/minio/health/live
# Expected: HTTP/1.1 200 OK
```

---

## Tear Down

```bash
docker compose down          # stop containers, keep data volume
docker compose down -v       # stop containers AND delete data volume
```
