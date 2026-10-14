
/*
    dbo.sp_GetNextGS1SSCC
    Выдаёт следующий SSCC в формате '(00)' + 18 цифр через выходной параметр @SSCC.

    Уникальность: атомарный UPDATE строки счётчика под эксклюзивной блокировкой;
                  параллельные вызовы выстраиваются в очередь.
    Граница:      серийный номер 0..999 999 999, после верхней границы сброс на 0.
    Ошибки:       THROW с кодами 50001–50004; транзакция откатывается,
                  номер не расходуется, @SSCC остаётся NULL.
    Внешняя транзакция: при ошибке откатывается и она
                  (XACT_ABORT ON делает транзакцию нефиксируемой).
*/
CREATE OR ALTER PROCEDURE dbo.sp_GetNextGS1SSCC
    @SSCC NVARCHAR(22) OUTPUT   -- '(00)' (4) + 18 цифр = ровно 22 символа; NVARCHAR, как у fn_GenerateGS1SSCC
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- любая ошибка откатывает транзакцию целиком

    -- Формат SSCC
    DECLARE @CompanyPrefix NVARCHAR(8) = N'54602541';  -- GS1-префикс компании
    DECLARE @AppId         NVARCHAR(4) = N'(00)';      -- идентификатор применения SSCC
    DECLARE @SerialLength  TINYINT     = 9;            -- длина серийного номера
    DECLARE @MinSerial     BIGINT      = 0;
    DECLARE @MaxSerial     BIGINT      = POWER(CAST(10 AS BIGINT), @SerialLength) - 1;  -- 999 999 999

    -- Коды ошибок
    DECLARE @ErrNoCounterRow    INT = 50001;  -- нет строки счётчика
    DECLARE @ErrOutOfRange      INT = 50002;  -- значение счётчика вне диапазона
    DECLARE @ErrManyCounterRows INT = 50003;  -- строк счётчика больше одной
    DECLARE @ErrBadFunction     INT = 50004;  -- fn_GenerateGS1SSCC вернула некорректный результат

    DECLARE @Serial   BIGINT,
            @RowCount INT,
            @SSCC17   NVARCHAR(17),
            @Result   NVARCHAR(25),           -- тип возврата fn_GenerateGS1SSCC
            @Msg      NVARCHAR(2048);

    SET @SSCC = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Чтение, инкремент и получение нового значения одним оператором.
        -- Блокировка строки держится до конца транзакции, поэтому
        -- две сессии не могут получить одно и то же значение.
        -- Недопустимое значение не меняется: оно попадёт в @Serial и будет отклонено ниже.
        UPDATE dbo.tbl_SSCC_Counter
        SET @Serial = LastGS1SSCC =
                CASE
                    WHEN LastGS1SSCC = @MaxSerial
                        THEN @MinSerial                     -- верхняя граница: сброс на 0
                    WHEN LastGS1SSCC >= @MinSerial AND LastGS1SSCC < @MaxSerial
                        THEN LastGS1SSCC + 1
                    ELSE LastGS1SSCC                        -- вне диапазона: не трогаем
                END;

        SET @RowCount = @@ROWCOUNT;

        IF @RowCount = 0
            THROW @ErrNoCounterRow, N'sp_GetNextGS1SSCC: в dbo.tbl_SSCC_Counter нет строки счётчика.', 1;

        IF @RowCount > 1
            THROW @ErrManyCounterRows, N'sp_GetNextGS1SSCC: в dbo.tbl_SSCC_Counter больше одной строки.', 1;

        IF @Serial NOT BETWEEN @MinSerial AND @MaxSerial
        BEGIN
            SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: значение счётчика ', @Serial,
                              N' вне диапазона ', @MinSerial, N'..', @MaxSerial, N'.');
            THROW @ErrOutOfRange, @Msg, 1;
        END;

        -- Префикс + серийный номер с ведущими нулями до 9 знаков
        -- (NVARCHAR(20) вмещает любой BIGINT со знаком)
        SET @SSCC17 = @CompanyPrefix
                    + RIGHT(REPLICATE(N'0', @SerialLength) + CONVERT(NVARCHAR(20), @Serial), @SerialLength);

        SET @Result = dbo.fn_GenerateGS1SSCC(@SSCC17);

        -- Ожидается ровно '(00)' + переданные 17 цифр + одна контрольная цифра.
        -- DATALENGTH, в отличие от LEN, учитывает хвостовые пробелы.
        IF @Result IS NULL
           OR DATALENGTH(@Result) <> DATALENGTH(@AppId + @SSCC17 + N'0')
           OR @Result NOT LIKE @AppId + @SSCC17 + N'[0-9]'
        BEGIN
            SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: fn_GenerateGS1SSCC вернула некорректное значение для ',
                              @SSCC17, N': ', ISNULL(N'''' + @Result + N'''', N'NULL'));
            THROW @ErrBadFunction, @Msg, 1;
        END;

        COMMIT TRANSACTION;

        SET @SSCC = @Result;  -- длина проверена: ровно 22 символа, без усечения
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;  -- номер не расходуется, если SSCC не сформирован
        SET @SSCC = NULL;
        THROW;                     -- исходная ошибка уходит вызывающему
    END CATCH;
END;
GO
