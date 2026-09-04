/* =============================================================================
   LFS S3 Macro Library — Eurostat Labour Force Survey
   Adapted from Eurostat production code for on-premise MinIO (SAS Viya, k3d)

   USAGE:
     %include "&PROJ/05-lfs-macros/lfs_s3_macros.sas";
     %lfs_setup;
     %getdico;
     %getmdb(fold_work=MDBQUAR, fold_s3=quar);
     /* ... run LFS programs ... */
     %putresults(localfile=&WORK/output/results.sas7bdat,
                 s3key=output/results.sas7bdat);

   PREREQUISITES:
     - MinIO running at http://minio:9000 (inside k3d cluster)
     - Credential domain "LFS_S3_Auth" / profile "P01" in SAS Viya Credential Store
     - Buckets lfs-acc-01 and lfs-output-01 exist

   NOTES:
     - Set MINIO_INTERNAL=0 before %include to use the localhost:9000 endpoint
       (when running SAS Studio from outside the cluster, e.g. from Windows)
============================================================================= */


/* =============================================================================
   SECTION 0 — Environment configuration
============================================================================= */

/* Allow caller to override endpoint (0 = use localhost for external access) */
%if not %symexist(MINIO_INTERNAL) %then %let MINIO_INTERNAL = 1;

%macro lfs_setup;

  /* S3 authentication */
  %global s3_region s3_authd s3_credentials s3_endpoint;
  %let s3_region      = lux;
  %let s3_authd       = LFS_S3_Auth;
  %let s3_credentials = P01;

  %if &MINIO_INTERNAL = 1 %then
    %let s3_endpoint = http://minio:9000;        /* cluster-internal (CAS/Compute pods) */
  %else
    %let s3_endpoint = http://localhost:9000;    /* external — workstation or CI/CD     */

  /* Bucket paths */
  %global S3LFS S3OUT;
  %let S3LFS = /lfs-acc-01;       /* input  data bucket                                */
  %let S3OUT = /lfs-output-01;    /* output results bucket                             */

  /* List of encoding years to process */
  %global listyenc;
  %let listyenc = 2019 2020 2021 2022 2023;

  %put NOTE: [lfs_setup] S3 endpoint  = &s3_endpoint;
  %put NOTE: [lfs_setup] Input bucket = &S3LFS;
  %put NOTE: [lfs_setup] Output bucket= &S3OUT;
  %put NOTE: [lfs_setup] Year range   = &listyenc;

%mend lfs_setup;


/* =============================================================================
   SECTION 1 — Utility: create a subdirectory under WORK
============================================================================= */

%macro make_workdir(dirname);
  /*
    Creates &WORK/&dirname if it does not already exist.
    Returns the full path in macro variable WORKDIR_PATH.
  */
  %global WORKDIR_PATH;
  data _null_;
    fullpath = catx("/", "&WORK", "&dirname");
    if fileexist(fullpath) = 0 then do;
      rc = dcreate("&dirname", "&WORK");
      if rc = '' then
        put "ERROR: [make_workdir] Could not create " fullpath;
      else
        put "NOTE: [make_workdir] Created " fullpath;
    end;
    else
      put "NOTE: [make_workdir] Already exists: " fullpath;
    call symputx("WORKDIR_PATH", fullpath);
  run;
%mend make_workdir;


/* =============================================================================
   SECTION 2 — PROC S3 GET wrapper with error checking
============================================================================= */

%macro s3_get(s3path, localpath, label=);
  /*
    Downloads a single object from S3 to the local filesystem.
    Aborts the session on failure.
  */
  proc s3 region             = "&s3_region"
          authdomain         = "&s3_authd"
          credentialsprofile = "&s3_credentials"
          endpointurl        = "&s3_endpoint";
    get "&s3path" "&localpath";
  run;

  %if &syserr > 0 %then %do;
    %put ERROR: [s3_get] FAILED  &s3path  (SYSERR=&syserr) &label;
    %abort cancel;
  %end;
  %else
    %put NOTE: [s3_get] OK  &s3path  →  &localpath;
%mend s3_get;


/* =============================================================================
   SECTION 3 — PROC S3 PUT wrapper with error checking
============================================================================= */

%macro s3_put(localpath, s3path, label=);
  /*
    Uploads a single file from the local filesystem to S3.
    Issues a WARNING (does not abort) on failure so results are
    never silently lost.
  */
  %if not %sysfunc(fileexist(&localpath)) %then %do;
    %put ERROR: [s3_put] Local file not found: &localpath;
    %return;
  %end;

  proc s3 region             = "&s3_region"
          authdomain         = "&s3_authd"
          credentialsprofile = "&s3_credentials"
          endpointurl        = "&s3_endpoint";
    put "&localpath" "&s3path";
  run;

  %if &syserr > 0 %then
    %put ERROR: [s3_put] FAILED  &localpath  →  &s3path  (SYSERR=&syserr) &label;
  %else
    %put NOTE: [s3_put] OK  &localpath  →  &s3path;
%mend s3_put;


/* =============================================================================
   SECTION 4 — getdico: download the LFS dictionary files
============================================================================= */

%macro getdico;
  /*
    Downloads the quarterly dictionary and format catalog into
    &WORK/DICOIESS, then assigns a SAS library to that folder.

    Output: library DICOIESS available to the SAS session.
  */
  %make_workdir(DICOIESS);

  proc s3 region             = "&s3_region"
          authdomain         = "&s3_authd"
          credentialsprofile = "&s3_credentials"
          endpointurl        = "&s3_endpoint";

    get "&S3LFS/dataiess/minidb/quar/dicofile.sas7bdat"  "&WORK/DICOIESS/dicofile.sas7bdat";
    get "&S3LFS/dataiess/minidb/quar/dicodisa.sas7bdat"  "&WORK/DICOIESS/dicodisa.sas7bdat";
    get "&S3LFS/dataiess/minidb/quar/dicoadhoc.sas7bdat" "&WORK/DICOIESS/dicoadhoc.sas7bdat";
    get "&S3LFS/dataiess/minidb/quar/formats.sas7bcat"   "&WORK/DICOIESS/formats.sas7bcat";

  run;

  %if &syserr > 0 %then %do;
    %put ERROR: [getdico] Failed to download dictionary files. Aborting.;
    %abort cancel;
  %end;

  libname DICOIESS "&WORK/DICOIESS";
  %put NOTE: [getdico] Dictionary library DICOIESS assigned at &WORK/DICOIESS;

%mend getdico;


/* =============================================================================
   SECTION 5 — getmdb: download mini-database files for a set of years
============================================================================= */

%macro getmdb(fold_work=, fold_s3=);
  /*
    Downloads mdb<year>.sas7bdat and mdb<year>.sas7bndx for all years
    in &listyenc from S3 prefix &S3LFS/dataiess/minidb/&fold_s3 into
    &WORK/&fold_work.

    Parameters:
      fold_work  — WORK subdirectory name to download into (e.g. MDBQUAR)
      fold_s3    — S3 prefix name under dataiess/minidb/  (e.g. quar | annu)

    Example:
      %getmdb(fold_work=MDBQUAR, fold_s3=quar);
      %getmdb(fold_work=MDBANNU, fold_s3=annu);
  */

  %if &fold_work = %then %do;
    %put ERROR: [getmdb] fold_work parameter is required.;
    %return;
  %end;
  %if &fold_s3 = %then %do;
    %put ERROR: [getmdb] fold_s3 parameter is required.;
    %return;
  %end;

  %make_workdir(&fold_work);

  %let x    = 1;
  %let year = %scan(&listyenc, &x, %str( ));

  proc s3 region             = "&s3_region"
          authdomain         = "&s3_authd"
          credentialsprofile = "&s3_credentials"
          endpointurl        = "&s3_endpoint";

    %do %while(&year ne );

      get "&S3LFS/dataiess/minidb/&fold_s3./mdb&year..sas7bdat"
          "&WORK/&fold_work./mdb&year..sas7bdat";

      get "&S3LFS/dataiess/minidb/&fold_s3./mdb&year..sas7bndx"
          "&WORK/&fold_work./mdb&year..sas7bndx";

      %let x    = %eval(&x + 1);
      %let year = %scan(&listyenc, &x, %str( ));

    %end;

  run;

  %if &syserr > 0 %then
    %put WARNING: [getmdb] One or more files may not have downloaded correctly (SYSERR=&syserr).;
  %else
    %put NOTE: [getmdb] All mini-database files downloaded to &WORK/&fold_work;

  libname &fold_work "&WORK/&fold_work";
  %put NOTE: [getmdb] Library &fold_work assigned at &WORK/&fold_work;

%mend getmdb;


/* =============================================================================
   SECTION 6 — putresults: upload a result file from WORK to S3
============================================================================= */

%macro putresults(localfile=, s3key=, bucket=);
  /*
    Uploads a result file to the S3 output bucket.

    Parameters:
      localfile  — full path to local file (e.g. &WORK/output/results.sas7bdat)
      s3key      — target key inside the bucket (e.g. output/results.sas7bdat)
      bucket     — optional bucket override (defaults to &S3OUT)
  */
  %if &localfile = %then %do;
    %put ERROR: [putresults] localfile parameter is required.;
    %return;
  %end;
  %if &s3key = %then %do;
    %put ERROR: [putresults] s3key parameter is required.;
    %return;
  %end;
  %if &bucket = %then %let bucket = &S3OUT;

  %s3_put(
    localpath = &localfile,
    s3path    = &bucket/&s3key,
    label     = (putresults)
  );

%mend putresults;


/* =============================================================================
   SECTION 7 — putlib: upload all datasets in a WORK library to S3
============================================================================= */

%macro putlib(libref=, s3prefix=, ext=sas7bdat);
  /*
    Uploads all files matching &ext from a WORK subdirectory to an S3 prefix.

    Parameters:
      libref    — SAS libref (must point to a WORK subdirectory)
      s3prefix  — S3 key prefix inside &S3OUT (e.g. output/mdbquar)
      ext       — file extension to upload (default: sas7bdat)

    Example:
      %putlib(libref=MDBQUAR, s3prefix=output/mdbquar);
  */
  %local dirpath memname fullpath s3path;

  %let dirpath = %sysfunc(pathname(&libref));

  %if &dirpath = %then %do;
    %put ERROR: [putlib] Libref &libref is not assigned.;
    %return;
  %end;

  /* Build a dataset of filenames in the library folder */
  data _putlib_files;
    length fname $256;
    did = dopen("&dirpath");
    if did = 0 then do;
      put "ERROR: [putlib] Cannot open directory &dirpath";
      stop;
    end;
    do i = 1 to dnum(did);
      fname = dread(did, i);
      if index(lowcase(fname), ".&ext") > 0 then output;
    end;
    rc = dclose(did);
  run;

  /* Loop and upload each file */
  data _null_;
    set _putlib_files;
    fullpath = catx("/", "&dirpath", fname);
    s3path   = catx("/", "&S3OUT", "&s3prefix", fname);
    call execute(cats(
      '%s3_put(localpath=', fullpath, ',s3path=', s3path, ',label=(putlib &libref));'
    ));
  run;

  proc delete data=work._putlib_files; run;

  %put NOTE: [putlib] Finished uploading &libref to &S3OUT/&s3prefix;

%mend putlib;


/* =============================================================================
   SECTION 8 — Complete LFS run template
   Copy this block into your main LFS program and fill in the processing steps.
============================================================================= */

/*
%lfs_setup;

** Step 1 — Get dictionaries;
%getdico;

** Step 2 — Get quarterly mini-database;
%getmdb(fold_work=MDBQUAR, fold_s3=quar);

** Step 3 — Get annual mini-database (optional);
** %getmdb(fold_work=MDBANNU, fold_s3=annu);

** Step 4 — Your LFS processing code here;
** (reads from libnames DICOIESS, MDBQUAR, MDBANNU in WORK)

** Step 5 — Upload individual result dataset;
%putresults(
  localfile = &WORK/output/my_results.sas7bdat,
  s3key     = results/2024/Q1/my_results.sas7bdat
);

** Step 6 — Or upload an entire library;
%putlib(libref=MYOUTLIB, s3prefix=results/2024/Q1);
*/
