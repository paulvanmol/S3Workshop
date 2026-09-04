# Using SAS Viya with On-Premise S3 Storage

## What is On-Premise S3?

Amazon S3 (Simple Storage Service) is an object storage API that has become an industry standard.
While AWS offers the original cloud implementation, many organisations — including Eurostat — run
**S3-compatible object storage on-premise** using software such as **MinIO**. MinIO is
open-source, S3-API compatible, and can run as a Docker container or Kubernetes pod alongside your
SAS Viya deployment.

From SAS Viya's perspective the storage looks identical to AWS S3: the same credentials model, the
same bucket/key path structure, and the same API calls. The key difference is the **endpoint URL**,
which points to your internal MinIO server instead of `s3.amazonaws.com`.

---

## Why Use S3 with SAS Viya?

| Use case | Benefit |
|---|---|
| Shared input datasets | Teams load raw survey files once; SAS jobs read directly from the bucket |
| Results archival | Processed output is written back to S3, decoupling storage from compute |
| Pipeline integration | Non-SAS tools (Python, R, Spark) share the same data lake via S3 |
| Cost efficiency | Object storage is cheaper than SAS SPDE or shared NFS for large files |

---

## SAS Viya Interfaces for S3

SAS Viya provides three complementary ways to interact with S3 storage:

### 1. PROC S3 (SAS Compute)
A SAS procedure that runs in the **SAS 9 / Compute Server** session. It supports:
- `GET` — download an object from S3 to the local filesystem (e.g. `WORK`)
- `PUT` — upload a file from the local filesystem to S3
- `DELETE` — remove an object from a bucket
- `LIST` — list objects in a bucket/prefix

```sas
proc s3 region="lux" authdomain="LFS_S3_Auth" credentialsprofile="P01";
  get  "s3://lfs-acc-01/dataiess/minidb/quar/dicofile.sas7bdat"
       "/tmp/saswork/dicofile.sas7bdat";
  put  "/tmp/saswork/results.sas7bdat"
       "s3://lfs-acc-01/output/results.sas7bdat";
run;
```

### 2. FILENAME S3 (SAS Compute)
A SAS fileref engine that lets you read/write S3 objects **as if they were local files** using the
standard SAS data step I/O. Useful for reading CSV or text objects without first downloading them.

```sas
filename mycsv s3 "s3://lfs-acc-01/data/survey.csv"
                  region="lux"
                  authdomain="LFS_S3_Auth"
                  credentialsprofile="P01";

data work.survey;
  infile mycsv dsd firstobs=2;
  input id year quarter age $ ...;
run;
```

### 3. CASLIB S3 (CAS)
A **CAS library** backed by S3 lets the CAS engine load data directly from object storage into
in-memory tables, bypassing the Compute filesystem entirely. This is the highest-performance path
for large analytical datasets.

```sas
cas mysession;
caslib lfs_s3 datasource=(srctype="s3",
                           region="lux",
                           bucket="lfs-acc-01",
                           credentialsdomain="LFS_S3_Auth",
                           credentialsprofile="P01",
                           endpointurl="http://minio.minio.svc.cluster.local:9000");

proc casutil incaslib="lfs_s3";
  load casdata="dataiess/minidb/quar/dicofile.sas7bdat" casout="dicofile";
run;
```

---

## Authentication — Credential Profiles

SAS Viya stores S3 credentials (access key + secret key) in its **Credential Store**, not in code.
This keeps secrets out of SAS programs.

Three parameters govern authentication:

| Parameter | Purpose | Example |
|---|---|---|
| `AUTHDOMAIN` | Named domain in SAS Viya credential store | `LFS_S3_Auth` |
| `CREDENTIALSPROFILE` | AWS-style profile name within the credential | `P01` |
| `REGION` | Logical region name — can be any string for on-premise | `lux` |

For on-premise MinIO you additionally need to supply the **endpoint URL** so SAS does not try to
reach `s3.amazonaws.com`. This is done differently per interface:

- **PROC S3**: `endpointurl="http://minio-host:9000"`
- **FILENAME S3**: `endpointurl="http://minio-host:9000"`
- **CASLIB S3**: `endpointurl=` inside `datasource=()` option

---

## Typical LFS Workflow

```
MinIO Bucket (lfs-acc-01)
   └── dataiess/minidb/
         ├── quar/          ← quarterly reference files
         └── annu/          ← annual micro-data

           ↓  PROC S3 GET
      SAS WORK (local)
         ├── DICOIESS/      ← dictionaries + formats
         └── MDBQUAR/       ← mini-database by year

           ↓  SAS programs run
      SAS WORK (local)
         └── output/

           ↓  PROC S3 PUT
MinIO Bucket (lfs-acc-01)
   └── output/              ← results uploaded back
```

---

## Differences from AWS S3

| Aspect | AWS S3 | On-Premise MinIO |
|---|---|---|
| Endpoint | `https://s3.eu-west-1.amazonaws.com` | `http://minio.minio.svc.cluster.local:9000` |
| Region | Real AWS region code (`eu-west-1`) | Any string you configure (`lux`) |
| TLS | Required | Optional (often HTTP in lab) |
| Credentials | IAM roles / access keys | MinIO access key + secret key |
| Pricing | Per GB stored + per request | On-premise infrastructure cost |

The SAS code is **identical** except for the endpoint URL and region string. This makes it easy to
move from on-premise to cloud or back without rewriting programs.

---

## Next Steps

1. **02-minio-setup** — Deploy a MinIO container in the same Docker/k3d network as SAS Viya
2. **03-sas-compute** — PROC S3 and FILENAME S3 examples for SAS Compute sessions
3. **04-cas** — CASLIB S3 examples for CAS in-memory analytics
4. **05-lfs-macros** — Full LFS macro library adapted from the Eurostat production code
