-- =====================================================================
-- STEP 4: Expiring reservations + SQL Server Agent job
-- =====================================================================

-- 4a. Expire Reserved bookings older than @OlderThanMinutes
CREATE OR ALTER PROCEDURE dbo.usp_ExpireReservations
    @OlderThanMinutes INT = 15,
    @ExpiredCount     INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Reserved bookings past the cutoff become Expired.
        -- The Step 3 triggers release the seats (SeatsSold)
        -- and write the Reserved -> Expired rows into BookingLog.
        UPDATE dbo.Bookings
        SET    Status = N'Expired'
        WHERE  Status = N'Reserved'
          AND  CreatedAt < DATEADD(MINUTE, -@OlderThanMinutes, SYSDATETIME());

        SET @ExpiredCount = @@ROWCOUNT;   -- read right after the UPDATE

        -- Log every run, also when nothing expired (ExpiredCount = 0)
        INSERT dbo.JobRunLog (ExpiredCount) VALUES (@ExpiredCount);

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

-- 4b. Agent job: run usp_ExpireReservations every 5 minutes.
-- msdb procedures are called by full name, so the script stays in KinoDB.

-- Re-runnable: delete the job if it already exists
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'KinoDB - Expire reservations')
    EXEC msdb.dbo.sp_delete_job @job_name = N'KinoDB - Expire reservations';

-- Create the job
EXEC msdb.dbo.sp_add_job
     @job_name    = N'KinoDB - Expire reservations',
     @description = N'Expires unpaid KinoDB reservations older than 15 minutes.';

-- One T-SQL step in database KinoDB
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'KinoDB - Expire reservations',
     @step_name     = N'Expire reservations',
     @subsystem     = N'TSQL',
     @database_name = N'KinoDB',
     @command       = N'EXEC dbo.usp_ExpireReservations;';

-- Every day, every 5 minutes, all day
EXEC msdb.dbo.sp_add_jobschedule
     @job_name             = N'KinoDB - Expire reservations',
     @name                 = N'KinoDB - Every 5 minutes',
     @freq_type            = 4,        -- daily
     @freq_interval        = 1,        -- every 1 day
     @freq_subday_type     = 4,        -- unit: minutes
     @freq_subday_interval = 5,        -- every 5 minutes
     @active_start_time    = 0,        -- 00:00:00
     @active_end_time      = 235959;   -- 23:59:59

-- Assign the job to the local server
EXEC msdb.dbo.sp_add_jobserver
     @job_name    = N'KinoDB - Expire reservations',
     @server_name = N'(local)';
GO
