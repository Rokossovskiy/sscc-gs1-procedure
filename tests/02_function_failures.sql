USE SSCC_Test;
GO
SET NOCOUNT ON;
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;

-- Исходная заглушка сохраняется, чтобы восстанавливать её после каждой подмены.
-- Транзакция для этого не годится: процедура запрещает вызов внутри неё (50006).
DROP TABLE IF EXISTS dbo.tst_SavedModule;
SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.fn_GenerateGS1SSCC')) AS Definition
INTO dbo.tst_SavedModule;
GO

CREATE OR ALTER PROCEDURE dbo.tst_RestoreGenerateStub
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Definition NVARCHAR(MAX) = (SELECT Definition FROM dbo.tst_SavedModule);
    -- DROP + исходный текст: работает при любом начале определения (CREATE или CREATE OR ALTER)
    DROP FUNCTION IF EXISTS dbo.fn_GenerateGS1SSCC;
    EXEC (@Definition);
END;
GO

-- 8. Функция вернула NULL: 50004, номер 1 пропущен
DECLARE @s NVARCHAR(22);
EXEC (N'ALTER FUNCTION dbo.fn_GenerateGS1SSCC (@SSCC17 NVARCHAR(17)) RETURNS NVARCHAR(25)
       AS BEGIN RETURN NULL; END');
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'fn NULL' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;
EXEC dbo.tst_RestoreGenerateStub;
GO

-- 9. Функция вернула строку с хвостовым пробелом: 50004, номер 2 пропущен
DECLARE @s NVARCHAR(22);
EXEC (N'ALTER FUNCTION dbo.fn_GenerateGS1SSCC (@SSCC17 NVARCHAR(17)) RETURNS NVARCHAR(25)
       AS BEGIN RETURN N''(00)'' + @SSCC17 + N''6 ''; END');
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'fn trailing space' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;
EXEC dbo.tst_RestoreGenerateStub;
GO

-- 10. Runtime-ошибка внутри функции (деление на ноль): исходная 8134, номер 3 пропущен
DECLARE @s NVARCHAR(22);
EXEC (N'ALTER FUNCTION dbo.fn_GenerateGS1SSCC (@SSCC17 NVARCHAR(17)) RETURNS NVARCHAR(25)
       AS BEGIN RETURN N''(00)'' + @SSCC17 + CAST(1 / (LEN(@SSCC17) - 17) AS NVARCHAR(1)); END');
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'fn runtime error' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;
EXEC dbo.tst_RestoreGenerateStub;
GO

-- 11. Нецифровой символ вместо контрольной цифры (NCHAR(178), надстрочная двойка): 50004, номер 4 пропущен
DECLARE @s NVARCHAR(22);
EXEC (N'ALTER FUNCTION dbo.fn_GenerateGS1SSCC (@SSCC17 NVARCHAR(17)) RETURNS NVARCHAR(25)
       AS BEGIN RETURN N''(00)'' + @SSCC17 + NCHAR(178); END');
BEGIN TRY EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; END TRY
BEGIN CATCH SELECT N'fn non-digit' AS test, ERROR_NUMBER() AS err,
    (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter) AS counter, ERROR_MESSAGE() AS msg; END CATCH;
EXEC dbo.tst_RestoreGenerateStub;
GO

-- 12. Заглушка восстановлена; каждый сбой пропустил ровно один номер,
--     следующий вызов выдаёт серийный номер 5
SET NOCOUNT ON;
DECLARE @s      NVARCHAR(22),
        @Before BIGINT = (SELECT LastGS1SSCC FROM dbo.tbl_SSCC_Counter);

SELECT N'stub restored' AS test, dbo.fn_GenerateGS1SSCC(N'54602541000000001') AS SSCC;

EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT;
SELECT N'after failures' AS test, @Before AS counter_before, @s AS SSCC;

DROP PROCEDURE dbo.tst_RestoreGenerateStub;
DROP TABLE dbo.tst_SavedModule;
GO

