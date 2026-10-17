/*
    Миграция dbo.tbl_SSCC_Counter.
    Инвариант «ровно одна строка, значение 0..999 999 999» переносится из процедуры в схему:
    - Id TINYINT + PRIMARY KEY + CHECK (Id = 1): вторая строка невозможна;
    - CHECK диапазона: недопустимое значение нельзя записать.
    Выполняется до установки dbo.sp_GetNextGS1SSCC. Текущее значение счётчика сохраняется.
    Повторный запуск ничего не меняет.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;  -- любая ошибка откатывает миграцию целиком

IF COL_LENGTH(N'dbo.tbl_SSCC_Counter', N'Id') IS NULL
BEGIN
    BEGIN TRANSACTION;

    DECLARE @Rows  INT,
            @Value BIGINT,
            @Msg   NVARCHAR(2048);

    -- TABLOCKX + HOLDLOCK: до конца миграции никто не выдаст номер и не изменит таблицу
    SELECT @Rows = COUNT(*), @Value = MAX(LastGS1SSCC)
    FROM dbo.tbl_SSCC_Counter WITH (TABLOCKX, HOLDLOCK);

    -- Аномалии не исправляются автоматически: пустую таблицу или лишние строки разбирает человек
    IF @Rows <> 1
    BEGIN
        SET @Msg = CONCAT(N'Миграция остановлена: строк в dbo.tbl_SSCC_Counter: ', @Rows,
                          N', ожидается ровно одна.');
        THROW 50101, @Msg, 1;
    END;

    -- Границы совпадают с @MinSerial и @MaxSerial в процедуре
    IF @Value NOT BETWEEN 0 AND 999999999
    BEGIN
        SET @Msg = CONCAT(N'Миграция остановлена: значение счётчика ', @Value,
                          N' вне диапазона 0..999999999.');
        THROW 50102, @Msg, 1;
    END;

    -- NOT NULL + DEFAULT: существующая строка получает Id = 1
    ALTER TABLE dbo.tbl_SSCC_Counter
        ADD Id TINYINT NOT NULL CONSTRAINT DF_SSCC_Counter_Id DEFAULT (1);

    -- Динамический SQL: в этом же пакете новый столбец ещё не виден компилятору
    EXEC (N'
        ALTER TABLE dbo.tbl_SSCC_Counter ADD
            CONSTRAINT PK_SSCC_Counter PRIMARY KEY CLUSTERED (Id),
            CONSTRAINT CK_SSCC_Counter_OnlyOneRow CHECK (Id = 1),
            CONSTRAINT CK_SSCC_Counter_Range CHECK (LastGS1SSCC BETWEEN 0 AND 999999999);');

    COMMIT TRANSACTION;
END;
GO

