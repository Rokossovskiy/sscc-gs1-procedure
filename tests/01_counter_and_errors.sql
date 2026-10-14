USE SSCC_Test;
GO
SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- Тип выходного параметра: nvarchar, 44 байта = 22 символа
SELECT name, TYPE_NAME(user_type_id) AS type_name, max_length AS bytes
FROM sys.parameters
WHERE object_id = OBJECT_ID(N'dbo.sp_GetNextGS1SSCC');

-- 1. Обычные вызовы: серийные номера 1, 2, 3
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 1' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 2' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 3' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;

-- 2. Граница: 999999999, затем сброс на 0
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 999999998;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial max' AS test, @s AS SSCC;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'after reset' AS test, @s AS SSCC,
       (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter;
GO

SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- 3. Недопустимое значение
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = -5;
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'invalid value' AS test, ERROR_NUMBER() AS err, ERROR_MESSAGE() AS msg; END CATCH;

-- 4. Нет строки счётчика
DELETE FROM dbo.tbl_SSCC_Counter;
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'no row' AS test, ERROR_NUMBER() AS err, ERROR_MESSAGE() AS msg; END CATCH;

-- 5. Две строки счётчика
INSERT INTO dbo.tbl_SSCC_Counter (LastGS1SSCC) VALUES (0), (0);
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'two rows' AS test, ERROR_NUMBER() AS err, ERROR_MESSAGE() AS msg; END CATCH;

-- Восстановление исходного состояния
DELETE FROM dbo.tbl_SSCC_Counter;
INSERT INTO dbo.tbl_SSCC_Counter (LastGS1SSCC) VALUES (0);
SELECT COUNT(*) AS CounterRows, MAX(LastGS1SSCC) AS LastValue FROM dbo.tbl_SSCC_Counter;
GO
