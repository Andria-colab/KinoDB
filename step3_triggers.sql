/*
Team:
Lizi Makharadze
Ana Maisuradze
Andria Beridze
Luka Akirtava
*/

USE KinoDB;
GO

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
	from dbo.Screenings s inner join @affectedScreenings a
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
