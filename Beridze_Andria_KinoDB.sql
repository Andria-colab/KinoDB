-- Group members:
-- Lizi Makharadze
-- Ana Maisuradze
-- Andria Beridze
-- Luka Akirtava

-- STEP 1: DATABASE AND TABLES

USE master;
GO

IF DB_ID('KinoDB') IS NOT NULL
BEGIN
    ALTER DATABASE KinoDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE KinoDB;
END;
GO

CREATE DATABASE KinoDB;
GO

USE KinoDB;
GO

SET NOCOUNT ON;
GO

-- Halls: the physical rooms, HallID is given by hand, so no IDENTITY.
CREATE TABLE dbo.Halls(
    HallID INT NOT NULL CONSTRAINT PK_Halls PRIMARY KEY,
    Name NVARCHAR(50) NOT NULL CONSTRAINT UQ_Halls_Name UNIQUE,
    SeatCount INT NOT NULL CONSTRAINT CK_Halls_SeatCount CHECK (SeatCount > 0)
);
GO

CREATE TABLE dbo.Movies(
    MovieID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Movies PRIMARY KEY,
    Title NVARCHAR(200) NOT NULL,
    DurationMin INT NOT NULL CONSTRAINT CK_Movies_DurationMin CHECK (DurationMin > 0),
    AgeRating NVARCHAR(5) NOT NULL
);
GO

CREATE TABLE dbo.Screenings(
    ScreeningID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Screenings PRIMARY KEY,
    MovieID INT NOT NULL CONSTRAINT FK_Screenings_Movies FOREIGN KEY REFERENCES dbo.Movies (MovieID),
    HallID INT NOT NULL CONSTRAINT FK_Screenings_Halls FOREIGN KEY REFERENCES dbo.Halls (HallID),
    StartsAt DATETIME2(0) NOT NULL,
    TicketPrice DECIMAL(6,2) NOT NULL CONSTRAINT CK_Screenings_TicketPrice CHECK (TicketPrice > 0),
    SeatsSold INT NOT NULL CONSTRAINT DF_Screenings_SeatsSold DEFAULT (0) CONSTRAINT CK_Screenings_SeatsSold CHECK (SeatsSold >= 0)
);
GO

CREATE TABLE dbo.Customers(
    CustomerID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customers PRIMARY KEY,
    FullName NVARCHAR(100) NOT NULL,
    Email NVARCHAR(100) NOT NULL CONSTRAINT UQ_Customers_Email UNIQUE
);
GO

CREATE TABLE dbo.Bookings(
    BookingID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Bookings PRIMARY KEY,
    ScreeningID INT NOT NULL CONSTRAINT FK_Bookings_Screenings FOREIGN KEY REFERENCES dbo.Screenings (ScreeningID),
    CustomerID INT NOT NULL CONSTRAINT FK_Bookings_Customers FOREIGN KEY REFERENCES dbo.Customers (CustomerID),
    Seats INT NOT NULL CONSTRAINT CK_Bookings_Seats CHECK (Seats > 0),
    TotalPrice DECIMAL(8,2) NOT NULL CONSTRAINT CK_Bookings_TotalPrice CHECK (TotalPrice >= 0),
    Status NVARCHAR(20) NOT NULL CONSTRAINT DF_Bookings_Status DEFAULT (N'Reserved') CONSTRAINT CK_Bookings_Status CHECK (Status IN (N'Reserved', N'Paid', N'Cancelled', N'Expired')),
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Bookings_CreatedAt DEFAULT (SYSDATETIME()),
    PaidAt DATETIME2(0) NULL
);
GO

-- BookingLog keeps history, so it has no foreign key to Bookings.
CREATE TABLE dbo.BookingLog(
    LogID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_BookingLog PRIMARY KEY,
    BookingID INT NOT NULL,
    OldStatus NVARCHAR(20) NULL,
    NewStatus NVARCHAR(20) NOT NULL,
    ChangedAt DATETIME2(0) NOT NULL CONSTRAINT DF_BookingLog_ChangedAt DEFAULT (SYSDATETIME()),
    ChangedBy SYSNAME NOT NULL CONSTRAINT DF_BookingLog_ChangedBy DEFAULT (SUSER_SNAME())
);
GO

CREATE TABLE dbo.JobRunLog(
    RunID INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobRunLog PRIMARY KEY,
    RunAt DATETIME2(0) NOT NULL CONSTRAINT DF_JobRunLog_RunAt DEFAULT (SYSDATETIME()),
    ExpiredCount INT NOT NULL
);
GO

-- Sample data
INSERT dbo.Halls (HallID, Name, SeatCount) VALUES
(1, N'Hall A', 10),
(2, N'Hall B', 6);

INSERT dbo.Movies (Title, DurationMin, AgeRating) VALUES
(N'The Last Tram', 104, N'12+'),
(N'Mountain Echo', 96, N'6+'),
(N'Midnight in Batumi', 118, N'16+');

DECLARE @today DATETIME2(0) = CAST(CAST(GETDATE() AS DATE) AS DATETIME2(0));
INSERT dbo.Screenings (MovieID, HallID, StartsAt, TicketPrice) VALUES
(1, 1, DATEADD(HOUR, 19, DATEADD(DAY, 1, @today)), 15.00), -- 1: tomorrow 19:00, Hall A
(2, 2, DATEADD(HOUR, 21, DATEADD(DAY, 1, @today)), 12.00), -- 2: tomorrow 21:00, Hall B
(3, 1, DATEADD(HOUR, 18, DATEADD(DAY, 2, @today)), 18.00), -- 3: in 2 days 18:00, Hall A
(1, 2, DATEADD(HOUR, 20, DATEADD(DAY, -1, @today)), 15.00); -- 4: yesterday 20:00, Hall B

INSERT dbo.Customers (FullName, Email) VALUES
(N'Nino Beridze', N'nino@kino.ge'),
(N'Giorgi Lomidze', N'giorgi@kino.ge'),
(N'Ana Kapanadze', N'ana@kino.ge'),
(N'Levan Tsereteli', N'levan@kino.ge'),
(N'Mariam Gelashvili', N'mariam@kino.ge');
GO

-- STEP 2: STORED PROCEDURES

-- 2a.BookSeats - Reserves seats for a customer.
CREATE PROCEDURE dbo.usp_BookSeats
    @ScreeningID INT,
    @CustomerID INT,
    @Seats INT,
    @BookingID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @StartsAt DATETIME2(0), @TicketPrice DECIMAL(6,2), @SeatsSold INT, @SeatCount INT;

        SELECT @StartsAt = s.StartsAt,
               @TicketPrice = s.TicketPrice,
               @SeatsSold = s.SeatsSold,
               @SeatCount = h.SeatCount
        FROM dbo.Screenings AS s
        JOIN dbo.Halls AS h ON h.HallID = s.HallID
        WHERE s.ScreeningID = @ScreeningID;

        -- checks run in the order
        IF @StartsAt IS NULL
            THROW 50001, N'Screening not found.', 1;

        IF @StartsAt <= SYSDATETIME()
            THROW 50002, N'Screening has already started.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerID = @CustomerID)
            THROW 50003, N'Customer not found.', 1;

        IF @Seats IS NULL OR @Seats <= 0
            THROW 50004, N'Number of seats must be positive.', 1;

        IF @SeatCount - @SeatsSold < @Seats
            THROW 50005, N'Not enough free seats.', 1;

        INSERT dbo.Bookings (ScreeningID, CustomerID, Seats, TotalPrice)
        VALUES (@ScreeningID, @CustomerID, @Seats, @Seats * @TicketPrice);

        SET @BookingID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- 2b. PayBooking - reserved -> paid. Only the status is checked, not the screening time.
CREATE PROCEDURE dbo.usp_PayBooking
    @BookingID INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.Bookings
    SET Status = N'Paid',
        PaidAt = SYSDATETIME()
    WHERE BookingID = @BookingID
      AND Status = N'Reserved';

    IF @@ROWCOUNT = 0
        THROW 50010, N'Booking not found or not reserved.', 1;
END;
GO

-- 2c. CancelBooking - Reserved or Paid -> Cancelled, only if the screening is still in the future.
CREATE PROCEDURE dbo.usp_CancelBooking
    @BookingID INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE b
    SET b.Status = N'Cancelled'
    FROM dbo.Bookings AS b
    JOIN dbo.Screenings AS s ON s.ScreeningID = b.ScreeningID
    WHERE b.BookingID = @BookingID
      AND b.Status IN (N'Reserved', N'Paid')
      AND s.StartsAt > SYSDATETIME();

    IF @@ROWCOUNT = 0
        THROW 50011, N'Booking cannot be cancelled.', 1;
END;
GO

-- 2d. GetScreenReport - One row per screening and parameters are optional touse
CREATE PROCEDURE dbo.usp_GetScreeningReport
    @FromDate DATE = NULL, -- NULL: no date filter
    @MovieID INT = NULL -- NULL: every movie
AS
BEGIN
    SET NOCOUNT ON;

    -- OUTER APPLY, so that screenings without any booking are listed too.
    SELECT s.ScreeningID,
           MovieTitle = m.Title,
           HallName = h.Name,
           s.StartsAt,
           h.SeatCount,
           s.SeatsSold,
           FreeSeats = h.SeatCount - s.SeatsSold,
           PaidRevenue = ISNULL(r.PaidRevenue, 0)
    FROM dbo.Screenings AS s
    JOIN dbo.Movies AS m ON m.MovieID = s.MovieID
    JOIN dbo.Halls AS h ON h.HallID = s.HallID
    OUTER APPLY (
        SELECT PaidRevenue = SUM(b.TotalPrice)
        FROM dbo.Bookings AS b
        WHERE b.ScreeningID = s.ScreeningID
          AND b.Status = N'Paid'
    ) AS r
    WHERE (@FromDate IS NULL OR s.StartsAt >= CAST(@FromDate AS DATETIME2(0)))
      AND (@MovieID IS NULL OR s.MovieID = @MovieID)
    ORDER BY s.StartsAt;
END;
GO


-- STEP 3: TRIGGERS

--3a
create or alter trigger dbo.trg_Bookings_SeatsSold
on dbo.Bookings after insert, update as
begin
	set nocount on;

	--a temporary table variable to hold the IDs of affected screenings 
	declare @AffectedScreenings table (
		ScreeningID int primary key
	);

	--combined IDs of affected screenings
	insert into @AffectedScreenings (ScreeningID)
	select ScreeningID from inserted 
	union
	select ScreeningID from deleted;

	--recalculated SeatsSold from all active bookings
	update s set SeatsSold = coalesce(
		(
			select sum(b.Seats) from dbo.Bookings b
			where b.ScreeningID = s.ScreeningID
			and b.Status in (N'Reserved', N'Paid')
		),
		0
	)
	from dbo.Screenings s inner join @AffectedScreenings a
	on s.ScreeningID = a.ScreeningID;

	--check the hall capacity
	if exists (
		select 1 from dbo.Screenings s
		inner join dbo.Halls h on h.HallID=s.HallID
		inner join @AffectedScreenings a on a.ScreeningID=s.ScreeningID
		where s.SeatsSold>h.SeatCount
	)
	begin
		throw 50020, N'Not enough seats in the hall.', 1;
	end;
end;
go


--3b
create or alter trigger dbo.trg_Bookings_Log
on dbo.Bookings after insert, update as
begin
	set nocount on;
	--automatically record new bookings and status changes in dbo.BookingLog
	insert into dbo.BookingLog
		(BookingID, OldStatus, NewStatus)
	select i.BookingID, d.Status, i.Status 
	--left join because we want to log every new and updated booking
	from inserted i left join deleted d
	on d.BookingID = i.BookingID 
	where d.BookingID is null or d.Status<>i.Status;
end;
go


--3c
create or alter trigger dbo.trg_Bookings_InsteadOfDelete
on dbo.Bookings instead of delete as --the original deletion is intercepted
begin
	set nocount on;
	--instead of removing a booking, we change its status to cancelled
	update b set b.Status = N'Cancelled'
	from dbo.Bookings b inner join deleted d
	on d.BookingID = b.BookingID
	inner join dbo.Screenings s
	on s.ScreeningID = b.ScreeningID
	where b.Status in (N'Reserved', N'Paid') and s.StartsAt > sysdatetime();
end;
go


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


-- =====================================================================
-- STEP 5: TESTS
-- =====================================================================
