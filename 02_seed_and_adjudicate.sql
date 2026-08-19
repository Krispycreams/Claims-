/*==============================================================================
  02 — SEED AND ADJUDICATE
  SQL Server 2016+ (compat level 130+) — local install

  Carlos M. Puente

  Run order:  01_schema.sql  ->  02_seed_and_adjudicate.sql  ->  03_analysis_and_tests.sql

  Contents
    0.  Guards and clear
    1.  Reference data: configuration, rules, benefit categories, fee schedule
    2.  Generator support: numbers table, deterministic random
    3.  Synthetic members, providers, claims, authorizations
    4.  The adjudication engine
    5.  Run it

  ----------------------------------------------------------------------------
  ON DETERMINISTIC RANDOMNESS

  Every generated value derives from a hash of the row number, so the file
  rebuilds identically every time and the dollar figures are reproducible.

  The hash is written INLINE at each site rather than wrapped in a scalar
  function. An earlier version used dbo.fnRand(@Seed, @Salt, @Range). That is
  the more readable form and it is the wrong one: a scalar UDF is invoked once
  per row per call site -- roughly 30,000 times across this file -- and below
  compatibility level 150 SQL Server cannot inline it. Each invocation is a
  separate execution context, so the seed spent minutes on arithmetic that
  costs microseconds. Inline, the optimizer folds the constants and evaluates
  the expression as part of the set operation.

  The pattern, applied at all 21 sites below:

      ABS(CHECKSUM(CAST(<seed> AS BIGINT) * 2654435761
                 + CAST(<salt> AS BIGINT) * 40503)) % <range>

  The CASTs are load-bearing and must not be simplified away. CHECKSUM is
  type-sensitive: 2654435761 exceeds the INT range so it types as NUMERIC, and
  whether the salt term arrives as BIGINT or INT changes the precision of the
  sum and therefore the CHECKSUM result. Writing CAST(41 AS BIGINT) * 40503
  rather than the folded literal 1660623 costs nothing at runtime -- it is a
  constant expression resolved at compile time -- and keeps every generated
  value identical to the UDF version, so previously reported figures hold.

  Salts are distinct primes per attribute so that two attributes of the same
  row do not correlate.
  ----------------------------------------------------------------------------
==============================================================================*/

SET NOEXEC OFF;   -- clear any leftover state from a previous failed run
GO

USE ClaimsAnalytics;
GO

/*------------------------------------------------------------------------------
  0a. GUARDS

  Same pattern as 01. Without these, a failed USE means every INSERT below
  lands in master and you get a wall of cascade errors instead of one message.
  RAISERROR alone does not stop a multi-batch script; NOEXEC does.
------------------------------------------------------------------------------*/
IF DB_NAME() <> 'ClaimsAnalytics'
BEGIN
    RAISERROR('STOP: not connected to ClaimsAnalytics. Check the database dropdown in the SSMS toolbar. Nothing further in this script was executed.', 16, 1);
    SET NOEXEC ON;
END
GO

/* 01 has to have run first. Checking one table from each schema catches a
   partial or failed 01 run, which otherwise surfaces as an invalid-object
   error two hundred lines down. */
IF OBJECT_ID('dbo.Claim')                IS NULL
OR OBJECT_ID('dbo.Numbers')              IS NULL
OR OBJECT_ID('dbo.PriorAuth')            IS NULL
OR OBJECT_ID('dw.FactClaimDenialDaily')  IS NULL
OR OBJECT_ID('ops.PartitionLog')         IS NULL
OR OBJECT_ID('dw.usp_BackfillClaimDenialDaily') IS NULL
BEGIN
    RAISERROR('STOP: schema objects from 01_schema.sql are missing. Run 01_schema.sql to completion first. Nothing further in this script was executed.', 16, 1);
    SET NOEXEC ON;
END
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

PRINT '02 complete. Next: run 03_analysis_and_tests.sql';
GO

/* Always the last line. SET statements execute even under NOEXEC ON, so this
   restores the session whether the script succeeded or bailed at a guard. */
SET NOEXEC OFF;
GO
