USE SSCC_Test;
GO
SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- Тип выходного параметра: nvarchar, 44 байта = 22 символа
SELECT name, TYPE_NAME(user_type_id) AS type_name, max_length AS bytes
FROM sys.parameters
WHERE object_id = OBJECT_ID(N'dbo.sp_GetNextGS1SSCC');

-- 1. Обычные вызовы: серийные номера 1, 2, 3
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 1' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 2' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial 3' AS test, @s AS SSCC, LEN(@s) AS len, DATALENGTH(@s) AS bytes;

-- 2. Граница: 999999999, затем ошибка 50005 и явный сброс на 0
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 999999998 WHERE Id = 1;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'serial max' AS test, @s AS SSCC;

-- 2a. Переполнение без разрешения: 50005, строка не обновляется
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'overflow' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;

-- 2b. Явно разрешённый сброс на 0
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT, @AllowWrapAround = 1;
SELECT N'after reset' AS test, @s AS SSCC,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter;
GO

SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- 3. CHECK диапазона не даёт записать недопустимое значение
BEGIN TRY UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = -5 WHERE Id = 1; END TRY
BEGIN CATCH SELECT N'range check' AS test, ERROR_NUMBER() AS err; END CATCH;

-- 3a. Повреждение данных моделируется отключением ограничения: процедура должна отказать с 50002
ALTER TABLE dbo.tbl_SSCC_Counter NOCHECK CONSTRAINT CK_SSCC_Counter_Range;
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = -5 WHERE Id = 1;
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'invalid value' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;

-- Восстановление: корректное значение и снова доверенное ограничение
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;
ALTER TABLE dbo.tbl_SSCC_Counter WITH CHECK CHECK CONSTRAINT CK_SSCC_Counter_Range;
GO

SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- 4. Нет строки счётчика
DELETE FROM dbo.tbl_SSCC_Counter;
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'no row' AS test, ERROR_NUMBER() AS err, ERROR_MESSAGE() AS msg; END CATCH;

INSERT INTO dbo.tbl_SSCC_Counter DEFAULT VALUES;  -- Id = 1, LastGS1SSCC = 0
GO

SET NOCOUNT ON;

-- 5. Вторую строку не пускает схема: PK при Id = 1, CHECK (Id = 1) при другом Id
BEGIN TRY INSERT INTO dbo.tbl_SSCC_Counter (LastGS1SSCC) VALUES (0); END TRY
BEGIN CATCH SELECT N'second row same id' AS test, ERROR_NUMBER() AS err; END CATCH;

BEGIN TRY INSERT INTO dbo.tbl_SSCC_Counter (Id, LastGS1SSCC) VALUES (2, 0); END TRY
BEGIN CATCH SELECT N'second row other id' AS test, ERROR_NUMBER() AS err; END CATCH;
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;  -- поведение по умолчанию: судьбу транзакции решает вызывающий
DECLARE @s NVARCHAR(22);

-- 6. Вызов внутри транзакции: 50006 до любых изменений, транзакция вызывающего остаётся фиксируемой
BEGIN TRANSACTION;
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'in transaction' AS test, ERROR_NUMBER() AS err, XACT_STATE() AS xact_state,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

SET NOCOUNT ON;
DECLARE @s NVARCHAR(22);

-- 7. IMPLICIT_TRANSACTIONS ON без открытой транзакции: вызов разрешён,
--    процедура не оставляет транзакцию открытой, режим у вызывающего восстанавливается.
--    Проверка до любого SELECT из таблицы: такой SELECT сам открыл бы транзакцию.
SET IMPLICIT_TRANSACTIONS ON;
EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'implicit tran' AS test, @s AS SSCC, @@TRANCOUNT AS trancount, @@OPTIONS & 2 AS implicit_on;
SET IMPLICIT_TRANSACTIONS OFF;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- Восстановление исходного состояния
SET NOCOUNT ON;
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;
SELECT N'counter rows' AS test, COUNT(*) AS CounterRows, MAX(LastGS1SSCC) AS LastValue
FROM dbo.tbl_SSCC_Counter;
GO

