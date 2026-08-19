/*==============================================================================
  04 — SCHEDULE THE NIGHTLY LOAD
  SQL Server 2016+ — Standard, Developer, or Enterprise edition

  Carlos M. Puente

  Run order:  01 -> 02 -> 03 -> 04_schedule_agent_job.sql

  Creates a SQL Agent job that runs the incremental warehouse load every
  morning and raises an alert if the pipeline health view reports a problem.

  Contents
    0.  Guards (edition, Agent running, prerequisites)
    1.  Operator
    2.  Job, category, and steps
    3.  Schedule
    4.  Verification

  This file is idempotent. Re-running it drops and recreates the job.

  NOTE ON EXPRESS EDITION
  SQL Server Express has no SQL Agent. The guard in 0a stops cleanly rather
  than failing on a missing msdb procedure. If you are on Express, section 5
  at the bottom gives the Windows Task Scheduler equivalent.
==============================================================================*/

SET NOEXEC OFF;
GO

USE master;
GO

/*------------------------------------------------------------------------------
  0a. EDITION GUARD

  sp_add_job lives in msdb and exists on Express, but the Agent service that
  would run the job does not. The job would be created and never fire — a
  silent failure that looks like a data problem weeks later.
------------------------------------------------------------------------------*/
IF CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) LIKE '%Express%'
BEGIN
    RAISERROR('STOP: SQL Server Express has no SQL Agent. This job cannot run. See section 5 at the bottom of this file for the Task Scheduler alternative.', 16, 1);
    SET NOEXEC ON;
END
GO

/*------------------------------------------------------------------------------
  0b. AGENT SERVICE GUARD

  Creating a job against a stopped Agent succeeds and then never runs. Check
  that the service is actually up.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.dm_server_services
               WHERE servicename LIKE 'SQL Server Agent%'
                 AND status_desc = 'Running')
BEGIN
    RAISERROR('WARNING: the SQL Server Agent service is not reporting as Running. The job will be created but will not fire until the service is started (SQL Server Configuration Manager -> SQL Server Agent -> Start).', 10, 1) WITH NOWAIT;
END
GO

/*------------------------------------------------------------------------------
  0c. PREREQUISITE GUARD
------------------------------------------------------------------------------*/
IF DB_ID('ClaimsAnalytics') IS NULL
BEGIN
    RAISERROR('STOP: ClaimsAnalytics does not exist. Run 01_schema.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('ClaimsAnalytics.dw.usp_LoadClaimDenialDaily') IS NULL
OR OBJECT_ID('ClaimsAnalytics.ops.vw_PipelineHealth')       IS NULL
BEGIN
    RAISERROR('STOP: dw.usp_LoadClaimDenialDaily or ops.vw_PipelineHealth is missing. Run 01_schema.sql to completion first.', 16, 1);
    SET NOEXEC ON;
END
GO


USE msdb;
GO

DECLARE @JobName SYSNAME = N'ClaimsAnalytics - Nightly Denial Load';

/*==============================================================================
  1. TEAR DOWN AND OPERATOR
==============================================================================*/

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;
    PRINT 'Dropped existing job.';
END

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'ClaimsAnalytics Owner')
    EXEC msdb.dbo.sp_add_operator
         @name         = N'ClaimsAnalytics Owner',
         @enabled      = 1,
         @email_address= N'carlos.puente@example.com';   -- << set a real address

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories
               WHERE name = N'ClaimsAnalytics' AND category_class = 1)
    EXEC msdb.dbo.sp_add_category
         @class = N'JOB', @type = N'LOCAL', @name = N'ClaimsAnalytics';


/*==============================================================================
  2. JOB AND STEPS
==============================================================================*/

EXEC msdb.dbo.sp_add_job
     @job_name              = @JobName,
     @enabled               = 1,
     @category_name         = N'ClaimsAnalytics',
     @description           = N'Loads yesterday''s service-date partition into dw.FactClaimDenialDaily, then checks pipeline health. Idempotent: the load procedure skips a date already logged SUCCESS unless @Reload = 1.',
     /* Event log only. @notify_level_email = 2 requires a configured Database
        Mail profile; without one the job still runs but every execution logs a
        notification failure, which buries the real errors. Turn it on once
        Database Mail is set up:
            EXEC msdb.dbo.sp_update_job
                 @job_name = N'ClaimsAnalytics - Nightly Denial Load',
                 @notify_level_email = 2,
                 @notify_email_operator_name = N'ClaimsAnalytics Owner'; */
     @notify_level_eventlog = 2,     -- on failure
     @notify_level_email    = 0;
     /* No @owner_login_name. It defaults to the current login. Hardcoding 'sa'
        fails outright on any instance where that account is renamed or
        disabled, which is most of them. */

EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName;   -- (LOCAL)


/*--- STEP 1 — catch up any missing partitions, then load yesterday.

     The backfill call is the safety net. If the Agent was down for three days,
     a step that only loads yesterday leaves a permanent hole; the backfill
     skips dates already logged SUCCESS, so on a normal night it is a cheap
     no-op and on a recovery night it closes the gap.

     Seven days is the look-back. Wider costs nothing on a healthy pipeline
     because every date short-circuits on the PartitionLog check. ---*/
EXEC msdb.dbo.sp_add_jobstep
     @job_name        = @JobName,
     @step_name       = N'01 Load partitions',
     @step_id         = 1,
     @subsystem       = N'TSQL',
     @database_name   = N'ClaimsAnalytics',
     @retry_attempts  = 2,
     @retry_interval  = 5,           -- minutes
     @on_success_action = 3,         -- go to next step
     @on_fail_action    = 2,         -- quit reporting failure
     @command = N'
SET NOCOUNT ON;

DECLARE @Yesterday DATE = CAST(DATEADD(DAY, -1, SYSDATETIME()) AS DATE);
DECLARE @LookBack  DATE = DATEADD(DAY, -7, @Yesterday);

PRINT CONCAT(''Loading '', CONVERT(VARCHAR(10), @LookBack, 23),
             '' through '', CONVERT(VARCHAR(10), @Yesterday, 23));

EXEC dw.usp_BackfillClaimDenialDaily
     @StartDate = @LookBack,
     @EndDate   = @Yesterday,
     @Reload    = 0;
';

/*--- STEP 2 — health gate.

     The load succeeding is not the same as the data being right. A partition
     that loads zero rows because the source file never arrived is a SUCCESS in
     the PartitionLog and a failure in reality. This step reads the health view
     and fails the job so the notification actually fires.

     MISSING PARTITION and EMPTY PARTITION on dates with no source claims are
     expected in a demo database, so the gate only looks at the last 7 days and
     only at conditions that indicate a real fault. ---*/
EXEC msdb.dbo.sp_add_jobstep
     @job_name        = @JobName,
     @step_name       = N'02 Health gate',
     @step_id         = 2,
     @subsystem       = N'TSQL',
     @database_name   = N'ClaimsAnalytics',
     @retry_attempts  = 0,
     @on_success_action = 1,         -- quit reporting success
     @on_fail_action    = 2,         -- quit reporting failure
     @command = N'
SET NOCOUNT ON;

DECLARE @Since DATE = DATEADD(DAY, -7, CAST(SYSDATETIME() AS DATE));
DECLARE @Bad   INT;
DECLARE @Detail VARCHAR(1000) = '''';

SELECT @Bad = COUNT(*)
FROM   ops.vw_PipelineHealth
WHERE  PartitionDate >= @Since
  AND  HealthFlag IN (''LOAD FAILED'',
                      ''VOLUME DROP OVER 50 PCT'',
                      ''VOLUME SPIKE OVER 100 PCT'',
                      ''REJECT RATE OVER THRESHOLD'');

IF @Bad > 0
BEGIN
    SELECT @Detail = @Detail + CONVERT(VARCHAR(10), PartitionDate, 23)
                             + '' '' + HealthFlag + ''; ''
    FROM   ops.vw_PipelineHealth
    WHERE  PartitionDate >= @Since
      AND  HealthFlag IN (''LOAD FAILED'',
                          ''VOLUME DROP OVER 50 PCT'',
                          ''VOLUME SPIKE OVER 100 PCT'',
                          ''REJECT RATE OVER THRESHOLD'')
    ORDER BY PartitionDate;

    RAISERROR(''Pipeline health check failed on %d partition(s): %s'', 16, 1, @Bad, @Detail);
END
ELSE
    PRINT ''Pipeline health OK for the last 7 days.'';
';


/*==============================================================================
  3. SCHEDULE

  05:00 daily. Late enough that the overnight 837 load has finished, early
  enough that the dashboard is current before business hours.
==============================================================================*/

EXEC msdb.dbo.sp_add_jobschedule
     @job_name        = @JobName,
     @name            = N'Daily 0500',
     @enabled         = 1,
     @freq_type       = 4,           -- daily
     @freq_interval   = 1,           -- every 1 day
     @active_start_time = 050000;    -- HHMMSS

PRINT 'Job created: ' + @JobName;
GO


/*==============================================================================
  4. VERIFICATION
==============================================================================*/

SELECT      j.name                AS JobName,
            j.enabled             AS JobEnabled,
            s.name                AS ScheduleName,
            STUFF(STUFF(RIGHT('000000' + CAST(s.active_start_time AS VARCHAR(6)), 6),
                        5,0,':'), 3,0,':')          AS RunsAt,
            s.enabled             AS ScheduleEnabled
FROM        msdb.dbo.sysjobs           AS j
LEFT JOIN   msdb.dbo.sysjobschedules   AS js ON js.job_id = j.job_id
LEFT JOIN   msdb.dbo.sysschedules      AS s  ON s.schedule_id = js.schedule_id
WHERE       j.name = N'ClaimsAnalytics - Nightly Denial Load';

SELECT      step_id, step_name, subsystem, database_name,
            retry_attempts, on_success_action, on_fail_action
FROM        msdb.dbo.sysjobsteps
WHERE       job_id = (SELECT job_id FROM msdb.dbo.sysjobs
                      WHERE name = N'ClaimsAnalytics - Nightly Denial Load')
ORDER BY    step_id;
GO

/*--- Run it once now to confirm both steps work. Comment out if you would
     rather wait for the schedule.

     sp_start_job returns as soon as the job is queued, not when it finishes,
     so the history query below may show the previous run. Give it a few
     seconds and re-run the history query. ---*/
EXEC msdb.dbo.sp_start_job @job_name = N'ClaimsAnalytics - Nightly Denial Load';
WAITFOR DELAY '00:00:10';
GO

/*--- History. run_status: 0 failed, 1 succeeded, 2 retry, 3 cancelled, 4 running ---*/
SELECT   TOP (20)
         h.step_id,
         CASE WHEN h.step_id = 0 THEN '(job outcome)' ELSE h.step_name END AS StepName,
         CASE h.run_status WHEN 0 THEN 'FAILED' WHEN 1 THEN 'SUCCEEDED'
                           WHEN 2 THEN 'RETRY'  WHEN 3 THEN 'CANCELLED'
                           ELSE 'RUNNING' END                              AS RunStatus,
         msdb.dbo.agent_datetime(h.run_date, h.run_time)                   AS RunAt,
         h.run_duration                                                    AS DurationHHMMSS,
         h.message
FROM     msdb.dbo.sysjobhistory AS h
WHERE    h.job_id = (SELECT job_id FROM msdb.dbo.sysjobs
                     WHERE name = N'ClaimsAnalytics - Nightly Denial Load')
ORDER BY h.instance_id DESC;
GO


/*==============================================================================
  5. EXPRESS EDITION ALTERNATIVE

  No Agent. Save the block below as C:\ClaimsAnalytics\nightly.sql and register
  it with Windows Task Scheduler:

      Program:   sqlcmd
      Arguments: -S localhost\SQLEXPRESS -d ClaimsAnalytics -E -b
                 -i C:\ClaimsAnalytics\nightly.sql
                 -o C:\ClaimsAnalytics\nightly.log

  The -b flag is what makes this work: without it sqlcmd returns exit code 0
  even when the script raises an error, and Task Scheduler reports every run as
  successful no matter what happened.

  ----------------------------------------------------------------------------
  SET NOCOUNT ON;

  DECLARE @Yesterday DATE = CAST(DATEADD(DAY, -1, SYSDATETIME()) AS DATE);
  DECLARE @LookBack  DATE = DATEADD(DAY, -7, @Yesterday);

  EXEC dw.usp_BackfillClaimDenialDaily
       @StartDate = @LookBack, @EndDate = @Yesterday, @Reload = 0;

  DECLARE @Bad INT;
  SELECT @Bad = COUNT(*)
  FROM   ops.vw_PipelineHealth
  WHERE  PartitionDate >= @LookBack
    AND  HealthFlag IN ('LOAD FAILED','VOLUME DROP OVER 50 PCT',
                        'VOLUME SPIKE OVER 100 PCT','REJECT RATE OVER THRESHOLD');

  IF @Bad > 0
      RAISERROR('Pipeline health check failed on %d partition(s).', 16, 1, @Bad);
  ----------------------------------------------------------------------------
==============================================================================*/

PRINT '04 complete. The pipeline is scheduled.';
GO

SET NOEXEC OFF;
GO
