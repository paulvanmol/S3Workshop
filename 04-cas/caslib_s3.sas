/* =============================================================================
   CAS — CASLIB S3 Examples
   On-Premise MinIO connected to SAS Viya CAS (k3d, namespace: edu)

   Prerequisites:
     - MinIO running at http://minio:9000 (cluster-internal)
     - Credential domain "LFS_S3_Auth" with profile "P01" registered
     - Buckets lfs-acc-01 and lfs-output-01 exist
     - A running CAS controller in the "edu" namespace

   CAS reads data directly from S3 into in-memory tables — no intermediate
   WORK copy needed for large datasets.
============================================================================= */


/* -----------------------------------------------------------------------------
   0. Global macro variables
----------------------------------------------------------------------------- */
%let s3_region      = lux;
%let s3_authd       = LFS_S3_Auth;
%let s3_credentials = P01;
%let s3_endpoint    = http://minio:9000;

%let s3_bucket_in   = lfs-acc-01;
%let s3_bucket_out  = lfs-output-01;


/* =============================================================================
   SECTION 1 — Start a CAS session and define CASLIB S3
============================================================================= */

/* -----------------------------------------------------------------------------
   1a. Start CAS session (uses default CAS server in SAS Viya)
----------------------------------------------------------------------------- */
cas lfs_session;


/* -----------------------------------------------------------------------------
   1b. Define a read-only CASLIB pointing at the input bucket
----------------------------------------------------------------------------- */
caslib lfs_s3_in
  datasource=(
    srctype            = "s3",
    region             = "&s3_region",
    bucket             = "&s3_bucket_in",
    credentialsdomain  = "&s3_authd",
    credentialsprofile = "&s3_credentials",
    endpointurl        = "&s3_endpoint"
  )
  sessref = lfs_session
  subdirs                                /* traverse sub-prefixes             */
  desc    = "LFS Input Bucket (MinIO)";


/* -----------------------------------------------------------------------------
   1c. Define a read-write CASLIB pointing at the output bucket
----------------------------------------------------------------------------- */
caslib lfs_s3_out
  datasource=(
    srctype            = "s3",
    region             = "&s3_region",
    bucket             = "&s3_bucket_out",
    credentialsdomain  = "&s3_authd",
    credentialsprofile = "&s3_credentials",
    endpointurl        = "&s3_endpoint"
  )
  sessref = lfs_session
  desc    = "LFS Output Bucket (MinIO)";


/* =============================================================================
   SECTION 2 — Browse available files in the CASLIB
============================================================================= */

/* List all data files visible in the input CASLIB */
proc casutil incaslib="lfs_s3_in";
  list files;
run;


/* =============================================================================
   SECTION 3 — Load data from S3 into CAS memory
============================================================================= */

/* -----------------------------------------------------------------------------
   3a. Load a single SAS dataset from S3 into a CAS table
----------------------------------------------------------------------------- */
proc casutil incaslib="lfs_s3_in" outcaslib="casuser";
  load casdata  = "dataiess/minidb/quar/dicofile.sas7bdat"
       casout   = "dicofile"
       replace;
run;

/* Quick check */
proc casutil incaslib="casuser";
  list tables;
run;

proc print data=casuser.dicofile(obs=5); run;


/* -----------------------------------------------------------------------------
   3b. Load a CSV file directly from S3 into CAS
----------------------------------------------------------------------------- */
proc casutil incaslib="lfs_s3_in" outcaslib="casuser";
  load casdata  = "data/survey_sample.csv"
       casout   = "survey_sample"
       importoptions=(filetype="csv" getnames=true)
       replace;
run;


/* -----------------------------------------------------------------------------
   3c. Load multiple datasets in a loop (annual mini-database)
----------------------------------------------------------------------------- */
%let listyenc = 2019 2020 2021 2022 2023;

%macro load_mdb_cas(fold_s3);
  %let x    = 1;
  %let year = %scan(&listyenc, &x, %str( ));

  %do %while(&year ne );

    proc casutil incaslib="lfs_s3_in" outcaslib="casuser";
      load casdata = "dataiess/minidb/&fold_s3./mdb&year..sas7bdat"
           casout  = "mdb&year"
           replace;
    run;

    %if &syserr > 0 %then
      %put WARNING: [load_mdb_cas] Could not load mdb&year from &fold_s3;
    %else
      %put NOTE: [load_mdb_cas] Loaded mdb&year into CAS;

    %let x    = %eval(&x + 1);
    %let year = %scan(&listyenc, &x, %str( ));

  %end;
%mend load_mdb_cas;

%load_mdb_cas(quar);   /* quarterly */
/* %load_mdb_cas(annu); */   /* annual — uncomment when needed */


/* =============================================================================
   SECTION 4 — Analyse in CAS (example: row count and column summary)
============================================================================= */

proc cas;
  simple.summary / table={caslib="casuser", name="dicofile"};
run;

proc cas;
  table.recordCount / table={caslib="casuser", name="dicofile"};
run;


/* =============================================================================
   SECTION 5 — Save results from CAS back to S3
============================================================================= */

/* -----------------------------------------------------------------------------
   5a. Save a CAS in-memory table to the S3 output bucket
----------------------------------------------------------------------------- */
proc casutil incaslib="casuser" outcaslib="lfs_s3_out";
  save casdata = "dicofile"
       casout  = "output/dicofile_processed.sas7bdat"
       replace;
run;


/* -----------------------------------------------------------------------------
   5b. Save as Parquet (more efficient for large tables)
----------------------------------------------------------------------------- */
proc casutil incaslib="casuser" outcaslib="lfs_s3_out";
  save casdata      = "survey_sample"
       casout       = "output/survey_sample.parquet"
       exportoptions=(filetype="parquet")
       replace;
run;


/* -----------------------------------------------------------------------------
   5c. Save as CSV
----------------------------------------------------------------------------- */
proc casutil incaslib="casuser" outcaslib="lfs_s3_out";
  save casdata      = "survey_sample"
       casout       = "output/survey_sample.csv"
       exportoptions=(filetype="csv")
       replace;
run;


/* =============================================================================
   SECTION 6 — Promote a table (make it accessible to all CAS sessions)
============================================================================= */

proc casutil incaslib="casuser";
  promote casdata="dicofile" outcaslib="public" casout="lfs_dicofile";
run;


/* =============================================================================
   SECTION 7 — Drop tables and terminate session
============================================================================= */

proc casutil incaslib="casuser";
  droptable casdata="dicofile"      quiet;
  droptable casdata="survey_sample" quiet;
run;

%macro drop_mdb_cas;
  %let x    = 1;
  %let year = %scan(&listyenc, &x, %str( ));
  %do %while(&year ne );
    proc casutil incaslib="casuser";
      droptable casdata="mdb&year" quiet;
    run;
    %let x    = %eval(&x + 1);
    %let year = %scan(&listyenc, &x, %str( ));
  %end;
%mend drop_mdb_cas;

%drop_mdb_cas;

/* Drop the CASLIBs and end the session */
caslib lfs_s3_in  drop;
caslib lfs_s3_out drop;
cas lfs_session terminate;


/* =============================================================================
   SECTION 8 — PROC FEDSQL on CAS tables (ad-hoc query example)
============================================================================= */

/* Re-open session for query demo */
cas lfs_session;

caslib lfs_s3_in
  datasource=(
    srctype            = "s3",
    region             = "&s3_region",
    bucket             = "&s3_bucket_in",
    credentialsdomain  = "&s3_authd",
    credentialsprofile = "&s3_credentials",
    endpointurl        = "&s3_endpoint"
  )
  sessref = lfs_session;

proc casutil incaslib="lfs_s3_in" outcaslib="casuser";
  load casdata="dataiess/minidb/quar/dicofile.sas7bdat" casout="dicofile" replace;
run;

/* Run a SQL query directly on the in-memory CAS table */
proc fedsql sessref=lfs_session;
  select *
  from   casuser.dicofile
  where  _n_ <= 20;
quit;

caslib lfs_s3_in drop;
cas lfs_session terminate;
