/*==============================================================================
  00 — BUILD EVERYTHING
  Claims Denial & Configuration Workbench
  SQL Server 2016+ (compat level 130+)

  Carlos M. Puente

  This is 01_schema.sql and 02_seed_and_adjudicate.sql combined into a single
  file. Run it top to bottom, once, in one query window. Nothing else is
  required before 03_analysis_and_tests.sql.

  Combining them removes a whole class of problem: no cross-file run order, no
  session state carried between windows, no chance of running the seed against
  a schema built by a different version of the script.

  HOW TO RUN
    1. Open ONE new query window. Close any older tabs from this project.
    2. Do not select any text -- press F5 with nothing highlighted so the whole
       file executes. Running a selection is what skips object creation.
    3. Read the grid printed at the very end. It reports what was built and
       what is missing. That single grid is the whole diagnostic.

  Expected final grid: every Status column reads OK.
==============================================================================*/

SET NOEXEC OFF;   -- clear any leftover state from a previous failed run
GO


/*------------------------------------------------------------------------------
  0a. CREATE THE DATABASE

  CREATE DATABASE is wrapped in TRY/CATCH so a permission failure surfaces its
  real message instead of being buried in the cascade that follows.
------------------------------------------------------------------------------*/
USE master;
GO

IF DB_ID('ClaimsAnalytics') IS NULL
BEGIN
    BEGIN TRY
        EXEC('CREATE DATABASE ClaimsAnalytics');
        PRINT 'Created database ClaimsAnalytics.';
    END TRY
    BEGIN CATCH
        PRINT 'CREATE DATABASE failed: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
    PRINT 'Database ClaimsAnalytics already exists.';
GO


/*------------------------------------------------------------------------------
  0b. HARD STOP IF THE DATABASE IS NOT THERE

  Severity 16, no WITH LOG. Severity 19+ requires WITH LOG, and WITH LOG requires
  sysadmin or ALTER TRACE — which is precisely the permission the caller is
  missing in the failure case this guard exists to catch. A severity 20 guard
  errors out on the only user who needs it, and the script then runs on in
  master. Severity 16 always reaches the caller.

  RAISERROR alone does not stop a multi-batch script, so NOEXEC does the stopping.
------------------------------------------------------------------------------*/
IF DB_ID('ClaimsAnalytics') IS NULL
BEGIN
    RAISERROR('STOP: ClaimsAnalytics does not exist and could not be created. Your login likely lacks CREATE DATABASE (dbcreator or sysadmin). Nothing further in this script was executed.', 16, 1);
    SET NOEXEC ON;
END
GO

USE ClaimsAnalytics;
GO

/* Second guard: USE can fail on its own (offline database, no CONNECT rights)
   even when DB_ID resolves. Without this, every object below lands in master. */
IF DB_NAME() <> 'ClaimsAnalytics'
BEGIN
    RAISERROR('STOP: USE ClaimsAnalytics did not take. Check the database dropdown in the SSMS toolbar and your CONNECT permission. Nothing further in this script was executed.', 16, 1);
    SET NOEXEC ON;
END
GO

/* STRING_SPLIT/OPENJSON and the modifier explosion need compat 130+. */
IF (SELECT compatibility_level FROM sys.databases WHERE name = 'ClaimsAnalytics') < 130
BEGIN
    RAISERROR('STOP: ClaimsAnalytics is below compatibility level 130. Run: ALTER DATABASE ClaimsAnalytics SET COMPATIBILITY_LEVEL = 130;', 16, 1);
    SET NOEXEC ON;
END
GO


/*==============================================================================
  0c. SCHEMAS

  Created BEFORE the teardown, not after. The teardown references stg, ops, and
  dw objects, so on a first run those schemas have to exist first.
  CREATE SCHEMA must be the first statement in its batch, hence EXEC().
==============================================================================*/
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw  AUTHORIZATION dbo;');
IF SCHEMA_ID('ops') IS NULL EXEC('CREATE SCHEMA ops AUTHORIZATION dbo;');
GO


/*==============================================================================
  0d. TEAR DOWN  (child objects first, so foreign keys release cleanly)

  Note: dbo.PriorAuth was named "Authorization" in an earlier draft. AUTHORIZATION
  is a reserved T-SQL keyword and breaks the batch parse, so the table is named
  PriorAuth throughout.
==============================================================================*/
DROP PROCEDURE IF EXISTS dw.usp_BackfillClaimDenialDaily;
DROP PROCEDURE IF EXISTS dw.usp_LoadClaimDenialDaily;
DROP PROCEDURE IF EXISTS dbo.usp_AdjudicateClaims;
DROP PROCEDURE IF EXISTS stg.usp_CleanseAndLoadClaims;
DROP VIEW      IF EXISTS ops.vw_PipelineHealth;
DROP FUNCTION  IF EXISTS dbo.fnRand;

DROP TABLE IF EXISTS dbo.ClaimRuleResult;
DROP TABLE IF EXISTS dbo.ClaimModifier;
DROP TABLE IF EXISTS dbo.ClaimDenial;
DROP TABLE IF EXISTS dbo.Claim;
DROP TABLE IF EXISTS dbo.PriorAuth;
DROP TABLE IF EXISTS dbo.AdjudicationRule;
DROP TABLE IF EXISTS dbo.BenefitCategory;
DROP TABLE IF EXISTS dbo.FeeSchedule;
DROP TABLE IF EXISTS dbo.PlanConfig;
DROP TABLE IF EXISTS dbo.Provider;
DROP TABLE IF EXISTS dbo.Member;
DROP TABLE IF EXISTS dbo.Numbers;
DROP TABLE IF EXISTS dw.FactClaimDenialDaily;
DROP TABLE IF EXISTS ops.PartitionLog;
DROP TABLE IF EXISTS ops.ClaimReject;
DROP TABLE IF EXISTS stg.ClaimImport;
GO


/*==============================================================================
  1. SOURCE SCHEMA
==============================================================================*/

/* The configuration register is the point of the whole project.
   LoadedValue is what the engine actually uses.
   StandardValue is what the contract or the state requires.
   Any row where they disagree is a live financial exposure. */
CREATE TABLE dbo.PlanConfig (
    ConfigKey       VARCHAR(64)   NOT NULL PRIMARY KEY,
    ConfigPath      VARCHAR(128)  NOT NULL,
    ConfigScope     VARCHAR(32)   NOT NULL,
    LoadedValue     DECIMAL(10,2) NOT NULL,
    StandardValue   DECIMAL(10,2) NOT NULL,
    StandardSource  VARCHAR(256)  NOT NULL,
    EffectiveDate   DATE          NOT NULL,
    LastChangedBy   VARCHAR(64)   NOT NULL,
    LastChangedUtc  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.Member (
    MemberID         VARCHAR(16) NOT NULL PRIMARY KEY,
    LOB              VARCHAR(16) NOT NULL,   -- STAR, CHIP, STAR+PLUS, HIM, D-SNP
    CoverageEffDate  DATE        NOT NULL,
    CoverageTermDate DATE        NULL,
    CountyCode       CHAR(3)     NOT NULL
);

CREATE TABLE dbo.Provider (
    ProviderID        VARCHAR(16)  NOT NULL PRIMARY KEY,
    ParentProviderID  VARCHAR(16)  NULL,   -- self-referencing: group -> billing entity
    ProviderName      VARCHAR(128) NOT NULL,
    NPI               CHAR(10)     NOT NULL,
    ProviderType      VARCHAR(32)  NOT NULL,
    ParticipatingFlag BIT          NOT NULL,
    ContractEffDate   DATE         NOT NULL,
    ContractTermDate  DATE         NULL,
    CONSTRAINT FK_Provider_Parent FOREIGN KEY (ParentProviderID)
        REFERENCES dbo.Provider (ProviderID)
);

CREATE TABLE dbo.AdjudicationRule (
    RuleID       CHAR(5)      NOT NULL PRIMARY KEY,
    RuleName     VARCHAR(128) NOT NULL,
    RuleSequence TINYINT      NOT NULL,   -- evaluation order; first failure denies
    ConfigKey    VARCHAR(64)  NULL,       -- the parameter this rule reads
    CONSTRAINT FK_Rule_Config FOREIGN KEY (ConfigKey)
        REFERENCES dbo.PlanConfig (ConfigKey)
);

/* Which service categories need prior auth, which are delegated to a vendor,
   and which are exempt from the plan-side auth edit. Modeled as a table, not a
   flag on the claim, so the rules are real joins. */
CREATE TABLE dbo.BenefitCategory (
    ProviderType     VARCHAR(32) NOT NULL PRIMARY KEY,
    BenefitCategory  VARCHAR(32) NOT NULL,
    AuthRequiredFlag BIT         NOT NULL,
    DelegatedVendor  VARCHAR(64) NULL,   -- non-null = plan should not adjudicate
    AuthExemptFlag   BIT         NOT NULL
);

CREATE TABLE dbo.FeeSchedule (
    ProcedureCode VARCHAR(8)    NOT NULL,
    EffectiveDate DATE          NOT NULL,
    TermDate      DATE          NULL,
    ScheduleRate  DECIMAL(12,2) NOT NULL,
    CONSTRAINT PK_FeeSchedule PRIMARY KEY (ProcedureCode, EffectiveDate)
);

CREATE TABLE dbo.Claim (
    ClaimID               VARCHAR(24)   NOT NULL PRIMARY KEY,
    MemberID              VARCHAR(16)   NOT NULL,
    ProviderID            VARCHAR(16)   NOT NULL,
    LOB                   VARCHAR(16)   NOT NULL,
    ProcedureCode         VARCHAR(8)    NOT NULL,
    ModifierList          VARCHAR(32)   NULL,   -- pipe-delimited on arrival
    Units                 SMALLINT      NOT NULL DEFAULT 1,
    ServiceFromDate       DATE          NOT NULL,
    ServiceThruDate       DATE          NOT NULL,
    ReceivedDate          DATE          NOT NULL,
    AdjudicatedDate       DATE          NULL,
    BilledAmount          DECIMAL(12,2) NOT NULL,
    ExpectedAllowedAmount DECIMAL(12,2) NULL,
    PaidAmount            DECIMAL(12,2) NULL,
    AdjudicationStatus    VARCHAR(12)   NOT NULL,
    CONSTRAINT FK_Claim_Member   FOREIGN KEY (MemberID)   REFERENCES dbo.Member (MemberID),
    CONSTRAINT FK_Claim_Provider FOREIGN KEY (ProviderID) REFERENCES dbo.Provider (ProviderID)
);

/* ServiceFromDate is the partition key for everything downstream. Leading the
   index with it lets the daily load seek one day instead of scanning the table. */
CREATE NONCLUSTERED INDEX IX_Claim_SvcDate_Status
    ON dbo.Claim (ServiceFromDate, AdjudicationStatus)
    INCLUDE (LOB, ProviderID, MemberID, ProcedureCode, Units,
             BilledAmount, ExpectedAllowedAmount, PaidAmount);

CREATE TABLE dbo.PriorAuth (
    AuthID       INT IDENTITY(1,1) PRIMARY KEY,
    MemberID     VARCHAR(16) NOT NULL,
    ProviderType VARCHAR(32) NOT NULL,
    AuthEffDate  DATE        NOT NULL,
    AuthThruDate DATE        NOT NULL,
    AuthStatus   VARCHAR(12) NOT NULL
);
CREATE NONCLUSTERED INDEX IX_Auth_Member
    ON dbo.PriorAuth (MemberID, ProviderType, AuthEffDate, AuthThruDate)
    INCLUDE (AuthStatus);

/* ClaimDenial holds only the first rule that failed — that is what denies. */
CREATE TABLE dbo.ClaimDenial (
    ClaimID    VARCHAR(24)  NOT NULL PRIMARY KEY,
    RuleID     CHAR(5)      NOT NULL,
    DenialCode VARCHAR(8)   NOT NULL,
    DeniedUtc  DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_Denial_Claim FOREIGN KEY (ClaimID) REFERENCES dbo.Claim (ClaimID),
    CONSTRAINT FK_Denial_Rule  FOREIGN KEY (RuleID)  REFERENCES dbo.AdjudicationRule (RuleID)
);

/* ClaimRuleResult holds every rule's verdict on every claim, so the trace can
   show the full chain including the rules that never ran. */
CREATE TABLE dbo.ClaimRuleResult (
    ClaimID    VARCHAR(24)  NOT NULL,
    RuleID     CHAR(5)      NOT NULL,
    RuleResult VARCHAR(8)   NOT NULL,   -- PASS / FAIL / SKIP
    Evidence   VARCHAR(512) NULL,
    CONSTRAINT PK_ClaimRuleResult PRIMARY KEY (ClaimID, RuleID)
);

CREATE TABLE dbo.ClaimModifier (
    ClaimID      VARCHAR(24) NOT NULL,
    ModifierSeq  TINYINT     NOT NULL,
    ModifierCode CHAR(2)     NOT NULL,
    CONSTRAINT PK_ClaimModifier PRIMARY KEY (ClaimID, ModifierSeq)
);

/* Utility numbers table. Drives the synthetic data generation in file 02 and
   is generally useful for date spines and gap-filling. */
CREATE TABLE dbo.Numbers (N INT NOT NULL PRIMARY KEY);
GO


/*==============================================================================
  2. STAGING, DATA QUALITY, AND CLEANSING

  The 837 extract arrives messy: duplicate submissions inside one file, mixed
  date formats, currency strings with accounting negatives, and a pipe-delimited
  modifier list.

  The rule is that one bad row never fails the batch. Bad rows land in a reject
  table named with the reason they failed; good rows merge forward. The reject
  rate feeds the pipeline health view in section 5.
==============================================================================*/

CREATE TABLE stg.ClaimImport (
    RawRowNum      INT IDENTITY(1,1) NOT NULL,
    ClaimID        VARCHAR(24)  NULL,
    MemberID       VARCHAR(24)  NULL,
    ProviderID     VARCHAR(24)  NULL,
    LOB            VARCHAR(32)  NULL,
    ProcedureCode  VARCHAR(16)  NULL,
    ModifierList   VARCHAR(64)  NULL,   -- '  25|59 | GT '
    Units          VARCHAR(8)   NULL,
    ServiceFromRaw VARCHAR(24)  NULL,   -- 2026-03-04 / 03/04/2026 / 20260304
    ServiceThruRaw VARCHAR(24)  NULL,
    ReceivedRaw    VARCHAR(24)  NULL,
    BilledRaw      VARCHAR(24)  NULL,   -- '$1,240.00 ' and '(85.00)'
    SourceFileName VARCHAR(128) NOT NULL,
    LoadedUtc      DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);

/* ServiceDate is carried onto the reject row so the pipeline health view can
   attribute a reject to the service date it belongs to. Attributing rejects by
   the timestamp they were written instead lands every reject on the day the
   load ran, which makes the reject rate on every historical partition zero. */
CREATE TABLE ops.ClaimReject (
    RejectID       INT IDENTITY(1,1) PRIMARY KEY,
    SourceFileName VARCHAR(128) NOT NULL,
    RawRowNum      INT          NOT NULL,
    ClaimID        VARCHAR(24)  NULL,
    ServiceDate    DATE         NULL,   -- NULL when the date itself was unparseable
    RejectReason   VARCHAR(128) NOT NULL,
    RejectedUtc    DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);

/* The MERGE in 2d probes this by (SourceFileName, RawRowNum) once per surviving
   row; without the index that is a scan of the whole reject history. */
CREATE UNIQUE NONCLUSTERED INDEX UX_ClaimReject_File_Row
    ON ops.ClaimReject (SourceFileName, RawRowNum);

CREATE NONCLUSTERED INDEX IX_ClaimReject_ServiceDate
    ON ops.ClaimReject (ServiceDate);
GO


CREATE OR ALTER PROCEDURE stg.usp_CleanseAndLoadClaims
    @SourceFileName VARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*--- 2a. Normalize. TRY_CONVERT throughout: one unparseable value returns
             NULL and gets rejected by name below, instead of aborting the
             batch with a conversion error. ---*/
    DROP TABLE IF EXISTS #Normalized;

    SELECT
        s.RawRowNum,
        LTRIM(RTRIM(UPPER(s.ClaimID)))                  AS ClaimID,
        LTRIM(RTRIM(UPPER(s.MemberID)))                 AS MemberID,
        LTRIM(RTRIM(UPPER(s.ProviderID)))               AS ProviderID,
        LTRIM(RTRIM(UPPER(s.LOB)))                      AS LOB,
        LTRIM(RTRIM(UPPER(s.ProcedureCode)))            AS ProcedureCode,
        REPLACE(LTRIM(RTRIM(s.ModifierList)), ' ', '')  AS ModifierList,
        TRY_CONVERT(SMALLINT, NULLIF(LTRIM(RTRIM(s.Units)), '')) AS Units,

        COALESCE(TRY_CONVERT(DATE, s.ServiceFromRaw, 23),   -- yyyy-mm-dd
                 TRY_CONVERT(DATE, s.ServiceFromRaw, 101),  -- mm/dd/yyyy
                 TRY_CONVERT(DATE, s.ServiceFromRaw, 112))  -- yyyymmdd
                                                        AS ServiceFromDate,
        COALESCE(TRY_CONVERT(DATE, s.ServiceThruRaw, 23),
                 TRY_CONVERT(DATE, s.ServiceThruRaw, 101),
                 TRY_CONVERT(DATE, s.ServiceThruRaw, 112)) AS ServiceThruDate,
        COALESCE(TRY_CONVERT(DATE, s.ReceivedRaw, 23),
                 TRY_CONVERT(DATE, s.ReceivedRaw, 101),
                 TRY_CONVERT(DATE, s.ReceivedRaw, 112))    AS ReceivedDate,

        -- Strip currency formatting; convert accounting negatives to signed
        TRY_CONVERT(DECIMAL(12,2),
            CASE WHEN LTRIM(RTRIM(s.BilledRaw)) LIKE '(%)'
                 THEN '-' + REPLACE(REPLACE(REPLACE(REPLACE(
                        LTRIM(RTRIM(s.BilledRaw)),'(',''),')',''),'$',''),',','')
                 ELSE REPLACE(REPLACE(LTRIM(RTRIM(s.BilledRaw)),'$',''),',','')
            END)                                        AS BilledAmount,
        s.SourceFileName
    INTO   #Normalized
    FROM   stg.ClaimImport AS s
    WHERE  s.SourceFileName = @SourceFileName;


    /*--- 2b. Deduplicate. The same claim can arrive more than once in a file and
             the versions are not always identical. Keep the last-arriving row;
             ROW_NUMBER over the natural key is cheaper and clearer than a
             self-join against a MAX() subquery.

             Ranked is materialized once and used for both the survivors and the
             superseded rejects, instead of running the same window function
             twice as two independent scans. ---*/
    DROP TABLE IF EXISTS #Ranked;
    DROP TABLE IF EXISTS #Deduped;

    SELECT n.*,
           ROW_NUMBER() OVER (PARTITION BY n.ClaimID ORDER BY n.RawRowNum DESC) AS RowRank
    INTO   #Ranked
    FROM   #Normalized AS n
    WHERE  n.ClaimID IS NOT NULL;

    SELECT * INTO #Deduped FROM #Ranked WHERE RowRank = 1;

    INSERT INTO ops.ClaimReject (SourceFileName, RawRowNum, ClaimID, ServiceDate, RejectReason)
    SELECT r.SourceFileName, r.RawRowNum, r.ClaimID, r.ServiceFromDate,
           'Superseded duplicate within source file'
    FROM   #Ranked AS r
    WHERE  r.RowRank > 1
      AND  NOT EXISTS (SELECT 1 FROM ops.ClaimReject AS x
                       WHERE x.SourceFileName = r.SourceFileName
                         AND x.RawRowNum      = r.RawRowNum);

    /* Rows with no ClaimID at all never enter #Ranked and would otherwise vanish
       without a trace. Name them. */
    INSERT INTO ops.ClaimReject (SourceFileName, RawRowNum, ClaimID, ServiceDate, RejectReason)
    SELECT n.SourceFileName, n.RawRowNum, NULL, n.ServiceFromDate, 'Missing claim identifier'
    FROM   #Normalized AS n
    WHERE  n.ClaimID IS NULL
      AND  NOT EXISTS (SELECT 1 FROM ops.ClaimReject AS x
                       WHERE x.SourceFileName = n.SourceFileName
                         AND x.RawRowNum      = n.RawRowNum);


    /*--- 2c. Validate. Every failing row is named with why it failed, so the
             reject table is actionable rather than a bucket.

             ServiceThruDate IS NULL is checked explicitly. Without it an
             unparseable thru date evaluates the < comparison to UNKNOWN, passes
             validation, and then fails the NOT NULL constraint on dbo.Claim
             inside the MERGE — which under XACT_ABORT takes down the whole
             batch. That is exactly the one-bad-row-fails-everything outcome the
             reject table exists to prevent. ---*/
    INSERT INTO ops.ClaimReject (SourceFileName, RawRowNum, ClaimID, ServiceDate, RejectReason)
    SELECT d.SourceFileName, d.RawRowNum, d.ClaimID, d.ServiceFromDate,
           CASE
             WHEN d.ServiceFromDate IS NULL   THEN 'Unparseable service from date'
             WHEN d.ServiceThruDate IS NULL   THEN 'Unparseable service thru date'
             WHEN d.ReceivedDate    IS NULL   THEN 'Unparseable received date'
             WHEN d.BilledAmount    IS NULL   THEN 'Unparseable billed amount'
             WHEN d.BilledAmount   <= 0       THEN 'Non-positive billed amount'
             WHEN d.ReceivedDate    < d.ServiceFromDate
                                              THEN 'Received date precedes date of service'
             WHEN d.ServiceThruDate < d.ServiceFromDate
                                              THEN 'Service thru precedes service from'
             WHEN d.ServiceFromDate > CAST(SYSDATETIME() AS DATE)
                                              THEN 'Service date in the future'
             WHEN d.MemberID   IS NULL        THEN 'Missing member identifier'
             WHEN d.ProviderID IS NULL        THEN 'Missing provider identifier'
             WHEN m.MemberID   IS NULL        THEN 'Member not found in eligibility'
             WHEN p.ProviderID IS NULL        THEN 'Provider not found in network file'
             WHEN d.Units IS NULL OR d.Units < 1
                                              THEN 'Invalid unit count'
           END
    FROM      #Deduped     AS d
    LEFT JOIN dbo.Member   AS m ON m.MemberID   = d.MemberID
    LEFT JOIN dbo.Provider AS p ON p.ProviderID = d.ProviderID
    WHERE (d.ServiceFromDate IS NULL
       OR  d.ServiceThruDate IS NULL
       OR  d.ReceivedDate    IS NULL
       OR  d.BilledAmount    IS NULL
       OR  d.BilledAmount   <= 0
       OR  d.ReceivedDate    < d.ServiceFromDate
       OR  d.ServiceThruDate < d.ServiceFromDate
       OR  d.ServiceFromDate > CAST(SYSDATETIME() AS DATE)
       OR  d.MemberID   IS NULL
       OR  d.ProviderID IS NULL
       OR  m.MemberID   IS NULL
       OR  p.ProviderID IS NULL
       OR  d.Units IS NULL OR d.Units < 1)
      AND NOT EXISTS (SELECT 1 FROM ops.ClaimReject AS x
                      WHERE x.SourceFileName = d.SourceFileName
                        AND x.RawRowNum      = d.RawRowNum);


    /*--- 2d. Merge the survivors.

             HOLDLOCK on the target is required, not optional: MERGE without it
             takes only an update lock while probing and can deadlock or produce
             a duplicate-key violation under concurrent loads. ---*/
    MERGE dbo.Claim WITH (HOLDLOCK) AS tgt
    USING (SELECT d.* FROM #Deduped AS d
           WHERE NOT EXISTS (SELECT 1 FROM ops.ClaimReject AS rj
                             WHERE rj.SourceFileName = d.SourceFileName
                               AND rj.RawRowNum      = d.RawRowNum)) AS src
    ON    tgt.ClaimID = src.ClaimID
    WHEN MATCHED AND (tgt.BilledAmount    <> src.BilledAmount
                   OR tgt.ReceivedDate    <> src.ReceivedDate
                   OR tgt.Units           <> src.Units
                   OR tgt.ProcedureCode   <> src.ProcedureCode
                   OR tgt.ServiceFromDate <> src.ServiceFromDate
                   OR tgt.ServiceThruDate <> src.ServiceThruDate) THEN
        /* Any of these changes the price, so all of them have to carry through
           and all of them force re-adjudication — not just amount and date. */
        UPDATE SET tgt.BilledAmount       = src.BilledAmount,
                   tgt.ReceivedDate       = src.ReceivedDate,
                   tgt.Units              = src.Units,
                   tgt.ProcedureCode      = src.ProcedureCode,
                   tgt.ModifierList       = src.ModifierList,
                   tgt.ServiceFromDate    = src.ServiceFromDate,
                   tgt.ServiceThruDate    = src.ServiceThruDate,
                   tgt.AdjudicationStatus = 'PENDING',
                   tgt.AdjudicatedDate    = NULL,
                   tgt.PaidAmount         = NULL,
                   tgt.ExpectedAllowedAmount = NULL
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ClaimID, MemberID, ProviderID, LOB, ProcedureCode, ModifierList, Units,
                ServiceFromDate, ServiceThruDate, ReceivedDate, BilledAmount, AdjudicationStatus)
        VALUES (src.ClaimID, src.MemberID, src.ProviderID, src.LOB, src.ProcedureCode,
                src.ModifierList, src.Units, src.ServiceFromDate, src.ServiceThruDate,
                src.ReceivedDate, src.BilledAmount, 'PENDING');


    /*--- 2e. Explode the pipe-delimited modifier string into rows.

             OPENJSON, not STRING_SPLIT. The three-argument form
             STRING_SPLIT(s, sep, 1) that returns an ordinal column was added in
             SQL Server 2022 — it does not exist in 2019 regardless of
             compatibility level, and the header on this file claims 2019+.
             OPENJSON's [key] gives the same positional ordinal on 2016+.

             Ordinal matters because modifier order changes pricing.

             COALESCE to '' rather than filtering NULLs in the WHERE clause: the
             optimizer is free to evaluate CROSS APPLY before WHERE, and
             OPENJSON(NULL) raises a malformed-JSON error. ---*/
    DELETE cm FROM dbo.ClaimModifier AS cm
    JOIN   #Deduped AS d ON d.ClaimID = cm.ClaimID;

    INSERT INTO dbo.ClaimModifier (ClaimID, ModifierSeq, ModifierCode)
    SELECT d.ClaimID,
           CAST(CAST(x.[key] AS INT) + 1 AS TINYINT),
           CAST(LTRIM(RTRIM(x.value)) AS CHAR(2))
    FROM   #Deduped AS d
    CROSS APPLY OPENJSON(
               '["' + REPLACE(STRING_ESCAPE(COALESCE(d.ModifierList, ''), 'json'),
                              '|', '","') + '"]') AS x
    WHERE  LEN(LTRIM(RTRIM(x.value))) = 2
      AND  NOT EXISTS (SELECT 1 FROM ops.ClaimReject AS rj
                       WHERE rj.SourceFileName = d.SourceFileName
                         AND rj.RawRowNum      = d.RawRowNum);

    DROP TABLE IF EXISTS #Ranked;
    DROP TABLE IF EXISTS #Deduped;
    DROP TABLE IF EXISTS #Normalized;
END;
GO


/*==============================================================================
  3. WAREHOUSE: DAILY AGGREGATE WITH ACCRETIVE DATE PARTITIONS

  Claim detail gets queried by the dashboard dozens of times a day. Aggregating
  once per service date and reading the aggregate afterward is the entire
  economics of this layer.

  GRAIN DECISION
  The dashboard answers: how much money is at risk, driven by which rule, on
  which line of business, for which provider type. So the grain is
      ServiceDate + LOB + ProviderType + RuleID + Verdict

  Deliberately NOT in the grain:
    MemberID       -- would push the table back toward claim-level row counts
                      and answers no question the dashboard asks
    ProcedureCode  -- same problem; procedure analysis is a drill-through to
                      detail, not a dashboard default
    ProviderID     -- kept at type level. Provider exposure is a ranked top-N
                      against detail, run on demand, not stored every day

  Dropping those three takes the daily table from roughly claim-count rows to a
  few dozen rows per service date.
==============================================================================*/

CREATE TABLE dw.FactClaimDenialDaily (
    ServiceDate           DATE          NOT NULL,
    LOB                   VARCHAR(16)   NOT NULL,
    ProviderType          VARCHAR(32)   NOT NULL,
    RuleID                CHAR(5)       NOT NULL,
    Verdict               VARCHAR(24)   NOT NULL,
    ClaimCount            INT           NOT NULL,
    DeniedCount           INT           NOT NULL,
    BilledAmount          DECIMAL(14,2) NOT NULL,
    ExpectedAllowedAmount DECIMAL(14,2) NOT NULL,
    PaidAmount            DECIMAL(14,2) NOT NULL,
    AmountAtRisk          DECIMAL(14,2) NOT NULL,
    PartitionLoadedUtc    DATETIME2(0)  NOT NULL,
    CONSTRAINT PK_FactClaimDenialDaily
        PRIMARY KEY CLUSTERED (ServiceDate, LOB, ProviderType, RuleID, Verdict)
);

/* The clustered key already leads on ServiceDate, so date ranges are seeks.
   This covering index serves the "by rule across all dates" view. */
CREATE NONCLUSTERED INDEX IX_FactDaily_Rule
    ON dw.FactClaimDenialDaily (RuleID, ServiceDate)
    INCLUDE (Verdict, DeniedCount, AmountAtRisk);

/* One row per loaded service date. This is what makes the load accretive: the
   procedure only touches dates that are missing or explicitly requested. */
CREATE TABLE ops.PartitionLog (
    PartitionDate  DATE         NOT NULL PRIMARY KEY,
    RowsWritten    INT          NOT NULL,
    SourceRowsRead INT          NOT NULL,
    RejectedRows   INT          NOT NULL,
    LoadStartUtc   DATETIME2(0) NOT NULL,
    LoadEndUtc     DATETIME2(0) NOT NULL,
    LoadStatus     VARCHAR(16)  NOT NULL,   -- SUCCESS / FAILED / RELOADED
    LoadMessage    VARCHAR(512) NULL
);
GO


/*==============================================================================
  4. INCREMENTAL LOAD

  Loads one service date. Idempotent: re-running a date deletes and rewrites
  only that date, so a retry after failure is safe and a reload after a
  configuration correction is a one-line call.
==============================================================================*/

CREATE OR ALTER PROCEDURE dw.usp_LoadClaimDenialDaily
    @PartitionDate DATE,
    @Reload        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Start DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Rows INT = 0, @SourceRows INT = 0, @Rejects INT = 0;
    DECLARE @PriorStatus VARCHAR(16);

    SELECT @PriorStatus = LoadStatus
    FROM   ops.PartitionLog
    WHERE  PartitionDate = @PartitionDate;

    IF @PriorStatus IN ('SUCCESS','RELOADED') AND @Reload = 0
        RETURN 0;   -- already loaded; pass @Reload = 1 to rebuild

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.FactClaimDenialDaily WHERE ServiceDate = @PartitionDate;

        ;WITH Scoped AS (
            /* Single seek on IX_Claim_SvcDate_Status. Filtering to one date
               here, before any join, is what keeps the load cheap as the
               table grows. */
            SELECT c.ClaimID, c.LOB, c.ProviderID, c.ProcedureCode, c.Units,
                   c.ServiceFromDate, c.PaidAmount, c.BilledAmount,
                   c.AdjudicationStatus
            FROM   dbo.Claim AS c
            WHERE  c.ServiceFromDate = @PartitionDate
        ),
        Priced AS (
            /* Recompute expected allowed from the STANDARD percentage, not the
               loaded one. The gap between this and PaidAmount is the silent
               underpayment. Units matter here — an LTSS claim is 8 to 40 units.

               OUTER APPLY TOP 1, not a LEFT JOIN. A LEFT JOIN to FeeSchedule
               returns one row per overlapping schedule version, and the PK
               (ProcedureCode, EffectiveDate) does nothing to prevent overlap —
               a stale row with a NULL TermDate is enough. Every duplicate would
               then be double-counted in COUNT(*) and SUM(BilledAmount) below,
               silently inflating the dashboard. TOP 1 by latest effective date
               guarantees exactly one rate. */
            SELECT s.*,
                   p.ProviderType,
                   CAST(fs.ScheduleRate * s.Units * fsc.StandardValue / 100.0
                        AS DECIMAL(14,2)) AS ExpectedAllowed
            FROM      Scoped       AS s
            JOIN      dbo.Provider AS p ON p.ProviderID = s.ProviderID
            OUTER APPLY (
                SELECT TOP (1) f.ScheduleRate
                FROM   dbo.FeeSchedule AS f
                WHERE  f.ProcedureCode = s.ProcedureCode
                  AND  s.ServiceFromDate >= f.EffectiveDate
                  AND  s.ServiceFromDate <= ISNULL(f.TermDate, '9999-12-31')
                ORDER BY f.EffectiveDate DESC
            ) AS fs
            LEFT JOIN dbo.PlanConfig AS fsc
                   ON fsc.ConfigKey = 'FeeSchedulePct_' + p.ProviderType
        ),
        Classified AS (
            SELECT pr.*,
                   ISNULL(d.RuleID, 'R-000') AS RuleID,
                   CASE
                     /* A claim that has not been adjudicated yet is not clean,
                        it is unknown. Previously PENDING claims with a NULL
                        PaidAmount fell through ISNULL(...,0) >= ISNULL(...,0)
                        as 0 >= 0 and were reported as CLEAN. */
                     WHEN pr.AdjudicationStatus = 'PENDING'
                          THEN 'PENDING ADJUDICATION'
                     /* No fee schedule row or no config key means there is no
                        expected allowed to compare against. Same failure mode:
                        NULL collapsed to 0 and read as CLEAN. */
                     WHEN d.RuleID IS NULL AND pr.ExpectedAllowed IS NULL
                          THEN 'UNPRICED'
                     WHEN d.RuleID IS NULL
                      AND ISNULL(pr.PaidAmount,0) >= pr.ExpectedAllowed
                          THEN 'CLEAN'
                     WHEN d.RuleID IS NULL
                          THEN 'CONFIGURATION DEFECT'   -- paid, but paid short
                     WHEN cfg.LoadedValue <> cfg.StandardValue
                          THEN 'CONFIGURATION DEFECT'   -- denied on a wrong value
                     ELSE 'CORRECT DENIAL'
                   END AS Verdict
            FROM      Priced               AS pr
            LEFT JOIN dbo.ClaimDenial      AS d   ON d.ClaimID    = pr.ClaimID
            LEFT JOIN dbo.AdjudicationRule AS r   ON r.RuleID     = d.RuleID
            LEFT JOIN dbo.PlanConfig       AS cfg ON cfg.ConfigKey = r.ConfigKey
        )
        INSERT INTO dw.FactClaimDenialDaily
            (ServiceDate, LOB, ProviderType, RuleID, Verdict, ClaimCount, DeniedCount,
             BilledAmount, ExpectedAllowedAmount, PaidAmount, AmountAtRisk, PartitionLoadedUtc)
        SELECT @PartitionDate, c.LOB, c.ProviderType, c.RuleID, c.Verdict,
               COUNT(*),
               SUM(CASE WHEN c.AdjudicationStatus = 'DENIED' THEN 1 ELSE 0 END),
               SUM(c.BilledAmount),
               SUM(ISNULL(c.ExpectedAllowed, 0)),
               SUM(ISNULL(c.PaidAmount, 0)),
               SUM(ISNULL(c.ExpectedAllowed, 0) - ISNULL(c.PaidAmount, 0)),
               SYSUTCDATETIME()
        FROM   Classified AS c
        GROUP BY c.LOB, c.ProviderType, c.RuleID, c.Verdict;

        SET @Rows = @@ROWCOUNT;

        SELECT @SourceRows = COUNT(*) FROM dbo.Claim WHERE ServiceFromDate = @PartitionDate;

        /* By ServiceDate, not CAST(RejectedUtc AS DATE). The old predicate
           compared the moment the reject was written to the service date being
           loaded, so any backfill of a historical date reported zero rejects
           and the reject rate in the health view was meaningless. */
        SELECT @Rejects = COUNT(*) FROM ops.ClaimReject
               WHERE ServiceDate = @PartitionDate;

        MERGE ops.PartitionLog WITH (HOLDLOCK) AS tgt
        USING (SELECT @PartitionDate AS PartitionDate) AS src
        ON    tgt.PartitionDate = src.PartitionDate
        WHEN MATCHED THEN UPDATE SET
              RowsWritten = @Rows, SourceRowsRead = @SourceRows, RejectedRows = @Rejects,
              LoadStartUtc = @Start, LoadEndUtc = SYSUTCDATETIME(),
              /* RELOADED only if there was a good load to reload. A retry after
                 a FAILED row is a first success, not a reload. */
              LoadStatus = CASE WHEN @PriorStatus IN ('SUCCESS','RELOADED')
                                THEN 'RELOADED' ELSE 'SUCCESS' END,
              LoadMessage = NULL
        WHEN NOT MATCHED THEN
              INSERT (PartitionDate, RowsWritten, SourceRowsRead, RejectedRows,
                      LoadStartUtc, LoadEndUtc, LoadStatus)
              VALUES (@PartitionDate, @Rows, @SourceRows, @Rejects,
                      @Start, SYSUTCDATETIME(), 'SUCCESS');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg VARCHAR(512) = LEFT(ERROR_MESSAGE(), 512);

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        MERGE ops.PartitionLog WITH (HOLDLOCK) AS tgt
        USING (SELECT @PartitionDate AS PartitionDate) AS src
        ON    tgt.PartitionDate = src.PartitionDate
        WHEN MATCHED THEN UPDATE SET
              LoadEndUtc = SYSUTCDATETIME(), LoadStatus = 'FAILED',
              LoadMessage = @ErrMsg
        WHEN NOT MATCHED THEN
              INSERT (PartitionDate, RowsWritten, SourceRowsRead, RejectedRows,
                      LoadStartUtc, LoadEndUtc, LoadStatus, LoadMessage)
              VALUES (@PartitionDate, 0, 0, 0, @Start, SYSUTCDATETIME(), 'FAILED', @ErrMsg);
        THROW;
    END CATCH
END;
GO


/*------------------------------------------------------------------------------
  BACKFILL

  A recursive CTE generates the date spine. Recursion is the right tool here
  rather than an ornament: the spine has to exist before any partition loads, so
  it cannot be derived from the data being loaded, and a calendar table would
  add a dependency the pipeline does not otherwise need.

  MAXRECURSION is set explicitly because the default of 100 silently caps a
  backfill at 100 days — a failure that looks like missing data rather than a
  broken query.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dw.usp_BackfillClaimDenialDaily
    @StartDate DATE,
    @EndDate   DATE,
    @Reload    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @EndDate < @StartDate
    BEGIN
        RAISERROR('@EndDate precedes @StartDate; nothing to backfill.', 16, 1);
        RETURN;
    END

    /* MAXRECURSION caps at 32767, so a range longer than that would silently
       truncate the spine the same way the default 100 does. Fail loudly. */
    IF DATEDIFF(DAY, @StartDate, @EndDate) >= 32767
    BEGIN
        RAISERROR('Range exceeds the 32767 MAXRECURSION ceiling. Split the backfill.', 16, 1);
        RETURN;
    END

    DECLARE @Spine TABLE (PartitionDate DATE PRIMARY KEY);

    ;WITH DateSpine AS (
        SELECT @StartDate AS PartitionDate
        UNION ALL
        SELECT DATEADD(DAY, 1, PartitionDate) FROM DateSpine
        WHERE  PartitionDate < @EndDate
    )
    INSERT INTO @Spine (PartitionDate)
    SELECT PartitionDate FROM DateSpine
    OPTION (MAXRECURSION 32767);

    DECLARE @D DATE, @Done INT = 0, @Failed INT = 0;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.PartitionDate
        FROM   @Spine AS s
        WHERE  @Reload = 1
           OR  NOT EXISTS (SELECT 1 FROM ops.PartitionLog AS pl
                           WHERE pl.PartitionDate = s.PartitionDate
                             AND pl.LoadStatus IN ('SUCCESS','RELOADED'))
        ORDER BY s.PartitionDate;

    OPEN cur;
    FETCH NEXT FROM cur INTO @D;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* One date per transaction. A failure on day 40 of a 300-day backfill
           leaves days 1-39 committed and restartable. */
        BEGIN TRY
            EXEC dw.usp_LoadClaimDenialDaily @PartitionDate = @D, @Reload = @Reload;
            SET @Done += 1;
        END TRY
        BEGIN CATCH
            SET @Failed += 1;
            PRINT 'Partition failed, continuing: ' + CONVERT(VARCHAR(10), @D, 23)
                  + ' -- ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM cur INTO @D;
    END
    CLOSE cur; DEALLOCATE cur;

    PRINT 'Partitions loaded: ' + CAST(@Done AS VARCHAR(10))
        + '   failed: '        + CAST(@Failed AS VARCHAR(10));
END;
GO


/*==============================================================================
  5. PIPELINE HEALTH

  Feeds a second dashboard. Answers the three questions a consumer needs before
  trusting the first dashboard: is every day present, did any day load an
  implausible number of rows, and is the reject rate normal.
==============================================================================*/

CREATE OR ALTER VIEW ops.vw_PipelineHealth
AS
WITH Bounds AS (
    SELECT MIN(ServiceFromDate) AS MinDate, MAX(ServiceFromDate) AS MaxDate
    FROM   dbo.Claim
),
Spine AS (
    /* A contiguous calendar between the first and last service date, NOT
       SELECT DISTINCT ServiceFromDate FROM dbo.Claim.

       Two bugs fixed by the same change:

       1. A date with zero source claims produced no row at all, so the single
          most important failure — a whole day of source data never arrived —
          was invisible in the view whose job is to catch it.

       2. Rolling7DayAvgRows uses ROWS BETWEEN 7 PRECEDING, which counts rows,
          not days. Over a gapped date list that averaged the last seven
          *present* dates, which could span a month, while the column name and
          the threshold logic both claimed seven days.

       sys.all_columns is used as the tally source; it comfortably exceeds any
       plausible service-date range. */
    SELECT s.PartitionDate
    FROM (
        SELECT b.MaxDate,
               DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1,
                       b.MinDate) AS PartitionDate
        FROM       Bounds          AS b
        CROSS JOIN sys.all_columns AS ac
        WHERE      b.MinDate IS NOT NULL
    ) AS s
    WHERE s.PartitionDate <= s.MaxDate
),
Joined AS (
    SELECT e.PartitionDate,
           pl.LoadStatus, pl.RowsWritten, pl.SourceRowsRead, pl.RejectedRows,
           pl.LoadEndUtc,
           DATEDIFF(SECOND, pl.LoadStartUtc, pl.LoadEndUtc) AS LoadSeconds,
           /* Rolling 7-day baseline EXCLUDING the day itself, so one bad day
              cannot inflate the baseline it is being measured against. Now
              genuinely 7 days, because the spine is contiguous. */
           AVG(CAST(pl.RowsWritten AS DECIMAL(12,2))) OVER (
               ORDER BY e.PartitionDate
               ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING) AS Rolling7DayAvgRows
    FROM      Spine            AS e
    LEFT JOIN ops.PartitionLog AS pl ON pl.PartitionDate = e.PartitionDate
)
SELECT
    j.PartitionDate,
    ISNULL(j.LoadStatus,'MISSING') AS LoadStatus,
    j.RowsWritten, j.SourceRowsRead, j.RejectedRows,
    CAST(100.0 * j.RejectedRows
         / NULLIF(j.SourceRowsRead + j.RejectedRows, 0) AS DECIMAL(5,2)) AS RejectRatePct,
    j.LoadSeconds,
    CAST(j.Rolling7DayAvgRows AS DECIMAL(12,2)) AS Rolling7DayAvgRows,
    CASE
      WHEN j.LoadStatus IS NULL      THEN 'MISSING PARTITION'
      WHEN j.LoadStatus = 'FAILED'   THEN 'LOAD FAILED'
      WHEN j.RowsWritten = 0         THEN 'EMPTY PARTITION'
      WHEN j.Rolling7DayAvgRows IS NOT NULL
       AND j.RowsWritten < j.Rolling7DayAvgRows * 0.5
                                     THEN 'VOLUME DROP OVER 50 PCT'
      WHEN j.Rolling7DayAvgRows IS NOT NULL
       AND j.RowsWritten > j.Rolling7DayAvgRows * 2.0
                                     THEN 'VOLUME SPIKE OVER 100 PCT'
      WHEN 100.0 * j.RejectedRows
           / NULLIF(j.SourceRowsRead + j.RejectedRows, 0) > 2.0
                                     THEN 'REJECT RATE OVER THRESHOLD'
      ELSE 'OK'
    END AS HealthFlag
FROM Joined AS j;
GO

PRINT 'Schema, cleansing, warehouse, and pipeline created.';
GO


/*==============================================================================
  0b. CLEAR DATA  (child rows first; foreign keys enforce the order)
==============================================================================*/
DELETE FROM dbo.ClaimRuleResult;
DELETE FROM dbo.ClaimModifier;
DELETE FROM dbo.ClaimDenial;
DELETE FROM dbo.Claim;
DELETE FROM dbo.PriorAuth;
DELETE FROM dbo.AdjudicationRule;   -- must go before PlanConfig (FK)
DELETE FROM dbo.BenefitCategory;
DELETE FROM dbo.FeeSchedule;
DELETE FROM dbo.PlanConfig;
DELETE FROM dbo.Provider WHERE ParentProviderID IS NOT NULL;  -- children first
DELETE FROM dbo.Provider;
DELETE FROM dbo.Member;
DELETE FROM dw.FactClaimDenialDaily;
DELETE FROM ops.PartitionLog;
DELETE FROM ops.ClaimReject;

/* Nothing calls it any more. Dropping it stops a stale copy from an earlier
   build being picked up by anything. */
DROP FUNCTION IF EXISTS dbo.fnRand;
GO


/*==============================================================================
  1. CONFIGURATION REGISTER

  Three rows below are seeded with LoadedValue <> StandardValue. Those three
  are the entire finding. Everything else in this project exists to locate them
  and price them.
==============================================================================*/

INSERT INTO dbo.PlanConfig
    (ConfigKey, ConfigPath, ConfigScope, LoadedValue, StandardValue,
     StandardSource, EffectiveDate, LastChangedBy)
VALUES
 ('TimelyFilingDaysPar',     'dbo.PlanConfig / TimelyFilingDaysPar',     'ALL',
   90,  95,  'Participating provider agreement, claims submission article',
   '2025-01-01', 'CONFIG.LOAD'),                                    -- << DEFECT

 ('TimelyFilingDaysNonPar',  'dbo.PlanConfig / TimelyFilingDaysNonPar',  'ALL',
   365, 365, 'Provider manual, out-of-network claims submission',
   '2025-01-01', 'CONFIG.LOAD'),

 ('FeeSchedulePct_LTSS',     'dbo.FeeScheduleConfig / LtssPct',          'STAR+PLUS',
   80,  100, 'LTSS reimbursed at 100 percent of the state fee schedule',
   '2025-01-01', 'CONFIG.LOAD'),                                    -- << DEFECT

 ('FeeSchedulePct_DME',      'dbo.FeeScheduleConfig / DmePct',           'ALL',
   80,  80,  'DME reimbursed at 80 percent of the state fee schedule',
   '2025-01-01', 'CONFIG.LOAD'),

 ('AuthExempt_Transportation','dbo.AuthRuleConfig / ExemptCategories',   'ALL',
   0,   1,   'Transportation delegated to vendor; exempt from plan prior auth',
   '2025-01-01', 'CONFIG.LOAD'),                                    -- << DEFECT

 ('AuthExempt_Meal',         'dbo.AuthRuleConfig / ExemptCategories',    'D-SNP',
   1,   1,   'Post-discharge meal benefit exempt from prior authorization',
   '2025-01-01', 'CONFIG.LOAD');

-- Every other provider type prices at 100 percent of schedule.
INSERT INTO dbo.PlanConfig
    (ConfigKey, ConfigPath, ConfigScope, LoadedValue, StandardValue,
     StandardSource, EffectiveDate, LastChangedBy)
SELECT 'FeeSchedulePct_' + t.ProviderType,
       'dbo.FeeScheduleConfig / Pct_' + t.ProviderType, 'ALL',
       100, 100, 'Contracted at 100 percent of the state fee schedule',
       '2025-01-01', 'CONFIG.LOAD'
FROM  (VALUES ('Physician'),('Hospital-Based'),('Ancillary'),('Facility'),
              ('Transportation'),('BehavioralHealth')) AS t(ProviderType);


/* Rule sequence is the evaluation order. First failure denies. */
INSERT INTO dbo.AdjudicationRule (RuleID, RuleName, RuleSequence, ConfigKey) VALUES
 ('R-010','Member eligibility on date of service',          10, NULL),
 ('R-020','Provider contract effective on date of service', 20, NULL),
 ('R-030','Duplicate submission',                           30, NULL),
 ('R-040','Delegated vendor benefit routing',               40, NULL),
 ('R-050','Prior authorization on file',                    50, 'AuthExempt_Transportation'),
 ('R-060','Timely filing',                                  60, 'TimelyFilingDaysPar'),
 ('R-070','Fee schedule pricing',                           70, 'FeeSchedulePct_LTSS');


INSERT INTO dbo.BenefitCategory
    (ProviderType, BenefitCategory, AuthRequiredFlag, DelegatedVendor, AuthExemptFlag)
VALUES
 ('Physician',       'Medical',        0, NULL,             0),
 ('Hospital-Based',  'Medical',        0, NULL,             0),
 ('Ancillary',       'Medical',        0, NULL,             0),
 ('Facility',        'Medical',        1, NULL,             0),
 ('LTSS',            'LTSS',           1, NULL,             0),
 ('DME',             'DME',            1, NULL,             0),
 ('Transportation',  'Transportation', 1, 'MTM',            1),  -- exempt by contract
 ('BehavioralHealth','Behavioral',     1, NULL,             0),
 ('Pharmacy',        'Pharmacy',       0, 'Navitus',        0),  -- fully carved out
 ('Dental',          'Dental',         0, 'FCL Dental',     0),
 ('Vision',          'Vision',         0, 'Envolve Vision', 0);


INSERT INTO dbo.FeeSchedule (ProcedureCode, EffectiveDate, TermDate, ScheduleRate) VALUES
 ('99213','2025-01-01',NULL, 102.30),('99214','2025-01-01',NULL, 143.84),
 ('99395','2025-01-01',NULL, 153.76),('99283','2025-01-01',NULL, 396.80),
 ('99285','2025-01-01',NULL, 917.60),('00790','2025-01-01',NULL, 694.40),
 ('70553','2025-01-01',NULL,1171.80),('80053','2025-01-01',NULL,  48.36),
 ('93306','2025-01-01',NULL, 706.80),('45378','2025-01-01',NULL,1457.00),
 ('29881','2025-01-01',NULL,3658.00),('59400','2025-01-01',NULL,2926.40),
 ('T1019','2025-01-01',NULL,  26.04),('S5150','2025-01-01',NULL,  23.56),
 ('S5102','2025-01-01',NULL,  59.52),('E0601','2025-01-01',NULL, 781.20),
 ('K0001','2025-01-01',NULL, 322.40),('E1390','2025-01-01',NULL, 440.20),
 ('A0120','2025-01-01',NULL,  42.16),('A0130','2025-01-01',NULL,  58.90),
 ('90837','2025-01-01',NULL, 130.20),('90792','2025-01-01',NULL, 244.90),
 ('H0015','2025-01-01',NULL, 297.60);
GO


/*==============================================================================
  2. GENERATOR SUPPORT
==============================================================================*/

/* A numbers table drives all generation. Built from cross-joined constants so
   it does not depend on any system view. */
;WITH L0 AS (SELECT 1 AS c UNION ALL SELECT 1),
      L1 AS (SELECT a.c FROM L0 a CROSS JOIN L0 b),
      L2 AS (SELECT a.c FROM L1 a CROSS JOIN L1 b),
      L3 AS (SELECT a.c FROM L2 a CROSS JOIN L2 b),
      L4 AS (SELECT a.c FROM L3 a CROSS JOIN L3 b),
      Nums AS (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N FROM L4)
INSERT INTO dbo.Numbers (N)
SELECT TOP (10000) N FROM Nums
WHERE NOT EXISTS (SELECT 1 FROM dbo.Numbers);
GO




/*==============================================================================
  3. SYNTHETIC DATA
==============================================================================*/

/*--- Members: 900, about 2 percent with coverage that terminates mid-file ---*/
INSERT INTO dbo.Member (MemberID, LOB, CoverageEffDate, CoverageTermDate, CountyCode)
SELECT 'M6' + RIGHT('0000000' + CAST(n.N AS VARCHAR(7)), 7),
       CHOOSE(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                           + CAST(11 AS BIGINT) * 40503)) % 5 + 1, 'STAR','CHIP','STAR+PLUS','HIM','D-SNP'),
       '2025-01-01',
       CASE WHEN ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                              + CAST(23 AS BIGINT) * 40503)) % 1000 < 22
            THEN DATEADD(DAY, ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                           + CAST(29 AS BIGINT) * 40503)) % 300, '2025-10-01')
            ELSE NULL END,
       RIGHT('000' + CAST(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                       + CAST(31 AS BIGINT) * 40503)) % 20 + 101 AS VARCHAR(3)), 3)
FROM   dbo.Numbers AS n
WHERE  n.N <= 900;

/*--- Providers: 40 parent organizations ---*/
INSERT INTO dbo.Provider
    (ProviderID, ParentProviderID, ProviderName, NPI, ProviderType,
     ParticipatingFlag, ContractEffDate, ContractTermDate)
SELECT 'P7' + RIGHT('00000' + CAST(n.N AS VARCHAR(5)), 5),
       NULL,
       CHOOSE(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                           + CAST(41 AS BIGINT) * 40503)) % 8 + 1,
              'Bayou City','Gulf Coast','Loop Central','Southbelt',
              'Northline','Clear Creek','Magnolia Park','Alief')
         + ' Health Network ' + CAST(n.N AS VARCHAR(5)),
       RIGHT('0000000000' + CAST(1000000000 + n.N * 37 AS VARCHAR(10)), 10),
       'Physician', 1, '2023-01-01', NULL
FROM   dbo.Numbers AS n
WHERE  n.N <= 40;

/*--- Providers: 260 billing entities beneath them, so the recursive hierarchy
      rollup in 03 has real depth to traverse ---*/
INSERT INTO dbo.Provider
    (ProviderID, ParentProviderID, ProviderName, NPI, ProviderType,
     ParticipatingFlag, ContractEffDate, ContractTermDate)
SELECT 'P8' + RIGHT('00000' + CAST(n.N AS VARCHAR(5)), 5),
       'P7' + RIGHT('00000' + CAST(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                                + CAST(43 AS BIGINT) * 40503)) % 40 + 1 AS VARCHAR(5)), 5),
       CHOOSE(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                           + CAST(47 AS BIGINT) * 40503)) % 8 + 1,
              'Bayou City','Gulf Coast','Loop Central','Southbelt',
              'Northline','Clear Creek','Magnolia Park','Alief')
         + ' ' +
       CHOOSE(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                           + CAST(53 AS BIGINT) * 40503)) % 6 + 1,
              'Family Medicine','Imaging Center','Surgery Center',
              'Home Supports','Medical Equipment','Counseling Center')
         + ' ' + CAST(n.N AS VARCHAR(5)),
       RIGHT('0000000000' + CAST(1200000000 + n.N * 41 AS VARCHAR(10)), 10),
       CHOOSE(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                           + CAST(59 AS BIGINT) * 40503)) % 8 + 1,
              'Physician','Hospital-Based','Ancillary','Facility',
              'LTSS','DME','Transportation','BehavioralHealth'),
       CASE WHEN ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                              + CAST(61 AS BIGINT) * 40503)) % 100 < 16 THEN 0 ELSE 1 END,      -- 16% non-par
       CASE WHEN ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                              + CAST(67 AS BIGINT) * 40503)) % 1000 < 11                        -- 1.1% loaded
            THEN DATEADD(DAY, ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                           + CAST(71 AS BIGINT) * 40503)) % 200, '2026-01-01')  -- with a future
            ELSE DATEADD(DAY, ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                           + CAST(73 AS BIGINT) * 40503)) % 700, '2022-06-01')  -- effective date
       END,
       NULL
FROM   dbo.Numbers AS n
WHERE  n.N <= 260;


/*--- Procedure catalogue, mapped to the provider type that bills it ---*/
DROP TABLE IF EXISTS #Proc;
CREATE TABLE #Proc (ProviderType VARCHAR(32), Slot INT, ProcedureCode VARCHAR(8),
                    CONSTRAINT PK_Proc PRIMARY KEY (ProviderType, Slot));
INSERT INTO #Proc VALUES
 ('Physician',0,'99213'),('Physician',1,'99214'),('Physician',2,'99395'),
 ('Hospital-Based',0,'99283'),('Hospital-Based',1,'99285'),('Hospital-Based',2,'00790'),
 ('Ancillary',0,'70553'),('Ancillary',1,'80053'),('Ancillary',2,'93306'),
 ('Facility',0,'45378'),('Facility',1,'29881'),('Facility',2,'59400'),
 ('LTSS',0,'T1019'),('LTSS',1,'S5150'),('LTSS',2,'S5102'),
 ('DME',0,'E0601'),('DME',1,'K0001'),('DME',2,'E1390'),
 ('Transportation',0,'A0120'),('Transportation',1,'A0130'),('Transportation',2,'A0120'),
 ('BehavioralHealth',0,'90837'),('BehavioralHealth',1,'90792'),('BehavioralHealth',2,'H0015');


/*--- Claims: 2,400, dates of service October 2025 through August 2026.

      Two things are engineered on purpose:

      1. About 3 percent of participating claims are received between day 91
         and day 95. Those were filed on time under the 95-day contract and
         deny only because the configuration says 90.

      2. Transportation claims almost never carry a plan-side authorization,
         because the benefit is delegated to the vendor. That is correct
         real-world behavior. It produces denials only because the exemption
         is missing from the auth rule configuration.
---*/
;WITH Base AS (
    SELECT n.N,
           'CLM-2026-' + RIGHT('0000000' + CAST(104200 + n.N * 7 AS VARCHAR(7)), 7) AS ClaimID,
           'M6' + RIGHT('0000000' + CAST(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                                      + CAST(101 AS BIGINT) * 40503)) % 900 + 1 AS VARCHAR(7)), 7) AS MemberID,
           'P8' + RIGHT('00000'  + CAST(ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                                     + CAST(103 AS BIGINT) * 40503)) % 260 + 1 AS VARCHAR(5)), 5) AS ProviderID,
           DATEADD(DAY, ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                                     + CAST(107 AS BIGINT) * 40503)) % 300, '2025-10-01') AS ServiceFromDate,
           ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                        + CAST(109 AS BIGINT) * 40503)) % 1000 AS LagRoll,
           ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                        + CAST(113 AS BIGINT) * 40503)) % 3    AS ProcSlot,
           ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                        + CAST(127 AS BIGINT) * 40503)) % 100  AS UnitRoll,
           ABS(CHECKSUM(CAST(n.N AS BIGINT) * 2654435761
                        + CAST(131 AS BIGINT) * 40503)) % 60   AS PriceJitter
    FROM   dbo.Numbers AS n
    WHERE  n.N <= 2400
),
Joined AS (
    SELECT b.*, p.ProviderType, p.ParticipatingFlag, m.LOB, pc.ProcedureCode,
           CASE WHEN p.ProviderType = 'LTSS' THEN 8 + (b.UnitRoll % 33) ELSE 1 END AS Units
    FROM        Base         AS b
    JOIN        dbo.Provider AS p ON p.ProviderID = b.ProviderID
    JOIN        dbo.Member   AS m ON m.MemberID   = b.MemberID
    CROSS APPLY (SELECT TOP 1 ProcedureCode FROM #Proc
                 WHERE ProviderType = p.ProviderType AND Slot = b.ProcSlot) AS pc
)
INSERT INTO dbo.Claim
    (ClaimID, MemberID, ProviderID, LOB, ProcedureCode, ModifierList, Units,
     ServiceFromDate, ServiceThruDate, ReceivedDate, BilledAmount, AdjudicationStatus)
SELECT j.ClaimID, j.MemberID, j.ProviderID, j.LOB, j.ProcedureCode, NULL, j.Units,
       j.ServiceFromDate,
       j.ServiceFromDate,
       DATEADD(DAY,
         CASE
           WHEN j.ParticipatingFlag = 1 AND j.LagRoll < 30
                THEN 91 + (j.LagRoll % 5)                    -- the 91-95 day gap
           WHEN j.LagRoll < 48
                THEN CASE WHEN j.ParticipatingFlag = 1
                          THEN 98  + (j.LagRoll % 60)        -- genuinely late
                          ELSE 368 + (j.LagRoll % 60) END
           ELSE 2 + (j.LagRoll % 74)                         -- on time
         END, j.ServiceFromDate),
       CAST(fs.ScheduleRate * j.Units * (1.45 + j.PriceJitter / 100.0) AS DECIMAL(12,2)),
       'PENDING'
FROM   Joined AS j
/* CROSS APPLY TOP 1 with the date range, not a bare JOIN on ProcedureCode.

   The bare join was wrong two ways. It priced the claim off whatever fee
   schedule row happened to exist regardless of whether that row was in effect
   on the date of service — so a claim dated 2026 could be billed off a rate
   that termed in 2025. And with more than one effective-dated row per code it
   fans out, producing multiple rows per claim and a duplicate-key violation on
   ClaimID that takes the whole INSERT down and leaves Claims=0.

   One row per code in the current seed hides both. Add a 2026 schedule version
   and the seed breaks. This is the same OUTER APPLY TOP 1 pattern already used
   in dw.usp_LoadClaimDenialDaily and the join already used in
   usp_AdjudicateClaims below — all three now agree. */
CROSS APPLY (
    SELECT TOP (1) f.ScheduleRate
    FROM   dbo.FeeSchedule AS f
    WHERE  f.ProcedureCode = j.ProcedureCode
      AND  j.ServiceFromDate >= f.EffectiveDate
      AND  j.ServiceFromDate <= ISNULL(f.TermDate, '9999-12-31')
    ORDER BY f.EffectiveDate DESC
) AS fs;

/* A silently short claim count means a procedure code in #Proc has no fee
   schedule row covering some service date, and CROSS APPLY dropped the row. */
IF (SELECT COUNT(*) FROM dbo.Claim) <> 2400
BEGIN
    DECLARE @Seeded INT;
    SELECT @Seeded = COUNT(*) FROM dbo.Claim;
    RAISERROR('STOP: expected 2400 claims, seeded %d. A procedure code has no fee schedule row in effect on some date of service.', 16, 1, @Seeded);
    SET NOEXEC ON;
END


/*--- Authorizations. Approved auths exist for most claims that need one —
      except transportation, where a plan-side auth is almost never on file. ---*/
INSERT INTO dbo.PriorAuth (MemberID, ProviderType, AuthEffDate, AuthThruDate, AuthStatus)
SELECT c.MemberID, p.ProviderType,
       DATEADD(DAY, -30, c.ServiceFromDate),
       DATEADD(DAY,  30, c.ServiceFromDate),
       'APPROVED'
FROM   dbo.Claim           AS c
JOIN   dbo.Provider        AS p  ON p.ProviderID   = c.ProviderID
JOIN   dbo.BenefitCategory AS bc ON bc.ProviderType = p.ProviderType
WHERE  bc.AuthRequiredFlag = 1
  AND  ABS(CHECKSUM(CAST(TRY_CAST(RIGHT(c.ClaimID, 7) AS INT) AS BIGINT) * 2654435761
                  + CAST(137 AS BIGINT) * 40503)) % 100
       >= CASE WHEN p.ProviderType = 'Transportation' THEN 88   -- 88% have none
               ELSE 8 END;                                       -- 8% have none
GO


/*==============================================================================
  4. THE ADJUDICATION ENGINE

  Set-based, not row-by-row. Every rule is evaluated for every claim into
  #Eval, then a single ordered CASE picks the first failure. That mirrors the
  engine — first failure denies, later rules never run — while keeping the full
  chain available for the trace.
==============================================================================*/

CREATE OR ALTER PROCEDURE dbo.usp_AdjudicateClaims
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Read the LIVE configuration once. Change a value in dbo.PlanConfig and
    -- re-run this procedure; the outcomes change. That is the demo.
    DECLARE @FilingPar INT, @FilingNonPar INT, @TransportExempt BIT;
    SELECT @FilingPar       = LoadedValue FROM dbo.PlanConfig WHERE ConfigKey='TimelyFilingDaysPar';
    SELECT @FilingNonPar    = LoadedValue FROM dbo.PlanConfig WHERE ConfigKey='TimelyFilingDaysNonPar';
    SELECT @TransportExempt = LoadedValue FROM dbo.PlanConfig WHERE ConfigKey='AuthExempt_Transportation';

    DROP TABLE IF EXISTS #Eval;

    ;WITH Dupes AS (
        /* A duplicate is derived from the data, not flagged on the claim:
           same member, provider, code, and date of service. */
        SELECT c.ClaimID,
               ROW_NUMBER() OVER (PARTITION BY c.MemberID, c.ProviderID,
                                               c.ProcedureCode, c.ServiceFromDate
                                  ORDER BY c.ClaimID) AS SubmissionSeq
        FROM   dbo.Claim AS c
    )
    SELECT
        c.ClaimID, c.MemberID, c.LOB, c.ServiceFromDate, c.ReceivedDate,
        c.BilledAmount, c.Units,
        p.ProviderType, p.ParticipatingFlag,
        bc.DelegatedVendor, bc.AuthRequiredFlag,

        DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate)                    AS FilingLagDays,
        CASE WHEN p.ParticipatingFlag=1 THEN @FilingPar ELSE @FilingNonPar END AS FilingLimit,
        CASE WHEN p.ParticipatingFlag=1 THEN 95 ELSE 365 END                AS FilingStandard,

        -- Priced at the loaded percentage, and at the required percentage.
        CAST(fs.ScheduleRate * c.Units * cfg.LoadedValue   / 100.0 AS DECIMAL(12,2)) AS AllowedLoaded,
        CAST(fs.ScheduleRate * c.Units * cfg.StandardValue / 100.0 AS DECIMAL(12,2)) AS AllowedStandard,
        cfg.LoadedValue   AS PricePctLoaded,
        cfg.StandardValue AS PricePctStandard,

        /* R-010 member eligible on DOS */
        CASE WHEN m.CoverageTermDate IS NOT NULL
              AND c.ServiceFromDate > m.CoverageTermDate THEN 1 ELSE 0 END AS Fail010,

        /* R-020 provider contract effective on DOS */
        CASE WHEN p.ParticipatingFlag = 1
              AND p.ContractEffDate > c.ServiceFromDate  THEN 1 ELSE 0 END AS Fail020,

        /* R-030 duplicate */
        CASE WHEN d.SubmissionSeq > 1                    THEN 1 ELSE 0 END AS Fail030,

        /* R-040 delegated benefit submitted to the plan in error */
        CASE WHEN bc.DelegatedVendor IS NOT NULL
              AND bc.ProviderType IN ('Pharmacy','Dental','Vision')
                                                         THEN 1 ELSE 0 END AS Fail040,

        /* R-050 auth required, none on file, and the category is not exempt.
           The exemption comes from configuration — that is the defect. */
        CASE WHEN bc.AuthRequiredFlag = 1
              AND NOT (p.ProviderType = 'Transportation' AND @TransportExempt = 1)
              AND NOT EXISTS (SELECT 1 FROM dbo.PriorAuth AS a
                              WHERE a.MemberID     = c.MemberID
                                AND a.ProviderType = p.ProviderType
                                AND a.AuthStatus   = 'APPROVED'
                                AND c.ServiceFromDate BETWEEN a.AuthEffDate AND a.AuthThruDate)
             THEN 1 ELSE 0 END AS Fail050,

        /* R-060 timely filing, measured against the LOADED limit */
        CASE WHEN DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate)
                  > CASE WHEN p.ParticipatingFlag=1 THEN @FilingPar ELSE @FilingNonPar END
             THEN 1 ELSE 0 END AS Fail060,

        /* R-070 pricing. A SOFT failure: the claim pays, it just pays the wrong
           amount. It never denies, so it never appears in denial reporting —
           which is exactly why it needs its own rule. */
        CASE WHEN cfg.LoadedValue <> cfg.StandardValue THEN 1 ELSE 0 END AS Fail070

    INTO   #Eval
    FROM   dbo.Claim           AS c
    JOIN   dbo.Member          AS m   ON m.MemberID      = c.MemberID
    JOIN   dbo.Provider        AS p   ON p.ProviderID    = c.ProviderID
    JOIN   dbo.BenefitCategory AS bc  ON bc.ProviderType = p.ProviderType
    JOIN   Dupes               AS d   ON d.ClaimID       = c.ClaimID
    /* CROSS APPLY TOP 1, matching the claim seed and the warehouse load. The
       date-bounded JOIN that was here is correct on effective dating but still
       fans out across overlapping schedule versions, which would silently
       double-count a claim in #Eval and in ClaimRuleResult. */
    CROSS APPLY (
        SELECT TOP (1) f.ScheduleRate
        FROM   dbo.FeeSchedule AS f
        WHERE  f.ProcedureCode = c.ProcedureCode
          AND  c.ServiceFromDate >= f.EffectiveDate
          AND  c.ServiceFromDate <= ISNULL(f.TermDate, '9999-12-31')
        ORDER BY f.EffectiveDate DESC
    ) AS fs
    JOIN   dbo.PlanConfig      AS cfg ON cfg.ConfigKey = 'FeeSchedulePct_' + p.ProviderType;

    CREATE CLUSTERED INDEX IX_Eval ON #Eval (ClaimID);


    /*--- First failure wins. This CASE cascade IS the rule sequence. ---*/
    DROP TABLE IF EXISTS #Outcome;

    SELECT e.*,
           CASE WHEN e.Fail010=1 THEN 'R-010' WHEN e.Fail020=1 THEN 'R-020'
                WHEN e.Fail030=1 THEN 'R-030' WHEN e.Fail040=1 THEN 'R-040'
                WHEN e.Fail050=1 THEN 'R-050' WHEN e.Fail060=1 THEN 'R-060'
                ELSE NULL END AS DenyingRuleID,
           CASE WHEN e.Fail010=1 THEN 'D-EL01' WHEN e.Fail020=1 THEN 'D-PR04'
                WHEN e.Fail030=1 THEN 'D-DU01' WHEN e.Fail040=1 THEN 'D-CO02'
                WHEN e.Fail050=1 THEN 'D-AU01' WHEN e.Fail060=1 THEN 'D-TF01'
                ELSE NULL END AS DenialCode
    INTO   #Outcome
    FROM   #Eval AS e;

    CREATE CLUSTERED INDEX IX_Outcome ON #Outcome (ClaimID);


    /*--- Write results back ---*/
    DELETE FROM dbo.ClaimRuleResult;
    DELETE FROM dbo.ClaimDenial;

    INSERT INTO dbo.ClaimDenial (ClaimID, RuleID, DenialCode)
    SELECT o.ClaimID, o.DenyingRuleID, o.DenialCode
    FROM   #Outcome AS o
    WHERE  o.DenyingRuleID IS NOT NULL;

    UPDATE c
    SET    c.AdjudicationStatus    = CASE WHEN o.DenyingRuleID IS NOT NULL
                                          THEN 'DENIED' ELSE 'PAID' END,
           c.ExpectedAllowedAmount = o.AllowedStandard,
           c.PaidAmount            = CASE WHEN o.DenyingRuleID IS NOT NULL
                                          THEN 0 ELSE o.AllowedLoaded END,
           c.AdjudicatedDate       = DATEADD(DAY, 14, c.ReceivedDate)
    FROM   dbo.Claim AS c
    JOIN   #Outcome  AS o ON o.ClaimID = c.ClaimID;

    /* Full chain for the trace: PASS, FAIL, or SKIP because an earlier rule
       already denied the claim. */
    INSERT INTO dbo.ClaimRuleResult (ClaimID, RuleID, RuleResult, Evidence)
    SELECT o.ClaimID, r.RuleID,
           CASE
             WHEN o.DenyingRuleID IS NOT NULL
              AND r.RuleSequence > (SELECT RuleSequence FROM dbo.AdjudicationRule
                                    WHERE RuleID = o.DenyingRuleID)  THEN 'SKIP'
             WHEN r.RuleID='R-010' AND o.Fail010=1                   THEN 'FAIL'
             WHEN r.RuleID='R-020' AND o.Fail020=1                   THEN 'FAIL'
             WHEN r.RuleID='R-030' AND o.Fail030=1                   THEN 'FAIL'
             WHEN r.RuleID='R-040' AND o.Fail040=1                   THEN 'FAIL'
             WHEN r.RuleID='R-050' AND o.Fail050=1                   THEN 'FAIL'
             WHEN r.RuleID='R-060' AND o.Fail060=1                   THEN 'FAIL'
             WHEN r.RuleID='R-070' AND o.Fail070=1                   THEN 'FAIL'
             ELSE 'PASS'
           END,
           CASE r.RuleID
             WHEN 'R-010' THEN CONCAT('Member ', o.MemberID, ', DOS ', o.ServiceFromDate)
             WHEN 'R-050' THEN CONCAT('Category ', o.ProviderType,
                                      CASE WHEN o.DelegatedVendor IS NOT NULL
                                           THEN ' delegated to ' + o.DelegatedVendor
                                           ELSE '' END)
             WHEN 'R-060' THEN CONCAT('Filing lag ', o.FilingLagDays,
                                      ' days against a ', o.FilingLimit,
                                      ' day limit; contractual limit is ',
                                      o.FilingStandard, ' days')
             WHEN 'R-070' THEN CONCAT('Priced at ', o.PricePctLoaded,
                                      ' pct against a contracted ', o.PricePctStandard,
                                      ' pct; allowed ', o.AllowedLoaded,
                                      ' versus ', o.AllowedStandard)
             ELSE NULL
           END
    FROM   #Outcome                AS o
    CROSS JOIN dbo.AdjudicationRule AS r;

    /* Counts go into variables first. PRINT takes a scalar expression and a
       subquery is not one, so embedding SELECT COUNT(*) inside the CAST is a
       compile-time error (Msg 1046) -- the procedure fails to CREATE, which
       looks at runtime like the procedure was never in the script. */
    DECLARE @ClaimCount INT, @DeniedCount INT;
    SELECT @ClaimCount  = COUNT(*) FROM dbo.Claim;
    SELECT @DeniedCount = COUNT(*) FROM dbo.ClaimDenial;

    PRINT CONCAT('Adjudication complete: ', @ClaimCount, ' claims, ',
                 @DeniedCount, ' denied.');
END;
GO


/*==============================================================================
  5. RUN IT
==============================================================================*/

EXEC dbo.usp_AdjudicateClaims;

/* Nothing should still be PENDING after adjudication. A non-zero count means a
   claim fell out of the #Eval joins — most likely a provider type with no
   dbo.BenefitCategory row or no FeeSchedulePct_ config key. Those claims would
   land in the warehouse as PENDING ADJUDICATION rather than being counted. */
IF EXISTS (SELECT 1 FROM dbo.Claim WHERE AdjudicationStatus = 'PENDING')
BEGIN
    DECLARE @Pending INT;
    SELECT @Pending = COUNT(*) FROM dbo.Claim WHERE AdjudicationStatus = 'PENDING';
    RAISERROR('WARNING: %d claims are still PENDING after adjudication. Check dbo.BenefitCategory and the FeeSchedulePct_ config keys for every provider type in use.', 10, 1, @Pending) WITH NOWAIT;
END
GO

/*--- Build the warehouse. The range is derived from the data rather than
      hardcoded: service dates run 300 days from 2025-10-01, so the previous
      fixed 2026-08-16 end date backfilled ~20 empty partitions that then
      reported as EMPTY PARTITION in the health view. ---*/
DECLARE @From DATE, @To DATE;
SELECT @From = MIN(ServiceFromDate), @To = MAX(ServiceFromDate) FROM dbo.Claim;

PRINT CONCAT('Backfilling ', CONVERT(VARCHAR(10), @From, 23),
             ' through ',    CONVERT(VARCHAR(10), @To, 23),
             ' (', DATEDIFF(DAY, @From, @To) + 1, ' partitions)');

EXEC dw.usp_BackfillClaimDenialDaily @StartDate = @From, @EndDate = @To;





/*==============================================================================
  BUILD VERIFICATION

  One grid. Every row should read OK. Anything else names what is missing and
  which part of the file did not run.
==============================================================================*/
;WITH Expected AS (
    SELECT 'dbo.Claim' AS ObjectName, 'table' AS Kind UNION ALL
    SELECT 'dbo.Member','table'                       UNION ALL
    SELECT 'dbo.Provider','table'                     UNION ALL
    SELECT 'dbo.PlanConfig','table'                   UNION ALL
    SELECT 'dbo.FeeSchedule','table'                  UNION ALL
    SELECT 'dbo.ClaimDenial','table'                  UNION ALL
    SELECT 'dbo.ClaimRuleResult','table'              UNION ALL
    SELECT 'dw.FactClaimDenialDaily','table'          UNION ALL
    SELECT 'ops.PartitionLog','table'                 UNION ALL
    SELECT 'ops.ClaimReject','table'                  UNION ALL
    SELECT 'stg.ClaimImport','table'                  UNION ALL
    SELECT 'stg.usp_CleanseAndLoadClaims','procedure' UNION ALL
    SELECT 'dw.usp_LoadClaimDenialDaily','procedure'  UNION ALL
    SELECT 'dw.usp_BackfillClaimDenialDaily','procedure' UNION ALL
    SELECT 'dbo.usp_AdjudicateClaims','procedure'     UNION ALL
    SELECT 'ops.vw_PipelineHealth','view'
)
SELECT   e.Kind,
         e.ObjectName,
         CASE WHEN OBJECT_ID(e.ObjectName) IS NULL THEN 'MISSING' ELSE 'OK' END AS Status
FROM     Expected AS e
ORDER BY CASE WHEN OBJECT_ID(e.ObjectName) IS NULL THEN 0 ELSE 1 END, e.Kind, e.ObjectName;

SELECT 'Members'    AS Metric, COUNT(*) AS Actual, 900  AS Expected,
       CASE WHEN COUNT(*) = 900  THEN 'OK' ELSE 'CHECK' END AS Status FROM dbo.Member
UNION ALL
SELECT 'Providers',        COUNT(*), 300,
       CASE WHEN COUNT(*) = 300  THEN 'OK' ELSE 'CHECK' END FROM dbo.Provider
UNION ALL
SELECT 'Claims',           COUNT(*), 2400,
       CASE WHEN COUNT(*) = 2400 THEN 'OK' ELSE 'CHECK' END FROM dbo.Claim
UNION ALL
SELECT 'Claims PENDING',   COUNT(*), 0,
       CASE WHEN COUNT(*) = 0    THEN 'OK' ELSE 'CHECK' END
       FROM dbo.Claim WHERE AdjudicationStatus = 'PENDING'
UNION ALL
SELECT 'Denied claims',    COUNT(*), NULL, 'INFO' FROM dbo.ClaimDenial
UNION ALL
SELECT 'Rule trace rows',  COUNT(*), NULL, 'INFO' FROM dbo.ClaimRuleResult
UNION ALL
SELECT 'Warehouse rows',   COUNT(*), NULL, 'INFO' FROM dw.FactClaimDenialDaily
UNION ALL
SELECT 'Partitions loaded',COUNT(*), NULL, 'INFO'
       FROM ops.PartitionLog WHERE LoadStatus IN ('SUCCESS','RELOADED')
UNION ALL
SELECT 'Partitions FAILED',COUNT(*), 0,
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'CHECK' END
       FROM ops.PartitionLog WHERE LoadStatus = 'FAILED';

PRINT 'Build complete. If every Status reads OK, run 03_analysis_and_tests.sql.';
GO

SET NOEXEC OFF;
GO
