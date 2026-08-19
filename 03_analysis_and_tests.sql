/*==============================================================================
  03 — ANALYSIS AND TESTS
  SQL Server 2016+ (compat level 130+)

  Carlos M. Puente

  Run order:  01_schema.sql -> 02_seed_and_adjudicate.sql -> 03_analysis_and_tests.sql

  Contents
    0.  Guards
    1.  TESTS — 14 assertions. Run these first; the analysis is only
        meaningful if they pass.
    2.  The configuration register: what is loaded vs what is required
    3.  Denial mix, and the split between correct denials and defects
    4.  Exposure priced per defect
    5.  Provider exposure, ranked, and rolled up the hierarchy
    6.  Pipeline health
    7.  PROOF: correct the configuration in a transaction, re-adjudicate,
        measure the delta, roll back

  Nothing in this file writes committed data. Section 7 opens an explicit
  transaction and rolls it back.
==============================================================================*/

SET NOEXEC OFF;
GO

USE ClaimsAnalytics;
GO

IF DB_NAME() <> 'ClaimsAnalytics'
BEGIN
    RAISERROR('STOP: not connected to ClaimsAnalytics. Check the database dropdown in the SSMS toolbar.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Claim)
BEGIN
    RAISERROR('STOP: dbo.Claim is empty. Run 02_seed_and_adjudicate.sql to completion first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM dw.FactClaimDenialDaily)
BEGIN
    RAISERROR('STOP: dw.FactClaimDenialDaily is empty. The backfill at the end of 02 did not run.', 16, 1);
    SET NOEXEC ON;
END
GO


/*==============================================================================
  1. TESTS

  Every assertion below is a statement about the pipeline that has to hold
  regardless of the seed. They are written as data, not as PRINT statements, so
  the result is one grid you can screenshot rather than a message tab you have
  to read.

  A test that fails does not stop the file. The point is to see all failures at
  once, not the first one.
==============================================================================*/

DROP TABLE IF EXISTS #Test;
CREATE TABLE #Test (
    TestNum   INT          NOT NULL,
    TestName  VARCHAR(96)  NOT NULL,
    Expected  VARCHAR(48)  NOT NULL,
    Actual    VARCHAR(48)  NOT NULL,
    Result    AS (CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END)
);

/*--- 1. The seed produced the row count the analysis assumes ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 1, 'Claim count', '2400', CAST(COUNT(*) AS VARCHAR(48)) FROM dbo.Claim;

/*--- 2. Adjudication reached every claim. A PENDING row means the claim fell
        out of the #Eval joins — a missing BenefitCategory row or a missing
        FeeSchedulePct_ config key for some provider type. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 2, 'Claims still PENDING after adjudication', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM   dbo.Claim WHERE AdjudicationStatus = 'PENDING';

/*--- 3. Status and denial table agree. Every DENIED claim has a denial row and
        every denial row belongs to a DENIED claim. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 3, 'DENIED claims without a ClaimDenial row', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM   dbo.Claim AS c
WHERE  c.AdjudicationStatus = 'DENIED'
  AND  NOT EXISTS (SELECT 1 FROM dbo.ClaimDenial AS d WHERE d.ClaimID = c.ClaimID);

INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 4, 'ClaimDenial rows on a non-DENIED claim', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM   dbo.ClaimDenial AS d
JOIN   dbo.Claim       AS c ON c.ClaimID = d.ClaimID
WHERE  c.AdjudicationStatus <> 'DENIED';

/*--- 5. One denial per claim. ClaimDenial holds the FIRST failing rule only;
        a second row would mean the rule sequence was not respected. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 5, 'Claims with more than one denial row', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM  (SELECT ClaimID FROM dbo.ClaimDenial
       GROUP BY ClaimID HAVING COUNT(*) > 1) AS x;

/*--- 6. The trace is complete: 7 rules evaluated for every claim. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 6, 'Claims without a full 7-rule trace', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM  (SELECT ClaimID FROM dbo.ClaimRuleResult
       GROUP BY ClaimID HAVING COUNT(*) <> 7) AS x;

/*--- 7. The rule sequence held. Every rule after the denying rule must be
        SKIP, and no rule before it may be FAIL. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 7, 'Rule-sequence violations in the trace', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM      dbo.ClaimRuleResult   AS rr
JOIN      dbo.AdjudicationRule  AS r  ON r.RuleID = rr.RuleID
JOIN      dbo.ClaimDenial       AS d  ON d.ClaimID = rr.ClaimID
JOIN      dbo.AdjudicationRule  AS dr ON dr.RuleID = d.RuleID
WHERE    (r.RuleSequence > dr.RuleSequence AND rr.RuleResult <> 'SKIP')
   OR    (r.RuleSequence < dr.RuleSequence AND rr.RuleResult =  'FAIL');

/*--- 8. Warehouse reconciles to source. Each claim maps to exactly one
        (LOB, ProviderType, RuleID, Verdict) group on its service date, so the
        sum of ClaimCount must equal the claim count. A mismatch is the
        fee-schedule fan-out this pipeline was rebuilt to prevent. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 8, 'dw claim count reconciles to dbo.Claim',
       CAST((SELECT COUNT(*) FROM dbo.Claim
             WHERE ServiceFromDate BETWEEN '2025-10-01' AND '2026-08-16') AS VARCHAR(48)),
       CAST(ISNULL((SELECT SUM(ClaimCount) FROM dw.FactClaimDenialDaily), 0) AS VARCHAR(48));

/*--- 9. Same reconciliation on money. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 9, 'dw billed amount reconciles to dbo.Claim',
       CAST((SELECT CAST(SUM(BilledAmount) AS DECIMAL(14,2)) FROM dbo.Claim
             WHERE ServiceFromDate BETWEEN '2025-10-01' AND '2026-08-16') AS VARCHAR(48)),
       CAST((SELECT CAST(SUM(BilledAmount) AS DECIMAL(14,2)) FROM dw.FactClaimDenialDaily) AS VARCHAR(48));

/*--- 10. Every service date present in the source has a partition. This is the
         check that catches a silently truncated backfill. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 10, 'Service dates with no partition log row', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM  (SELECT DISTINCT c.ServiceFromDate FROM dbo.Claim AS c) AS d
WHERE NOT EXISTS (SELECT 1 FROM ops.PartitionLog AS pl
                  WHERE pl.PartitionDate = d.ServiceFromDate
                    AND pl.LoadStatus IN ('SUCCESS','RELOADED'));

/*--- 11. No partition failed. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 11, 'Failed partitions', '0', CAST(COUNT(*) AS VARCHAR(48))
FROM   ops.PartitionLog WHERE LoadStatus = 'FAILED';

/*--- 12. The three seeded defects are present and are the ONLY three. If this
         fails, either a defect was corrected or a new one was introduced, and
         every exposure figure below moves. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 12, 'Configuration keys where loaded <> standard', '3',
       CAST(COUNT(*) AS VARCHAR(48))
FROM   dbo.PlanConfig WHERE LoadedValue <> StandardValue;

/*--- 13. R-070 is the pricing rule and it is a SOFT failure: it must never
         appear in ClaimDenial. A claim that pays the wrong amount still pays,
         which is exactly why it is invisible to denial reporting. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 13, 'R-070 pricing failures that denied a claim', '0',
       CAST(COUNT(*) AS VARCHAR(48))
FROM   dbo.ClaimDenial WHERE RuleID = 'R-070';

/*--- 14. Underpayment exists and is confined to LTSS. FeeSchedulePct_LTSS is
         the only pricing key where loaded and standard disagree, so no other
         provider type may show a paid-short claim. ---*/
INSERT INTO #Test (TestNum, TestName, Expected, Actual)
SELECT 14, 'Non-LTSS provider types paid below expected', '0',
       CAST(COUNT(DISTINCT p.ProviderType) AS VARCHAR(48))
FROM   dbo.Claim    AS c
JOIN   dbo.Provider AS p ON p.ProviderID = c.ProviderID
WHERE  c.AdjudicationStatus = 'PAID'
  AND  c.PaidAmount < c.ExpectedAllowedAmount
  AND  p.ProviderType <> 'LTSS';

SELECT   TestNum, TestName, Expected, Actual, Result
FROM     #Test
ORDER BY Result DESC, TestNum;   -- failures sort to the top

SELECT CONCAT(SUM(CASE WHEN Result='PASS' THEN 1 ELSE 0 END), ' of ',
              COUNT(*), ' tests passed') AS TestSummary
FROM   #Test;
GO


/*==============================================================================
  2. THE CONFIGURATION REGISTER

  The whole project in one grid. Three rows disagree; each one has a dollar
  figure attached in section 4.
==============================================================================*/
SELECT      pc.ConfigKey,
            pc.ConfigPath,
            pc.ConfigScope,
            pc.LoadedValue,
            pc.StandardValue,
            CASE WHEN pc.LoadedValue = pc.StandardValue
                 THEN 'MATCHES STANDARD' ELSE 'DEFECT' END AS ConfigStatus,
            r.RuleID,
            r.RuleName,
            pc.StandardSource
FROM        dbo.PlanConfig       AS pc
LEFT JOIN   dbo.AdjudicationRule AS r ON r.ConfigKey = pc.ConfigKey
ORDER BY    CASE WHEN pc.LoadedValue = pc.StandardValue THEN 1 ELSE 0 END,
            pc.ConfigKey;
GO


/*==============================================================================
  3. DENIAL MIX

  3a. Every denial by rule, split into the two categories that matter: denials
      the contract supports, and denials produced by a configuration value.
      The second column is the finding. The first is the control group.
==============================================================================*/
SELECT      f.RuleID,
            ISNULL(r.RuleName, 'No denial — claim paid')          AS RuleName,
            SUM(f.ClaimCount)                                     AS Claims,
            SUM(CASE WHEN f.Verdict='CORRECT DENIAL'
                     THEN f.ClaimCount ELSE 0 END)                AS CorrectDenials,
            SUM(CASE WHEN f.Verdict='CONFIGURATION DEFECT'
                     THEN f.ClaimCount ELSE 0 END)                AS DefectDriven,
            /* AmountAtRisk is expected-minus-paid on every row, including
               correct denials where the full allowed is legitimately unpaid.
               Filtering to CONFIGURATION DEFECT is what makes it exposure
               rather than just unpaid dollars. */
            CAST(SUM(CASE WHEN f.Verdict='CONFIGURATION DEFECT'
                          THEN f.AmountAtRisk ELSE 0 END) AS DECIMAL(14,2)) AS ExposureUSD
FROM        dw.FactClaimDenialDaily AS f
LEFT JOIN   dbo.AdjudicationRule    AS r ON r.RuleID = f.RuleID
GROUP BY    f.RuleID, r.RuleName
ORDER BY    ExposureUSD DESC;


/*--- 3b. The same split by line of business and provider type, which is how
         the dashboard is filtered. ---*/
SELECT      f.LOB,
            f.ProviderType,
            SUM(f.ClaimCount)                                     AS Claims,
            SUM(f.DeniedCount)                                    AS Denied,
            CAST(100.0 * SUM(f.DeniedCount)
                 / NULLIF(SUM(f.ClaimCount),0) AS DECIMAL(5,2))   AS DenialRatePct,
            CAST(SUM(CASE WHEN f.Verdict='CONFIGURATION DEFECT'
                          THEN f.AmountAtRisk ELSE 0 END) AS DECIMAL(14,2)) AS ExposureUSD
FROM        dw.FactClaimDenialDaily AS f
GROUP BY    f.LOB, f.ProviderType
HAVING      SUM(f.ClaimCount) > 0
ORDER BY    ExposureUSD DESC, f.LOB, f.ProviderType;


/*--- 3c. Verdict distribution. PENDING ADJUDICATION and UNPRICED should both
         be zero on a clean run; they exist so that a claim in either state is
         never silently counted as CLEAN. ---*/
SELECT      f.Verdict,
            SUM(f.ClaimCount)                                     AS Claims,
            CAST(100.0 * SUM(f.ClaimCount)
                 / SUM(SUM(f.ClaimCount)) OVER () AS DECIMAL(5,2)) AS PctOfClaims,
            CAST(SUM(f.AmountAtRisk) AS DECIMAL(14,2))            AS ExpectedMinusPaid
FROM        dw.FactClaimDenialDaily AS f
GROUP BY    f.Verdict
ORDER BY    Claims DESC;
GO


/*==============================================================================
  4. EXPOSURE PRICED PER DEFECT

  Each of the three blocks below isolates one configuration value and prices
  what it costs. These are the numbers that go on the one-page summary.
==============================================================================*/

/*--- 4a. DEFECT 1 — TimelyFilingDaysPar loaded at 90, contract says 95.

     The recoverable population is precise: participating providers, denied on
     R-060, filed within 95 days. Every one of these was filed on time under
     the agreement and denied by the configuration. ---*/
SELECT      'TimelyFilingDaysPar (90 vs 95)'                      AS Defect,
            COUNT(*)                                              AS RecoverableClaims,
            CAST(SUM(c.ExpectedAllowedAmount) AS DECIMAL(14,2))   AS ExposureUSD,
            MIN(DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate)) AS MinFilingLag,
            MAX(DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate)) AS MaxFilingLag
FROM        dbo.Claim       AS c
JOIN        dbo.ClaimDenial AS d ON d.ClaimID = c.ClaimID
JOIN        dbo.Provider    AS p ON p.ProviderID = c.ProviderID
WHERE       d.RuleID = 'R-060'
  AND       p.ParticipatingFlag = 1
  AND       DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate) <= 95;


/*--- 4b. DEFECT 2 — FeeSchedulePct_LTSS loaded at 80, required 100.

     This one never denies anything. The claims pay, they pay short, and the
     gap appears in no denial report. Units matter: an LTSS claim is 8 to 40
     units, so the per-claim shortfall is not small. ---*/
SELECT      'FeeSchedulePct_LTSS (80 vs 100)'                     AS Defect,
            COUNT(*)                                              AS UnderpaidClaims,
            SUM(c.Units)                                          AS TotalUnits,
            CAST(SUM(c.PaidAmount) AS DECIMAL(14,2))              AS PaidUSD,
            CAST(SUM(c.ExpectedAllowedAmount) AS DECIMAL(14,2))   AS ShouldHavePaidUSD,
            CAST(SUM(c.ExpectedAllowedAmount - c.PaidAmount) AS DECIMAL(14,2)) AS ExposureUSD
FROM        dbo.Claim    AS c
JOIN        dbo.Provider AS p ON p.ProviderID = c.ProviderID
WHERE       p.ProviderType = 'LTSS'
  AND       c.AdjudicationStatus = 'PAID'
  AND       c.PaidAmount < c.ExpectedAllowedAmount;


/*--- 4c. DEFECT 3 — AuthExempt_Transportation loaded at 0, should be 1.

     Transportation is delegated to MTM. A plan-side authorization is not
     supposed to exist, so the absence of one is correct provider behavior.
     The auth edit fires anyway because the exemption was never loaded. ---*/
SELECT      'AuthExempt_Transportation (0 vs 1)'                  AS Defect,
            COUNT(*)                                              AS RecoverableClaims,
            CAST(SUM(c.ExpectedAllowedAmount) AS DECIMAL(14,2))   AS ExposureUSD,
            MAX(bc.DelegatedVendor)                               AS DelegatedTo
FROM        dbo.Claim           AS c
JOIN        dbo.ClaimDenial     AS d  ON d.ClaimID = c.ClaimID
JOIN        dbo.Provider        AS p  ON p.ProviderID = c.ProviderID
JOIN        dbo.BenefitCategory AS bc ON bc.ProviderType = p.ProviderType
WHERE       d.RuleID = 'R-050'
  AND       p.ProviderType = 'Transportation';


/*--- 4d. All three on one line. ---*/
;WITH D1 AS (
    SELECT COUNT(*) AS Claims, SUM(c.ExpectedAllowedAmount) AS Exposure
    FROM   dbo.Claim AS c
    JOIN   dbo.ClaimDenial AS d ON d.ClaimID = c.ClaimID
    JOIN   dbo.Provider    AS p ON p.ProviderID = c.ProviderID
    WHERE  d.RuleID='R-060' AND p.ParticipatingFlag=1
      AND  DATEDIFF(DAY, c.ServiceFromDate, c.ReceivedDate) <= 95
), D2 AS (
    SELECT COUNT(*) AS Claims, SUM(c.ExpectedAllowedAmount - c.PaidAmount) AS Exposure
    FROM   dbo.Claim AS c
    JOIN   dbo.Provider AS p ON p.ProviderID = c.ProviderID
    WHERE  p.ProviderType='LTSS' AND c.AdjudicationStatus='PAID'
      AND  c.PaidAmount < c.ExpectedAllowedAmount
), D3 AS (
    SELECT COUNT(*) AS Claims, SUM(c.ExpectedAllowedAmount) AS Exposure
    FROM   dbo.Claim AS c
    JOIN   dbo.ClaimDenial AS d ON d.ClaimID = c.ClaimID
    JOIN   dbo.Provider    AS p ON p.ProviderID = c.ProviderID
    WHERE  d.RuleID='R-050' AND p.ProviderType='Transportation'
)
SELECT      x.Defect, x.Claims, CAST(x.Exposure AS DECIMAL(14,2)) AS ExposureUSD,
            CAST(100.0 * x.Exposure / SUM(x.Exposure) OVER () AS DECIMAL(5,2)) AS PctOfTotal
FROM  (
    SELECT 'Timely filing loaded at 90, contract 95'      AS Defect, Claims, Exposure FROM D1
    UNION ALL
    SELECT 'LTSS priced at 80 pct, contract 100 pct',              Claims, Exposure FROM D2
    UNION ALL
    SELECT 'Transportation auth exemption not loaded',             Claims, Exposure FROM D3
) AS x
ORDER BY    ExposureUSD DESC;
GO


/*==============================================================================
  5. PROVIDER EXPOSURE
==============================================================================*/

/*--- 5a. Ranked within provider type. RANK, not ROW_NUMBER: ties on exposure
         are real and collapsing them would misstate the queue. ---*/
;WITH ProviderExposure AS (
    SELECT      p.ProviderID,
                p.ProviderName,
                p.ProviderType,
                p.ParticipatingFlag,
                COUNT(*)                          AS DeniedClaims,
                SUM(c.ExpectedAllowedAmount)      AS Exposure
    FROM        dbo.Claim       AS c
    JOIN        dbo.ClaimDenial AS d ON d.ClaimID    = c.ClaimID
    JOIN        dbo.Provider    AS p ON p.ProviderID = c.ProviderID
    GROUP BY    p.ProviderID, p.ProviderName, p.ProviderType, p.ParticipatingFlag
)
SELECT      pe.ProviderType,
            RANK() OVER (PARTITION BY pe.ProviderType
                         ORDER BY pe.Exposure DESC)               AS RankInType,
            pe.ProviderID,
            pe.ProviderName,
            CASE pe.ParticipatingFlag WHEN 1 THEN 'PAR' ELSE 'NON-PAR' END AS Status,
            pe.DeniedClaims,
            CAST(pe.Exposure AS DECIMAL(14,2))                    AS ExposureUSD,
            CAST(100.0 * pe.Exposure
                 / SUM(pe.Exposure) OVER (PARTITION BY pe.ProviderType)
                 AS DECIMAL(5,2))                                 AS PctOfTypeExposure
FROM        ProviderExposure AS pe
WHERE       pe.Exposure > 0
ORDER BY    pe.ProviderType, RankInType;


/*--- 5b. Roll exposure up the provider hierarchy.

     A recursive CTE is required here rather than decorative: the number of
     levels between a billing NPI and its ultimate parent organization varies
     by contract, so the traversal cannot be written as a fixed set of joins.
     This seed is two levels deep; a real network file is not. ---*/
;WITH Hierarchy AS (
    SELECT      p.ProviderID,
                p.ParentProviderID,
                p.ProviderID   AS RootProviderID,
                p.ProviderName AS RootProviderName,
                0              AS DepthFromRoot
    FROM        dbo.Provider AS p
    WHERE       p.ParentProviderID IS NULL

    UNION ALL

    SELECT      c.ProviderID,
                c.ParentProviderID,
                h.RootProviderID,
                h.RootProviderName,
                h.DepthFromRoot + 1
    FROM        dbo.Provider AS c
    JOIN        Hierarchy    AS h ON h.ProviderID = c.ParentProviderID
)
SELECT      h.RootProviderID,
            h.RootProviderName,
            MAX(h.DepthFromRoot)                         AS HierarchyDepth,
            COUNT(DISTINCT h.ProviderID)                 AS BillingEntities,
            COUNT(*)                                     AS DeniedClaims,
            CAST(SUM(c.ExpectedAllowedAmount) AS DECIMAL(14,2)) AS RolledUpExposure
FROM        Hierarchy       AS h
JOIN        dbo.Claim       AS c ON c.ProviderID = h.ProviderID
JOIN        dbo.ClaimDenial AS d ON d.ClaimID    = c.ClaimID
GROUP BY    h.RootProviderID, h.RootProviderName
HAVING      SUM(c.ExpectedAllowedAmount) > 0
ORDER BY    RolledUpExposure DESC
OPTION (MAXRECURSION 25);
GO


/*==============================================================================
  6. PIPELINE HEALTH

  Answers the three questions a consumer needs before trusting anything above:
  is every day present, did any day load an implausible volume, is the reject
  rate normal.
==============================================================================*/
SELECT      PartitionDate, LoadStatus, RowsWritten, SourceRowsRead,
            RejectedRows, RejectRatePct, Rolling7DayAvgRows, LoadSeconds, HealthFlag
FROM        ops.vw_PipelineHealth
WHERE       HealthFlag <> 'OK'
ORDER BY    PartitionDate DESC;

/*--- Health summary. EMPTY PARTITION on the trailing dates is expected: the
     backfill runs to 2026-08-16 but the seed generates service dates only
     through 2026-07-27, so the last few weeks have no source claims. That is
     the view correctly reporting an absence, not a fault. ---*/
SELECT      HealthFlag, COUNT(*) AS PartitionCount,
            MIN(PartitionDate) AS FirstDate, MAX(PartitionDate) AS LastDate
FROM        ops.vw_PipelineHealth
GROUP BY    HealthFlag
ORDER BY    PartitionCount DESC;
GO


/*==============================================================================
  7. PROOF

  The claim this project makes is that these three values drive the outcomes.
  This section proves it: correct all three to their standard values,
  re-adjudicate, measure the difference, and roll the whole thing back.

  Nothing here is committed. The ROLLBACK restores dbo.PlanConfig, dbo.Claim,
  dbo.ClaimDenial, and dbo.ClaimRuleResult to the state they were in before
  the batch started.
==============================================================================*/

BEGIN TRANSACTION;

/* Snapshot the before state inside the transaction. A table variable is used
   deliberately — table variables are not rolled back, so the before figures
   survive to be compared against the after figures once the ROLLBACK lands. */
DECLARE @Before TABLE (
    Metric   VARCHAR(48),
    Claims   INT,
    AmountUSD DECIMAL(14,2)
);

INSERT INTO @Before (Metric, Claims, AmountUSD)
SELECT 'Denied claims',
       COUNT(*), CAST(SUM(c.ExpectedAllowedAmount) AS DECIMAL(14,2))
FROM   dbo.Claim AS c WHERE c.AdjudicationStatus = 'DENIED';

INSERT INTO @Before (Metric, Claims, AmountUSD)
SELECT 'Paid claims', COUNT(*), CAST(SUM(c.PaidAmount) AS DECIMAL(14,2))
FROM   dbo.Claim AS c WHERE c.AdjudicationStatus = 'PAID';

/*--- Correct the configuration. One statement. This is the remediation. ---*/
UPDATE dbo.PlanConfig
SET    LoadedValue   = StandardValue,
       LastChangedBy = 'REMEDIATION.PROOF'
WHERE  LoadedValue <> StandardValue;

/*--- Re-run the engine against the corrected values. ---*/
EXEC dbo.usp_AdjudicateClaims;

DECLARE @After TABLE (
    Metric   VARCHAR(48),
    Claims   INT,
    AmountUSD DECIMAL(14,2)
);

INSERT INTO @After (Metric, Claims, AmountUSD)
SELECT 'Denied claims',
       COUNT(*), CAST(ISNULL(SUM(c.ExpectedAllowedAmount),0) AS DECIMAL(14,2))
FROM   dbo.Claim AS c WHERE c.AdjudicationStatus = 'DENIED';

INSERT INTO @After (Metric, Claims, AmountUSD)
SELECT 'Paid claims', COUNT(*), CAST(SUM(c.PaidAmount) AS DECIMAL(14,2))
FROM   dbo.Claim AS c WHERE c.AdjudicationStatus = 'PAID';

/*--- Undo everything. ---*/
ROLLBACK TRANSACTION;

/*--- Report the delta. Runs after the rollback; the table variables survived. ---*/
SELECT      b.Metric,
            b.Claims    AS ClaimsBefore,
            a.Claims    AS ClaimsAfter,
            a.Claims - b.Claims       AS ClaimsDelta,
            b.AmountUSD AS AmountBefore,
            a.AmountUSD AS AmountAfter,
            CAST(a.AmountUSD - b.AmountUSD AS DECIMAL(14,2)) AS AmountDelta
FROM        @Before AS b
JOIN        @After  AS a ON a.Metric = b.Metric
ORDER BY    b.Metric;

/*--- Confirm the rollback landed. Both should read 3 and DEFECT. ---*/
SELECT      COUNT(*) AS ConfigDefectsStillPresent
FROM        dbo.PlanConfig WHERE LoadedValue <> StandardValue;

SELECT      COUNT(*) AS DeniedClaimsRestored
FROM        dbo.Claim WHERE AdjudicationStatus = 'DENIED';
GO

PRINT '03 complete. Next: run 04_schedule_agent_job.sql';
GO

SET NOEXEC OFF;
GO
