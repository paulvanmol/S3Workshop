/* =============================================================================
   SAS Compute — PROC S3 and FILENAME S3 Examples
   On-Premise MinIO connected to SAS Viya (k3d, namespace: edu)

   Prerequisites:
     - MinIO running and reachable at http://minio:9000 (inside cluster)
       or http://localhost:9000 (from your workstation)
     - Credential domain "LFS_S3_Auth" with profile "P01" registered in
       the SAS Viya Credential Store (see 02-minio-setup/minio-setup.md)
     - Buckets lfs-acc-01 and lfs-output-01 exist in MinIO

   All examples use macro variables at the top so only one block needs
   editing when moving between environments (lab → production).
============================================================================= */


/* -----------------------------------------------------------------------------
   0. Global macro variables — edit here to switch environments
----------------------------------------------------------------------------- */
%let s3_region      = lux;
%let s3_authd       = LFS_S3_Auth;
%let s3_credentials = P01;
%let s3_endpoint    = http://minio:9000;          /* cluster-internal URL      */
/* %let s3_endpoint = http://localhost:9000; */   /* use this from workstation */

%let S3LFS          = /lfs-acc-01;                /* input  bucket             */
%let S3OUT          = /lfs-output-01;             /* output bucket             */


/* =============================================================================
   SECTION 1 — PROC S3
   Downloads and uploads SAS datasets (sas7bdat) between S3 and WORK.
============================================================================= */


/* -----------------------------------------------------------------------------
   1a. LIST objects in a bucket prefix
----------------------------------------------------------------------------- */
proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";
  list "&S3LFS/dataiess/minidb/quar/";
run;


/* -----------------------------------------------------------------------------
   1b. GET — download one SAS dataset from S3 into WORK
----------------------------------------------------------------------------- */
proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";
  get "&S3LFS/dataiess/minidb/quar/dicofile.sas7bdat"
      "&WORK/dicofile.sas7bdat";
run;

/* Verify the download */
proc contents data=work.dicofile; run;


/* -----------------------------------------------------------------------------
   1c. GET — download multiple files (dictionary set)
----------------------------------------------------------------------------- */
proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";

  get "&S3LFS/dataiess/minidb/quar/dicofile.sas7bdat"  "&WORK/dicofile.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/dicodisa.sas7bdat"  "&WORK/dicodisa.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/dicoadhoc.sas7bdat" "&WORK/dicoadhoc.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/formats.sas7bcat"   "&WORK/formats.sas7bcat";

run;


/* -----------------------------------------------------------------------------
   1d. PUT — upload a result dataset from WORK back to S3
----------------------------------------------------------------------------- */

/* First create a small example output dataset */
data work.survey_results;
  set work.dicofile(obs=10);
run;

proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";
  put "&WORK/survey_results.sas7bdat"
      "&S3OUT/output/survey_results.sas7bdat";
run;


/* -----------------------------------------------------------------------------
   1e. DELETE — remove an object from S3
----------------------------------------------------------------------------- */
proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";
  delete "&S3OUT/output/survey_results.sas7bdat";
run;


/* =============================================================================
   SECTION 2 — FILENAME S3
   Stream S3 objects as file references — useful for CSV, JSON, and text files
   without needing to download first.
============================================================================= */


/* -----------------------------------------------------------------------------
   2a. Read a CSV directly from S3 into a SAS dataset
----------------------------------------------------------------------------- */
filename lfs_csv s3 "&S3LFS/data/survey_sample.csv"
                    region            = "&s3_region"
                    authdomain        = "&s3_authd"
                    credentialsprofile= "&s3_credentials"
                    endpointurl       = "&s3_endpoint";

data work.survey_csv;
  infile lfs_csv dsd firstobs=2 truncover;
  /* adjust INPUT statement to match your CSV columns */
  input country     : $2.
        year        : 4.
        quarter     : 1.
        hhseqnum    : 8.
        age         : 3.
        sex         : 1.
        empstat     : $2.;
run;

filename lfs_csv clear;


/* -----------------------------------------------------------------------------
   2b. Write a text/log file directly to S3 via FILENAME S3
----------------------------------------------------------------------------- */
filename s3log s3 "&S3OUT/logs/run_log.txt"
                  region            = "&s3_region"
                  authdomain        = "&s3_authd"
                  credentialsprofile= "&s3_credentials"
                  endpointurl       = "&s3_endpoint";

data _null_;
  file s3log;
  put "LFS processing run completed: " "%sysfunc(datetime(), datetime20.)";
  put "Records processed: " _n_;
run;

filename s3log clear;


/* -----------------------------------------------------------------------------
   2c. Read a JSON metadata file from S3
----------------------------------------------------------------------------- */
filename lfs_meta s3 "&S3LFS/config/run_config.json"
                     region            = "&s3_region"
                     authdomain        = "&s3_authd"
                     credentialsprofile= "&s3_credentials"
                     endpointurl       = "&s3_endpoint";

libname lfs_meta json;

proc print data=lfs_meta.root(obs=5); run;

libname  lfs_meta clear;
filename lfs_meta clear;


/* =============================================================================
   SECTION 3 — Subdirectory creation helper
   PROC S3 / FILENAME S3 work with flat object keys; "folders" are just
   key prefixes. Use DATA _NULL_ + DCREATE to prepare WORK subdirectories.
============================================================================= */

%macro make_workdir(dirname);
  %local rc;
  data _null_;
    rc = dcreate("&dirname", "&WORK");
    if rc = '' then put "ERROR: could not create &WORK/&dirname";
    else            put "NOTE: Created &WORK/&dirname";
  run;
%mend make_workdir;

%make_workdir(DICOIESS);
%make_workdir(MDBQUAR);
%make_workdir(MDBANNU);


/* -----------------------------------------------------------------------------
   3a. Download the full DICOIESS set into its WORK subfolder
----------------------------------------------------------------------------- */
proc s3 region    = "&s3_region"
        authdomain= "&s3_authd"
        credentialsprofile= "&s3_credentials"
        endpointurl= "&s3_endpoint";

  get "&S3LFS/dataiess/minidb/quar/dicofile.sas7bdat"  "&WORK/DICOIESS/dicofile.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/dicodisa.sas7bdat"  "&WORK/DICOIESS/dicodisa.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/dicoadhoc.sas7bdat" "&WORK/DICOIESS/dicoadhoc.sas7bdat";
  get "&S3LFS/dataiess/minidb/quar/formats.sas7bcat"   "&WORK/DICOIESS/formats.sas7bcat";

run;

/* Assign a library to the downloaded files */
libname DICOIESS "&WORK/DICOIESS";

proc datasets lib=DICOIESS; quit;


/* =============================================================================
   SECTION 4 — Error handling pattern
   Wrap PROC S3 in a macro to check SYSERR after each step.
============================================================================= */

%macro s3_get_safe(s3path, localpath, label=);
  proc s3 region    = "&s3_region"
          authdomain= "&s3_authd"
          credentialsprofile= "&s3_credentials"
          endpointurl= "&s3_endpoint";
    get "&s3path" "&localpath";
  run;
  %if &syserr > 0 %then %do;
    %put ERROR: [s3_get_safe] Failed to GET &s3path (SYSERR=&syserr) &label;
    %abort cancel;
  %end;
  %else %do;
    %put NOTE: [s3_get_safe] OK — &s3path → &localpath;
  %end;
%mend s3_get_safe;

%s3_get_safe(
  s3path    = &S3LFS/dataiess/minidb/quar/dicofile.sas7bdat,
  localpath = &WORK/DICOIESS/dicofile.sas7bdat,
  label     = (dictionary file)
);
