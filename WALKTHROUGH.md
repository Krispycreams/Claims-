# Ten-minute walkthrough

Structure: the problem, one query that proves it, the engine, the safety net.
Not a tour of the schema.

Have `03_analysis_and_tests.sql` open with sections 2, 4d, and 7 ready to run.

---

## 0:00 — Open with the problem, not the project

> "Most claim denials are correct. The ones that aren't are hard to find,
> because the engine did exactly what it was configured to do — so nothing looks
> broken. I built something that separates those two populations and prices the
> difference."

Do not start with "I built a SQL Server database with four schemas." Lead with
the question it answers.

---

## 0:30 — The configuration register (run §2)

One grid, three rows flagged `DEFECT`.

> "This is the whole project in one table. `LoadedValue` is what the engine
> actually uses. `StandardValue` is what the contract or the state requires.
> Any row where they disagree is live financial exposure. Three of them do."

Walk the three:

- **Timely filing at 90 against a 95-day agreement.** Claims filed on day 91
  through 95 were on time and denied anyway.
- **LTSS priced at 80% against a contract that says 100%.** This one never
  denies. The claim pays, 20% short, on every unit — and LTSS runs 8 to 40 units.
- **Transportation auth exemption never loaded.** The benefit is delegated to
  MTM, so a plan-side auth is not supposed to exist. Its absence is correct
  provider behavior. The edit fires anyway.

---

## 2:30 — The number (run §4d)

Three rows, exposure and percent of total.

> "That's what those three values cost across 2,400 claims."

Then the point that matters:

> "The LTSS one is the one I'd have missed. It doesn't produce a denial, so it
> appears in no denial report. That's why the pricing check exists as its own
> rule instead of as a denial reason — it's a soft failure, and soft failures
> are the ones that survive."

Stop talking here. Let them ask.

---

## 4:00 — How the engine works

Only if asked, or if the conversation is going technical.

> "Seven rules in sequence, first failure denies, later rules never run. It's
> set-based — every rule is evaluated for every claim into a work table, then a
> single ordered CASE picks the first failure. That gets me the real behavior
> and the full audit trace in one pass instead of a cursor."

Show one claim's trace if they want detail:

```sql
SELECT TOP 1 c.ClaimID FROM dbo.Claim c
JOIN dbo.ClaimDenial d ON d.ClaimID = c.ClaimID WHERE d.RuleID = 'R-060';

SELECT r.RuleSequence, rr.RuleID, rr.RuleResult, rr.Evidence
FROM   dbo.ClaimRuleResult AS rr
JOIN   dbo.AdjudicationRule AS r ON r.RuleID = rr.RuleID
WHERE  rr.ClaimID = '<paste>'
ORDER BY r.RuleSequence;
```

The `Evidence` column on R-060 reads the filing lag against both the loaded
limit and the contractual limit. That's the audit trail — it says why, in terms
someone outside IT can read.

---

## 6:00 — Prove the causation (run §7)

> "The claim I'm making is that those three values drive the outcomes. So here's
> the test: correct all three, re-run the engine, measure the delta, roll it
> back. Nothing's committed."

Before/after on denied claims and paid dollars.

> "That's not a projection. That's the same engine on the same claims with the
> configuration corrected."

---

## 8:00 — The safety net

> "None of that means anything if the pipeline is quietly wrong, so there are
> 14 assertions."

Run the test grid. Point at two:

- **Test 9** — billed dollars reconcile to the cent between source and
  warehouse. "That's the one that catches a duplicate in the aggregation. A
  fan-out inflates the dashboard and nothing else notices."
- **Test 7** — zero rule-sequence violations across 16,800 trace rows. "Every
  rule after a denial is SKIP. That's the first-failure-denies contract holding."

---

## 9:00 — Close on the operational piece

> "It loads incrementally, one service date per transaction, so a failure on day
> 40 of a backfill leaves the first 39 committed and restartable. There's a
> health view that flags missing partitions, volume swings, and reject rate, and
> an Agent job that fails loudly if any of those trip."

---

## Questions you should expect

**"Is this real data?"**
No. Synthetic, generated deterministically so it rebuilds identically. No PHI,
no production extract. Say this early and plainly — do not let them wonder.

**"How long did this take?"**
Answer honestly. Then: "the adjudication engine was the fast part. What took
time was making the warehouse layer correct — the reconciliation tests kept
failing and each one was a real bug."

**"What would you do differently?"**
Have a real answer. Options:
- The `AmountAtRisk` column name is misleading — it's expected-minus-paid on
  every row including correct denials, where the full allowed is legitimately
  unpaid. It's only exposure when filtered to `CONFIGURATION DEFECT`. Should be
  named for what it computes.
- No slowly-changing dimension handling. If a provider changes type, history
  restates.
- Duplicate detection is same member/provider/code/date. Real duplicate logic
  considers billed amount and units.

**"What was the hardest bug?"**
A procedure that silently failed to compile. The body had
`PRINT 'x' + CAST((SELECT COUNT(*) FROM t) AS VARCHAR)` — a subquery in a scalar
context, Msg 1046. `CREATE PROCEDURE` failed, so at runtime it looked like the
procedure had never been in the script at all, and the error pointed at the
`EXEC` rather than the definition. Cost me a lot of time chasing the wrong thing.

That's a good answer. It's specific, it's a real failure mode, and it shows you
read error messages rather than guessing.

---

## What not to do

- Don't walk the schema table by table.
- Don't apologize for it being synthetic. It's the right choice for a portfolio
  project and saying so confidently is better than hedging.
- Don't oversell. It's a well-built demonstration, not a production system, and
  claiming otherwise invites a question you can't answer.
- Don't read the SQL aloud. Show output, describe intent.
