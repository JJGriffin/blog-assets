/*
	SQL Server Change Tracking Example Scripts

	This script is an accompaniment to my blog post, that provides an overview of how to get started with SQL Server change tracking.
	To execute, you will need access to an Azure SQL or SQL Server 2016 or greater database.
	Any problems with the script, let me know!
*/

--Change the below to the name of your database or ensure you have a database on your server called CT-Test
USE [CT-Test]
GO
--Enable Change Tracking, with auto-cleanup and retention period of 7 days.
ALTER DATABASE [CT-Test]
SET CHANGE_TRACKING = ON  
(CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);
GO
--Verify that the database has been enabled for Change Tracking
SELECT d.name, ctd.is_auto_cleanup_on, ctd.retention_period, ctd.retention_period_units_desc
FROM sys.change_tracking_databases AS ctd
 INNER JOIN sys.databases AS d
  ON ctd.database_id = d.database_id;
GO
--Create a dummy table - note no primary key
CREATE TABLE [dbo].[MyTable]
(
	[ID] INT IDENTITY(1,1) NOT NULL,
	[Name] NVARCHAR(50) NULL,
	[Birthday] DATETIME NULL,
	[FavouriteCake] NVARCHAR(50)
);
GO
--Attempt to enable Change Tracking on MyTable - this will fail
ALTER TABLE [dbo].[MyTable]  
ENABLE CHANGE_TRACKING  
WITH (TRACK_COLUMNS_UPDATED = ON);
GO
--So we can fix by recreating our table with a Primary Key value this time.
DROP TABLE [dbo].[MyTable];
CREATE TABLE [dbo].[MyTable]
(
	[ID] INT IDENTITY(1,1) PRIMARY KEY NOT NULL,
	[Name] NVARCHAR(50) NULL,
	[Birthday] DATETIME NULL,
	[FavouriteCake] NVARCHAR(50)
);
ALTER TABLE [dbo].[MyTable]  
ENABLE CHANGE_TRACKING  
WITH (TRACK_COLUMNS_UPDATED = ON);
GO
--With Change Tracking all configured, we can now check the current version - this is global across the database
--Running the below should return a 0.
SELECT CHANGE_TRACKING_CURRENT_VERSION();
--Now lets insert some data, as part of two seperate batches
INSERT INTO [dbo].[MyTable]([Name], [Birthday], [FavouriteCake])
VALUES('Jane', '1990-03-23', 'Chocolate');
GO
INSERT INTO [dbo].[MyTable]([Name], [Birthday], [FavouriteCake])
VALUES('John', '1985-07-03', 'Banana');
GO
--Checking our change tracking version again, we can see that this should now return a 2
SELECT CHANGE_TRACKING_CURRENT_VERSION();
--We can also view the MINIMUM change tracking version that the database is still recording changes from
--Running the below should return 0
SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('dbo.MyTable'));
--These functions aren't too useful on their own...
--...but when we pass these as part of the CHANGETABLE function, we can view further details about all changes across a period
--Note that the CHANGETABLE function MUST be aliased, otherwise an error will occur
DECLARE @changeTrackingMinimumVersion INT = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('dbo.MyTable'));

SELECT *
FROM CHANGETABLE(CHANGES [dbo].[MyTable], @changeTrackingMinimumVersion) AS CT;
--Now let's add some more data, update existing rows and remove some completely
INSERT INTO [dbo].[MyTable]([Name], [Birthday], [FavouriteCake])
VALUES('Alex', '1987-01-04', 'Sponge');
GO
UPDATE [dbo].[MyTable]
SET [FavouriteCake] = 'Cream'
WHERE [Name] = 'John';
GO
DELETE FROM [dbo].[MyTable]
WHERE [Name] = 'Jane';
GO
--Checking our change tracking version again - should be 5
SELECT CHANGE_TRACKING_CURRENT_VERSION();
--Now we can get some more interesting results
--Running the query with a change tracking value of 2 provides us with full details for the previous transactions
--For the list of changed columns, we have to pass this through an additional function to review the underlying data
SELECT CT.SYS_CHANGE_VERSION, CT.SYS_CHANGE_CREATION_VERSION, CT.SYS_CHANGE_OPERATION,
	   CASE
			WHEN CT.SYS_CHANGE_COLUMNS IS NOT NULL THEN CHANGE_TRACKING_IS_COLUMN_IN_MASK(COLUMNPROPERTY(OBJECT_ID('dbo.MyTable'), 'FavouriteCake', 'ColumnId'), CT.SYS_CHANGE_COLUMNS)
			ELSE 0 END AS FavouriteCakeColumnChanged, 
	   CT.SYS_CHANGE_CONTEXT, CT.ID
FROM CHANGETABLE(CHANGES [dbo].[MyTable], 2) AS CT;
--With the basics covered, we can now look at implementing a solution that:
--	- Records the latest Change Tracking version for the table
--  - A stored procedure that will update the change tracking table with the latest version.
--	- A query that will grab the latest changes and move the data into a staging table (for this example, this will exist in the same database)
--	- A MERGE statement that will merge the changes into the new table, and insert/update/delete records accordingly.

--First, we setup our change tracking logging table
--The constraints are optional, but can help to enforce data integrity
--We also initialise the table based on the current change tracking version in the DB

CREATE TABLE [dbo].[ChangeTrackingVersion]
(
	[TableName] VARCHAR(255) NOT NULL,
	CONSTRAINT CHK_TableName CHECK ([TableName] IN ('MyTable')),
	CONSTRAINT UC_TableName UNIQUE ([TableName]),
	[SYS_CHANGE_VERSION] BIGINT NOT NULL
);
INSERT INTO [dbo].[ChangeTrackingVersion]
VALUES ('MyTable', CHANGE_TRACKING_CURRENT_VERSION());

GO
--Next, we create our staging tables and table where data will be merged into
--In this case, we want to aggregate cake preferences based on birthday and remove any personally identifiable information
--These would typically sit in a seperate database and be moved across via SSIS or Azure Data Factory
CREATE TABLE [dbo].[Staging_MyTable]
(
	[ID] INT NOT NULL,
	[Birthday] DATETIME NULL,
	[FavouriteCake] NVARCHAR(50),
	[SYS_CHANGE_OPERATION] NCHAR(1) NOT NULL,
	CONSTRAINT [CHK_MyTable] CHECK ([SYS_CHANGE_OPERATION] IN ('U','I','D'))
);


CREATE TABLE [dbo].[ReportingMyTable]
(
	[ID] INT NOT NULL,
	[Birthday] DATETIME NULL,
	[FavouriteCake] NVARCHAR(50)

);
GO
--Finally, we create the stored procedure that will be called as part of the query/merge operation
CREATE PROCEDURE [dbo].[uspUpdateChangeTrackingVersion] @CurrentTrackingVersion BIGINT, @TableName varchar(50)
AS
BEGIN
UPDATE [dbo].[ChangeTrackingVersion]
SET [SYS_CHANGE_VERSION] = @CurrentTrackingVersion
WHERE [TableName] = @TableName
END;
GO
--With all objects created, we can now run the following query to start synchronising data.
--First, run a one-off query to get all current records moved across.

INSERT INTO dbo.ReportingMyTable
SELECT ID, Birthday, FavouriteCake
FROM dbo.MyTable;

--Verify table results

SELECT *
FROM dbo.ReportingMyTable;

--Then, make some additional data changes

UPDATE dbo.MyTable
SET [Birthday] = '1989-10-1'
WHERE ID = 2;
GO
INSERT INTO dbo.MyTable
VALUES	('Mary', '1991-10-11', 'Banana'),
	    ('Jude', '1978-09-25', 'Pannacotta');
GO
DELETE FROM MyTable
WHERE ID = 3;
GO
--Now, we can run the synchronisation scripts.
--First, import all data into the staging table

DECLARE @lastChangeTrackingVersion BIGINT = (SELECT TOP 1 SYS_CHANGE_VERSION FROM [dbo].[ChangeTrackingVersion]),
		@currentChangeTrackingVersion BIGINT = (SELECT CHANGE_TRACKING_CURRENT_VERSION());

INSERT INTO [dbo].[Staging_MyTable]
SELECT CT.ID, ISNULL(MT.Birthday, '') AS Birthday, ISNULL(MT.FavouriteCake, '') AS FavouriteCake,
	   CT.SYS_CHANGE_OPERATION
FROM [dbo].[MyTable] AS MT 
 RIGHT JOIN CHANGETABLE(CHANGES [dbo].[MyTable], @lastChangeTrackingVersion) AS CT
  ON MT.ID = CT.ID
WHERE CT.SYS_CHANGE_VERSION <= @currentChangeTrackingVersion;

--Then, run a merge script, with logic in place to handle each potential record operation

MERGE [dbo].[ReportingMyTable] AS target
USING [dbo].[Staging_MyTable] AS source
ON target.[ID] = source.[ID]
--If change was an INSERT, add it to the database.
WHEN NOT MATCHED BY TARGET AND source.[SYS_CHANGE_OPERATION] = 'I' THEN
	INSERT ([ID], [Birthday], [FavouriteCake])
	VALUES (source.[ID], source.[Birthday], source.[FavouriteCake])
--If change was an UPDATE, update existing record.
WHEN MATCHED AND source.[SYS_CHANGE_OPERATION] = 'U' THEN 
	UPDATE 
	SET target.[Birthday] = source.[Birthday],
		target.[FavouriteCake] = source.[FavouriteCake]
--If change was a DELETE, then delete the record in target
WHEN MATCHED AND source.[SYS_CHANGE_OPERATION] = 'D' THEN 
	DELETE;
GO
--Finally, we update the change tracking table to record the fact that we have grabbed the latest changes
DECLARE @currentChangeTrackingVersion BIGINT = CHANGE_TRACKING_CURRENT_VERSION();

EXEC [dbo].[uspUpdateChangeTrackingVersion] @currentChangeTrackingVersion, 'MyTable'

--Verify the results now - should be 3 results and ID 2 should have a birthday of '1989-10-1'

SELECT *
FROM ReportingMyTable

--And that's how you get started with change tracking on SQL Server!

