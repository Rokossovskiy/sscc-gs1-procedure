/*
    Тестовое окружение. НЕ является частью решения.
    Пересоздаёт базу SSCC_Test, таблицу-счётчик из условия и заглушки функций.
    Заглушка fn_GS1SSCC_CheckDigit реализует GS1 Mod 10 (веса 3/1 справа налево).
*/
USE master;
GO
IF DB_ID(N'SSCC_Test') IS NOT NULL
BEGIN
    ALTER DATABASE SSCC_Test SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SSCC_Test;
END;
GO
CREATE DATABASE SSCC_Test;
GO
USE SSCC_Test;
GO

-- Таблица из условия, одна строка со значением 0
CREATE TABLE dbo.tbl_SSCC_Counter (
    LastGS1SSCC BIGINT NOT NULL DEFAULT 0
);
INSERT INTO dbo.tbl_SSCC_Counter DEFAULT VALUES;
GO

-- Заглушка: контрольная цифра GS1 Mod 10
CREATE OR ALTER FUNCTION dbo.fn_GS1SSCC_CheckDigit (@Digits NVARCHAR(20))
RETURNS INT
AS
BEGIN
    DECLARE @Len INT = LEN(@Digits), @i INT = 1, @Sum INT = 0;

    IF @Digits IS NULL OR @Len = 0 OR @Digits LIKE N'%[^0-9]%'
        RETURN NULL;

    WHILE @i <= @Len
    BEGIN
        -- крайняя правая цифра получает вес 3, далее чередование 1/3
        SET @Sum += CAST(SUBSTRING(@Digits, @i, 1) AS INT)
                  * CASE WHEN (@Len - @i) % 2 = 0 THEN 3 ELSE 1 END;
        SET @i += 1;
    END;

    RETURN (10 - @Sum % 10) % 10;
END;
GO

-- Заглушка: '(00)' + 17 цифр + контрольная цифра
CREATE OR ALTER FUNCTION dbo.fn_GenerateGS1SSCC (@SSCC17 NVARCHAR(17))
RETURNS NVARCHAR(25)
AS
BEGIN
    IF @SSCC17 IS NULL OR LEN(@SSCC17) <> 17 OR @SSCC17 LIKE N'%[^0-9]%'
        RETURN NULL;

    RETURN N'(00)' + @SSCC17
         + CAST(dbo.fn_GS1SSCC_CheckDigit(@SSCC17) AS NVARCHAR(1));
END;
GO
