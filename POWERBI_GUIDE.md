# Power BI build

Two pages: **Exposure** (the finding) and **Pipeline Health** (whether to trust
page one). Build in that order.

Everything below assumes `00` and `03` ran clean.

---

## 1. Connect

**Home → Get Data → SQL Server**

| Field | Value |
|---|---|
| Server | `localhost` (or `localhost\SQLEXPRESS`, or your instance name) |
| Database | `ClaimsAnalytics` |
| Data Connectivity mode | **Import** |

Import, not DirectQuery. The warehouse is ~2,187 rows — it fits in memory
several thousand times over, and Import gives you the full DAX surface. Choosing
DirectQuery for a table this size is a red flag if anyone technical looks at it.

If prompted for credentials, use **Windows** authentication.

Select these tables:

- `dw.FactClaimDenialDaily` — the fact
- `dbo.PlanConfig` — the configuration register
- `dbo.AdjudicationRule` — rule names
- `dbo.Provider` — only if you want provider-level drill; skip for the first pass

Do **not** import `dbo.Claim`, `dbo.ClaimRuleResult`, or `dbo.ClaimModifier`.
Claim detail belongs behind a drill-through, not in the model. Importing it
defeats the point of having built an aggregate.

---

## 2. Add a date table

Power BI needs a proper date dimension for any time intelligence.

**Modeling → New table:**

```dax
DimDate =
VAR MinDate = MIN ( FactClaimDenialDaily[ServiceDate] )
VAR MaxDate = MAX ( FactClaimDenialDaily[ServiceDate] )
RETURN
ADDCOLUMNS (
    CALENDAR ( MinDate, MaxDate ),
    "Year",        YEAR ( [Date] ),
    "MonthNum",    MONTH ( [Date] ),
    "MonthName",   FORMAT ( [Date], "MMM yyyy" ),
    "QuarterName", "Q" & FORMAT ( [Date], "Q yyyy" ),
    "WeekStart",   [Date] - WEEKDAY ( [Date], 3 )
)
```

Then:
- **Modeling → Mark as date table** → `Date`
- Sort `MonthName` by `MonthNum` (select the column → **Sort by column**)

---

## 3. Relationships

**Model view.** Create these, all single-direction, one-to-many:

| From | To | Cardinality |
|---|---|---|
| `DimDate[Date]` | `FactClaimDenialDaily[ServiceDate]` | 1 → * |
| `AdjudicationRule[RuleID]` | `FactClaimDenialDaily[RuleID]` | 1 → * |

**One catch.** The fact uses `R-000` for claims with no denial, and that value
doesn't exist in `dbo.AdjudicationRule`. Those rows land in a blank row on the
rule dimension. Either accept it, or add the row in Power Query — **Transform
Data → AdjudicationRule → Enter Data** is fiddly; easier to fix at the source:

```sql
INSERT INTO dbo.AdjudicationRule (RuleID, RuleName, RuleSequence, ConfigKey)
VALUES ('R-000', 'No denial — claim paid', 0, NULL);
```

Then refresh. This is harmless to the rest of the project — nothing joins on
`RuleSequence = 0`.

`PlanConfig` stays **unrelated**. It's a reference table you display directly,
not something you filter the fact by.

`LOB`, `ProviderType`, and `Verdict` are degenerate dimensions — columns on the
fact itself. Slice on them directly. Don't build lookup tables for three,
eight, and five distinct values.

---

## 4. Measures

New measure (right-click the fact table → **New measure**). Create these in
order; the later ones reference the earlier ones.

```dax
Total Claims = SUM ( FactClaimDenialDaily[ClaimCount] )
```

```dax
Denied Claims = SUM ( FactClaimDenialDaily[DeniedCount] )
```

```dax
Denial Rate =
DIVIDE ( [Denied Claims], [Total Claims] )
```

```dax
Billed = SUM ( FactClaimDenialDaily[BilledAmount] )
```

```dax
Paid = SUM ( FactClaimDenialDaily[PaidAmount] )
```

```dax
Expected Allowed = SUM ( FactClaimDenialDaily[ExpectedAllowedAmount] )
```

**The important one:**

```dax
Exposure =
CALCULATE (
    SUM ( FactClaimDenialDaily[AmountAtRisk] ),
    FactClaimDenialDaily[Verdict] = "CONFIGURATION DEFECT"
)
```

`AmountAtRisk` is expected-minus-paid on **every** row, including correct
denials where the full allowed amount is legitimately unpaid. Summing it
unfiltered overstates exposure by a large multiple. The `CALCULATE` filter is
what makes it mean what the name suggests. This is the single easiest way to
get an embarrassing number on a slide.

```dax
Correct Denials =
CALCULATE ( [Denied Claims], FactClaimDenialDaily[Verdict] = "CORRECT DENIAL" )
```

```dax
Defect Driven Denials =
CALCULATE ( [Denied Claims], FactClaimDenialDaily[Verdict] = "CONFIGURATION DEFECT" )
```

```dax
Pct Denials From Defects =
DIVIDE ( [Defect Driven Denials], [Denied Claims] )
```

Format as you go: currency measures to `$ #,##0`, rates to `0.0%`. Doing it now
saves reformatting every visual later.

---

## 5. Page one — Exposure

**Four cards across the top:**

| Card | Measure |
|---|---|
| Total Claims | `[Total Claims]` |
| Denial Rate | `[Denial Rate]` |
| Exposure | `[Exposure]` |
| % Denials From Defects | `[Pct Denials From Defects]` |

**Table — the configuration register.** From `PlanConfig`:
`ConfigKey`, `ConfigPath`, `LoadedValue`, `StandardValue`, `StandardSource`.

Conditional formatting on `LoadedValue`: **Format → Cell elements → Background
color → Format by: Rules**, where value ≠ `StandardValue`. Rules-based
formatting can't reference another column directly, so add a Power Query column
instead:

```
if [LoadedValue] <> [StandardValue] then "DEFECT" else "OK"
```

Name it `ConfigStatus`, then format on that.

**Stacked bar — denial mix by rule.** Axis `AdjudicationRule[RuleName]`, values
`[Denied Claims]`, legend `Verdict`. This is the visual that carries the whole
story: correct denials and defect-driven denials side by side per rule.

**Bar — exposure by provider type.** Axis `ProviderType`, value `[Exposure]`.
LTSS will dominate.

**Line — exposure over time.** Axis `DimDate[MonthName]`, value `[Exposure]`.

**Slicers:** `LOB`, `ProviderType`, `DimDate[MonthName]`.

---

## 6. Page two — Pipeline Health

Import `ops.vw_PipelineHealth` as its own table. Leave it unrelated to the fact;
it's a monitoring view with its own grain.

- **Card:** count of rows where `HealthFlag <> "OK"`
- **Table:** `PartitionDate`, `LoadStatus`, `RowsWritten`, `Rolling7DayAvgRows`,
  `RejectRatePct`, `HealthFlag` — filtered to `HealthFlag <> "OK"`
- **Line:** `RowsWritten` and `Rolling7DayAvgRows` over `PartitionDate`, so the
  volume-drop threshold is visible rather than asserted

Expect the trailing dates to be clean now — the backfill range is derived from
the data rather than hardcoded, so there are no empty partitions past the last
claim.

Having this page is worth more than it looks. Anyone who has been burned by a
dashboard that was confidently wrong will recognize what it's for.

---

## 7. Before you show it

- **View → Page view → Fit to page**, and check it at 1920×1080.
- Rename pages. "Page 1" on a portfolio file is a tell.
- Turn off the visual header icons for a cleaner look:
  **File → Options → Current file → Report settings**.
- Save as `.pbix` next to the SQL files.

If you want it to match the rest of your materials, set a theme with navy
`#0D2B55` and gold `#C9A227`: **View → Themes → Customize current theme**.

---

## Refreshing

The `.pbix` holds an imported snapshot. After re-running `00`, hit **Refresh**
in Power BI to pick up new numbers.

To demo the config correction live: run the `UPDATE dbo.PlanConfig` from §7 of
`03` **without** the rollback, re-run `EXEC dbo.usp_AdjudicateClaims` and the
backfill with `@Reload = 1`, then refresh. Exposure drops to near zero on the
corrected rules. Restore afterward by re-running `00`.

That's a strong demo, but it takes a couple of minutes to run. Rehearse it or
have a screenshot of the after state ready.
