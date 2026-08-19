# Claims Denial & Configuration Workbench

A SQL Server pipeline that adjudicates synthetic healthcare claims and separates
denials the contract supports from denials caused by a wrong configuration value.

The premise: most claim denials are correct. A small number are not, and those
are invisible in denial reporting because the engine did exactly what it was
configured to do. This project finds them and puts a dollar figure on each one.

---

## The finding

Three configuration values disagree with the contract that governs them.

| Parameter | Loaded | Required | Effect |
|---|---|---|---|
| `TimelyFilingDaysPar` | 90 days | 95 days | Claims filed on time under the agreement deny as late |
| `FeeSchedulePct_LTSS` | 80% | 100% | LTSS claims pay, and pay short — never appears in denial reporting |
| `AuthExempt_Transportation` | not exempt | exempt | Transportation is delegated to the vendor; the plan-side auth edit fires anyway |

Exposure across 2,400 claims:

| Defect | Claims | Exposure | % of total |
|---|---|---|---|
| Timely filing loaded at 90 days against a 95-day contract | 51 | $39,571.50 | 48.0% |
| LTSS priced at 80% against a contracted 100% | 207 | $33,369.65 | 40.5% |
| Transportation auth exemption never loaded | 195 | $9,459.96 | 11.5% |
| **Total** | **453** | **$82,401.11** | **100%** |

> Run section 4d of `03_analysis_and_tests.sql` for all three on one line.

The second defect is the interesting one. It never denies a claim, so it appears
in no denial report. The claim pays; it just pays 20% short on every unit, and
an LTSS claim runs 8–40 units. That is why the pricing check exists as its own
rule rather than as a denial reason.

---

## How it works

```
stg.ClaimImport ──► stg.usp_CleanseAndLoadClaims ──► dbo.Claim
                             │                          │
                             ▼                          ▼
                    ops.ClaimReject          dbo.usp_AdjudicateClaims
                                                        │
                                              ┌─────────┴─────────┐
                                              ▼                   ▼
                                      dbo.ClaimDenial    dbo.ClaimRuleResult
                                              │           (full 7-rule trace)
                                              ▼
                                  dw.usp_LoadClaimDenialDaily
                                              │
                                              ▼
                                  dw.FactClaimDenialDaily ──► ops.vw_PipelineHealth
```

**Adjudication.** Seven rules in sequence; the first failure denies and later
rules never run. The engine is set-based — every rule is evaluated for every
claim into a work table, then one ordered `CASE` picks the first failure. That
preserves the full chain for the audit trace while keeping the whole thing a
single pass rather than a cursor.

**Configuration is data.** The engine reads `dbo.PlanConfig` at runtime. Change
a value and re-run the procedure; the outcomes change. Section 7 of `03` does
exactly this inside a transaction and rolls it back.

**Warehouse grain.** `ServiceDate + LOB + ProviderType + RuleID + Verdict`.
Member, procedure code, and provider ID are deliberately excluded — they push the
table back toward claim-level row counts and answer no question the dashboard
asks. 2,400 claims aggregate to ~2,187 daily rows across 300 partitions.

**Incremental and idempotent.** One service date per transaction. A failure on
day 40 of a 300-day backfill leaves days 1–39 committed and restartable. Re-running
a date deletes and rewrites only that date.

---

## Verdicts

Every claim lands in exactly one bucket:

| Verdict | Meaning |
|---|---|
| `CLEAN` | Paid at or above the contracted allowed amount |
| `CORRECT DENIAL` | Denied on a rule whose configuration matches the contract |
| `CONFIGURATION DEFECT` | Denied on a wrong value, or paid short |
| `PENDING ADJUDICATION` | Not yet adjudicated — unknown, not clean |
| `UNPRICED` | No fee schedule row or config key — unknown, not clean |

The last two exist because their absence was a bug. A `NULL` paid amount
compared against a `NULL` expected amount collapsed through `ISNULL(...,0)` to
`0 >= 0` and reported as `CLEAN`.

---

## Running it

Requires SQL Server 2016+ at compatibility level 130 or higher.

| File | Purpose |
|---|---|
| `01_schema.sql` | Database, schemas, tables, cleansing, warehouse, pipeline health view |
| `02_seed_and_adjudicate.sql` | 900 members, 300 providers, 2,400 claims; adjudication engine; backfill |
| `03_analysis_and_tests.sql` | 14 assertions, then the analysis |
| `04_schedule_agent_job.sql` | Nightly Agent job with a health gate (optional; needs non-Express) |

Run in order. `00_build_all.sql` is 01 and 02 combined into a single file if you
prefer one execution.

Execute the whole file with nothing selected. Running a selection skips the
`CREATE PROCEDURE` batches and the later `EXEC` calls then fail with
`Could not find stored procedure`.

---

## Tests

`03` opens with 14 assertions rendered as one grid, failures sorted to the top.

Reconciliation (8 and 9) is the important pair — claim counts and billed dollars
must match to the cent between `dbo.Claim` and `dw.FactClaimDenialDaily`. A
duplicate row anywhere in the aggregation inflates the warehouse and nothing
else in the project notices.

Test 7 checks that the rule sequence held across all 16,800 trace rows: every
rule after a denial is `SKIP`, no rule before it is `FAIL`.

Tests 13 and 14 state the pricing finding as an assertion — R-070 never denied a
claim, and only LTSS was paid short.

---

## Design notes

Decisions that are load-bearing and not obvious:

**Deterministic generation, inlined.** Every synthetic value derives from
`ABS(CHECKSUM(CAST(seed AS BIGINT) * 2654435761 + CAST(salt AS BIGINT) * 40503)) % range`.
This started as a scalar UDF, which was invoked ~30,000 times and took twelve
minutes. Below compatibility level 150 SQL Server cannot inline a scalar UDF, so
each call was a separate execution context. Written inline, the optimizer folds
the constants and evaluates it as part of the set operation. The `CAST`s are
load-bearing: `CHECKSUM` is type-sensitive, and dropping them changes every
generated value.

**`CROSS APPLY TOP 1` on the fee schedule, not `JOIN`.** A join on
`ProcedureCode` alone returns one row per effective-dated version. With one row
per code that looks fine; add a 2026 schedule and it fans out, producing
duplicate `ClaimID` values and a failed insert. The same pattern is used in the
seed, the engine, and the warehouse load so all three agree.

**Rejects carry a service date.** Attributing a reject to the timestamp it was
written lands every reject on the day the load ran, which makes the reject rate
on every historical partition zero.

**The health view builds a contiguous calendar.** Deriving the spine from
`SELECT DISTINCT ServiceFromDate` means a day with no source data produces no
row — the single most important failure is invisible in the view whose job is to
catch it. It also makes `ROWS BETWEEN 7 PRECEDING` cover seven *present* dates
rather than seven calendar days.

---

## Not included

Synthetic data only. No PHI, no production extract, no real contract terms. The
fee schedule rates are plausible but invented, and the configuration defects are
seeded deliberately rather than discovered.
