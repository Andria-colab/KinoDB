/*
Team:
Lizi Makharadze
Ana Maisuradze
Andria Beridze
Luka Akirtava
*/
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
