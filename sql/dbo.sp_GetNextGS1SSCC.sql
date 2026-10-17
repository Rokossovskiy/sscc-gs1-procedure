/*
    dbo.sp_GetNextGS1SSCC
    Выдаёт следующий SSCC в формате '(00)' + 18 цифр через выходной параметр @SSCC.
    Требует схему из sql/dbo.tbl_SSCC_Counter_constraints.sql (одна строка с Id = 1).

    Уникальность: один автофиксируемый UPDATE строки Id = 1. Чтение, проверка границы
                  и запись выполняются атомарно; параллельные вызовы ждут на блокировке строки.
    Внешняя транзакция: вызов внутри неё запрещён (ошибка 50006). Если бы вызов прошёл
                  успешно, а внешняя транзакция потом откатилась по бизнес-причинам,
                  счётчик вернулся бы назад, и уже выданный SSCC выдали бы повторно.
                  SSCC получают до начала бизнес-транзакции; при её откате номер пропускается.
    Граница:      0..999 999 999. После верхней границы по умолчанию ошибка 50005,
                  строка не изменяется. Сброс на 0 только при @AllowWrapAround = 1.
    Ошибки:       THROW, @SSCC остаётся NULL. Если номер уже взят, а SSCC не сформирован,
                  номер пропускается: пропуск допустим, повторная выдача — нет.
    Скрипт не содержит USE: выполняется в целевой базе.
*/
CREATE OR ALTER PROCEDURE dbo.sp_GetNextGS1SSCC
    @SSCC            NVARCHAR(22) OUTPUT,  -- '(00)' (4) + 18 цифр = ровно 22 символа.
                                           -- NVARCHAR, как у fn_GenerateGS1SSCC: без неявных преобразований.
                                           -- Данные чисто ASCII: при рефакторинге функций
                                           -- перевести всю цепочку на VARCHAR(22)
    @AllowWrapAround BIT = 0               -- 1: после 999 999 999 выдать 0; 0 или NULL: ошибка 50005
AS
BEGIN
    SET NOCOUNT ON;

    -- Формат SSCC
    DECLARE @CompanyPrefix NVARCHAR(20) = N'54602541';  -- GS1-префикс компании из условия.
                                                        -- Тип шире 8 символов намеренно: неверная длина
                                                        -- не усечётся молча, а будет поймана проверкой
    DECLARE @PrefixLength  TINYINT      = 8;
    DECLARE @SerialLength  TINYINT      = 9;
    DECLARE @Sscc17Length  TINYINT      = 17;            -- длина входа fn_GenerateGS1SSCC
    DECLARE @AppId         NVARCHAR(4)  = N'(00)';       -- идентификатор применения SSCC
    DECLARE @MinSerial     BIGINT       = 0;
    DECLARE @MaxSerial     BIGINT       = POWER(CAST(10 AS BIGINT), @SerialLength) - 1;
                                                        -- 999 999 999; выводится из длины, чтобы не разойтись с ней
    DECLARE @CounterId     TINYINT      = 1;             -- единственная строка (CK_SSCC_Counter_OnlyOneRow)

    -- Коды ошибок. 50003 (несколько строк) не используется: это запрещает схема.
    -- State в каждом THROW уникален: пара (код, state) однозначно указывает место ошибки.
    DECLARE @ErrNoCounterRow     INT = 50001;  -- нет строки счётчика
    DECLARE @ErrOutOfRange       INT = 50002;  -- значение счётчика вне диапазона
    DECLARE @ErrBadFunction      INT = 50004;  -- fn_GenerateGS1SSCC вернула некорректный результат
    DECLARE @ErrCounterExhausted INT = 50005;  -- диапазон исчерпан, сброс не разрешён
    DECLARE @ErrInTransaction    INT = 50006;  -- вызов внутри внешней транзакции
    DECLARE @ErrBadConfig        INT = 50007;  -- неверные константы формата

    DECLARE @Wrap     BIT = ISNULL(@AllowWrapAround, 0),  -- NULL трактуется как запрет сброса
            @Serial   BIGINT,                             -- выданный серийный номер
            @Current  BIGINT,                             -- значение для диагностики отказа
            @RowCount INT,
            @SSCC17   NVARCHAR(17),
            @Result   NVARCHAR(25),                       -- тип возврата fn_GenerateGS1SSCC
            @Msg      NVARCHAR(2048);

    SET @SSCC = NULL;  -- результат появляется только после всех проверок

    -- 1. Внешняя транзакция. Проверка стоит до SET XACT_ABORT ON:
    --    судьбу своей транзакции при этой ошибке определяет вызывающий.
    IF @@TRANCOUNT > 0
        THROW @ErrInTransaction,
              N'sp_GetNextGS1SSCC: вызов внутри транзакции запрещён. Её откат вернул бы счётчик назад, и выданный SSCC был бы выдан повторно. Вызовите процедуру до BEGIN TRANSACTION.',
              1;

    SET XACT_ABORT ON;  -- runtime-ошибки прерывают выполнение и уходят вызывающему с исходным кодом

    -- В режиме IMPLICIT_TRANSACTIONS UPDATE сам открыл бы транзакцию и оставил её открытой
    -- у вызывающего. SET внутри процедуры действует только до её завершения.
    SET IMPLICIT_TRANSACTIONS OFF;

    -- 2. Константы формата. Проверяются до UPDATE: ошибка конфигурации не расходует номер.
    --    Сумма длин обязана быть 17, иначе параметр функции NVARCHAR(17) молча усечёт строку.
    IF @PrefixLength + @SerialLength <> @Sscc17Length
    BEGIN
        SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: длина префикса (', @PrefixLength,
                          N') + длина серийного номера (', @SerialLength,
                          N') должны давать ', @Sscc17Length, N'.');
        THROW @ErrBadConfig, @Msg, 2;
    END;

    -- Ровно @PrefixLength ASCII-цифр. LIKE с Unicode-аргументами учитывает хвостовые пробелы,
    -- бинарная коллация оставляет в [0-9] только ASCII-цифры
    IF ISNULL(@CompanyPrefix, N'') COLLATE Latin1_General_BIN2
       NOT LIKE REPLICATE(N'[0-9]', @PrefixLength)
    BEGIN
        SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: префикс компании ''', @CompanyPrefix,
                          N''' должен состоять ровно из ', @PrefixLength, N' цифр.');
        THROW @ErrBadConfig, @Msg, 3;
    END;

    -- 3. Получение номера одной инструкцией.
    --    Явной транзакции нет: UPDATE фиксируется сам и сразу отпускает строку,
    --    поэтому функция ниже вызывается уже без блокировки.
    --    Граница проверяется в WHERE: если номер выдать нельзя, строка не обновляется.
    --    Хинты фиксируют намерение; корректность обеспечивают атомарность UPDATE и PK по Id.
    UPDATE dbo.tbl_SSCC_Counter WITH (UPDLOCK, ROWLOCK)
    SET @Serial = LastGS1SSCC =               -- переменная получает значение ПОСЛЕ обновления
            CASE
                WHEN LastGS1SSCC < @MaxSerial THEN LastGS1SSCC + 1
                ELSE @MinSerial               -- только при @Wrap = 1, см. WHERE
            END
    WHERE Id = @CounterId
      AND LastGS1SSCC >= @MinSerial
      AND (LastGS1SSCC < @MaxSerial
           OR (LastGS1SSCC = @MaxSerial AND @Wrap = 1));

    SET @RowCount = @@ROWCOUNT;

    IF @RowCount = 0
    BEGIN
        -- Строка не обновлена; причину выясняем отдельным чтением.
        -- Если другой вызов успел изменить значение после нашего UPDATE,
        -- меняется только текст ошибки, но не уникальность.
        SELECT @Current = LastGS1SSCC
        FROM dbo.tbl_SSCC_Counter
        WHERE Id = @CounterId;

        IF @@ROWCOUNT = 0
        BEGIN
            SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: в dbo.tbl_SSCC_Counter нет строки с Id = ',
                              @CounterId, N'.');
            THROW @ErrNoCounterRow, @Msg, 4;
        END;

        IF @Current NOT BETWEEN @MinSerial AND @MaxSerial
        BEGIN
            SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: значение счётчика ', @Current,
                              N' вне диапазона ', @MinSerial, N'..', @MaxSerial, N'.');
            THROW @ErrOutOfRange, @Msg, 5;
        END;

        SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: диапазон серийных номеров исчерпан (', @MaxSerial,
                          N'). Сброс на ', @MinSerial, N' выполняется только при @AllowWrapAround = 1.');
        THROW @ErrCounterExhausted, @Msg, 6;
    END;

    -- 4. Префикс + серийный номер с ведущими нулями. Длина 17 гарантирована проверками выше.
    --    Номер уже зафиксирован: при ошибке ниже он пропускается, но повторно не выдаётся.
    SET @SSCC17 = @CompanyPrefix
                + RIGHT(REPLICATE(N'0', @SerialLength) + CONVERT(NVARCHAR(20), @Serial), @SerialLength);

    SET @Result = dbo.fn_GenerateGS1SSCC(@SSCC17);

    -- 5. Проверка до присвоения: NVARCHAR(25) в NVARCHAR(22) усекается молча.
    IF @Result IS NULL
    BEGIN
        SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: fn_GenerateGS1SSCC вернула NULL для ', @SSCC17,
                          N'. Серийный номер ', @Serial, N' пропущен.');
        THROW @ErrBadFunction, @Msg, 7;
    END;

    -- Ровно '(00)' + переданные 17 цифр + одна ASCII-цифра.
    -- DATALENGTH, в отличие от LEN, учитывает хвостовые пробелы.
    IF DATALENGTH(@Result) <> DATALENGTH(@AppId + @SSCC17 + N'0')
       OR @Result COLLATE Latin1_General_BIN2 NOT LIKE @AppId + @SSCC17 + N'[0-9]'
    BEGIN
        SET @Msg = CONCAT(N'sp_GetNextGS1SSCC: fn_GenerateGS1SSCC вернула некорректное значение для ',
                          @SSCC17, N': ''', @Result, N'''. Серийный номер ', @Serial, N' пропущен.');
        THROW @ErrBadFunction, @Msg, 8;
    END;

    SET @SSCC = @Result;  -- длина проверена: ровно 22 символа, без усечения
END;
GO

