#!/usr/bin/env bash
# Полный прогон тестов dbo.sp_GetNextGS1SSCC:
# тестовая БД -> миграция схемы -> установка процедуры -> тесты -> конкурентный тест -> автопроверка.
# Нужен запущенный контейнер SQL Server, в котором корень репозитория смонтирован в /work.
# Пароль sa берётся из MSSQL_SA_PASSWORD или из окружения контейнера; в репозитории его нет.
set -euo pipefail

CONTAINER="${MSSQL_CONTAINER:-mssql}"
WORKDIR="${MSSQL_WORKDIR:-/work}"   # путь к репозиторию внутри контейнера
DB="SSCC_Test"
SESSIONS="${SESSIONS:-8}"            # параллельных сессий
CALLS="${CALLS:-250}"                # вызовов в каждой сессии
EXPECTED=$((SESSIONS * CALLS))
MIGRATION="$WORKDIR/sql/dbo.tbl_SSCC_Counter_constraints.sql"

R0=00_migration.txt
R1=01_counter_and_errors.txt
R2=02_function_failures.txt
R3=03_concurrency.txt

cd "$(dirname "$0")/.."
mkdir -p results

PASSWORD="${MSSQL_SA_PASSWORD:-$(docker exec "$CONTAINER" sh -c 'printf %s "${MSSQL_SA_PASSWORD:-$SA_PASSWORD}"')}"
if [ -z "$PASSWORD" ]; then
  echo "Не найден пароль sa: задайте MSSQL_SA_PASSWORD" >&2
  exit 1
fi

SQLCMD="$(docker exec "$CONTAINER" sh -c 'for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do [ -x "$p" ] && { echo "$p"; exit 0; }; done; exit 1')" \
  || { echo "В контейнере не найден sqlcmd" >&2; exit 1; }

# Пароль передаётся через переменную окружения, а не аргументом командной строки
run_sql() {
  docker exec -e SQLCMDPASSWORD="$PASSWORD" "$CONTAINER" \
    "$SQLCMD" -S localhost -U sa -C -b -W "$@"
}

echo "== Ожидание SQL Server"
for _ in $(seq 1 30); do
  run_sql -Q "SELECT 1" > /dev/null 2>&1 && break
  sleep 2
done

echo "== Окружение"
run_sql -h -1 -Q "SET NOCOUNT ON; SELECT @@VERSION;" | tee results/00_environment.txt

echo "== Тестовая БД и заглушки функций"
run_sql -i "$WORKDIR/tests/00_setup_stubs.sql"

echo "== Миграция схемы"
: > "results/$R0"

# Отказ при двух строках: ожидается 50101, таблица не меняется
run_sql -d "$DB" -Q "SET NOCOUNT ON; INSERT INTO dbo.tbl_SSCC_Counter DEFAULT VALUES;"
run_sql -d "$DB" -i "$MIGRATION" >> "results/$R0" 2>&1 || true
run_sql -d "$DB" -h -1 -Q "SET NOCOUNT ON;
SELECT 'after two rows', COUNT(*), ISNULL(COL_LENGTH('dbo.tbl_SSCC_Counter', 'Id'), 0) FROM dbo.tbl_SSCC_Counter;
DELETE TOP (1) FROM dbo.tbl_SSCC_Counter;" >> "results/$R0"

# Отказ при значении вне диапазона: ожидается 50102, таблица не меняется
run_sql -d "$DB" -Q "SET NOCOUNT ON; UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = -5;"
run_sql -d "$DB" -i "$MIGRATION" >> "results/$R0" 2>&1 || true
run_sql -d "$DB" -h -1 -Q "SET NOCOUNT ON;
SELECT 'after bad value', MAX(LastGS1SSCC), ISNULL(COL_LENGTH('dbo.tbl_SSCC_Counter', 'Id'), 0) FROM dbo.tbl_SSCC_Counter;
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0;" >> "results/$R0"

# Корректные данные: миграция применяется, повторный запуск ничего не меняет
run_sql -d "$DB" -i "$MIGRATION"
run_sql -d "$DB" -i "$MIGRATION"
run_sql -d "$DB" -h -1 -Q "SET NOCOUNT ON;
SELECT 'migrated', COUNT(*), MAX(Id), MAX(LastGS1SSCC),
       (SELECT COUNT(*) FROM sys.check_constraints
        WHERE parent_object_id = OBJECT_ID('dbo.tbl_SSCC_Counter')
          AND is_disabled = 0 AND is_not_trusted = 0)
FROM dbo.tbl_SSCC_Counter;" >> "results/$R0"

echo "== Установка процедуры"
run_sql -d "$DB" -i "$WORKDIR/sql/dbo.sp_GetNextGS1SSCC.sql"

echo "== Номера, граница, схема, внешняя транзакция"
run_sql -i "$WORKDIR/tests/01_counter_and_errors.sql" | tee "results/$R1"

echo "== Сбой функции"
run_sql -i "$WORKDIR/tests/02_function_failures.sql" | tee "results/$R2"

echo "== Конкурентный доступ: $SESSIONS сессий x $CALLS вызовов"
run_sql -d "$DB" -Q "SET NOCOUNT ON; DROP TABLE IF EXISTS dbo.tbl_SSCC_TestLog; CREATE TABLE dbo.tbl_SSCC_TestLog (SSCC NVARCHAR(22) NOT NULL); UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;"
pids=()
for _ in $(seq 1 "$SESSIONS"); do
  run_sql -d "$DB" -Q "SET NOCOUNT ON; DECLARE @s NVARCHAR(22), @i INT = 0; WHILE @i < $CALLS BEGIN EXEC dbo.sp_GetNextGS1SSCC @SSCC = @s OUTPUT; INSERT dbo.tbl_SSCC_TestLog (SSCC) VALUES (@s); SET @i += 1; END;" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done

run_sql -d "$DB" -Q "SET NOCOUNT ON;
WITH s AS (SELECT SSCC, CAST(SUBSTRING(SSCC, 13, 9) AS BIGINT) AS Serial FROM dbo.tbl_SSCC_TestLog)
SELECT COUNT(*) AS Total, COUNT(DISTINCT SSCC) AS Uniq, MIN(Serial) AS MinSerial, MAX(Serial) AS MaxSerial,
       CASE WHEN COUNT(*) = $EXPECTED AND COUNT(DISTINCT SSCC) = $EXPECTED
             AND MIN(Serial) = 1 AND MAX(Serial) = $EXPECTED
            THEN 'PASS' ELSE 'FAIL' END AS Result
FROM s;
DROP TABLE dbo.tbl_SSCC_TestLog;
UPDATE dbo.tbl_SSCC_Counter SET LastGS1SSCC = 0 WHERE Id = 1;" | tee "results/$R3"

echo "== Автопроверка"
: > results/summary.txt
FAILED=0
check() {
  local status="PASS"
  grep -Eq -- "$2" "results/$1" || { status="FAIL"; FAILED=1; }
  printf '%s  %s\n' "$status" "$3" | tee -a results/summary.txt
}

check $R0 'Msg 50101'                                        'Миграция отклонена при двух строках -> 50101'
check $R0 '^after two rows +2 +0 *$'                         'После отказа таблица не изменена'
check $R0 'Msg 50102'                                        'Миграция отклонена при значении вне диапазона -> 50102'
check $R0 '^after bad value +-5 +0 *$'                       'После отказа значение и схема не изменены'
check $R0 '^migrated +1 +1 +0 +2 *$'                         'Миграция применена, повторный запуск ничего не меняет'

check $R1 '^@SSCC +nvarchar +44'                             'Выходной параметр NVARCHAR(22): 44 байта'
check $R1 '^serial 1 +\(00\)546025410000000016 +22 +44'      'Серийный номер 1: 22 символа, без хвостовых пробелов'
check $R1 '^serial 2 +\(00\)546025410000000023 +22 +44'      'Серийный номер 2'
check $R1 '^serial 3 +\(00\)546025410000000030 +22 +44'      'Серийный номер 3'
check $R1 '^serial max +\(00\)546025419999999998'            'Верхняя граница 999 999 999'
check $R1 '^overflow +50005 +999999999 '                     'Переполнение без разрешения -> 50005, счётчик не изменён'
check $R1 '^after reset +\(00\)546025410000000009 +0'        'Сброс на 0 при @AllowWrapAround = 1'
check $R1 '^range check +547 *$'                             'CHECK диапазона отклоняет запись -5'
check $R1 '^invalid value +50002 +-5 '                       'Значение вне диапазона (CHECK отключён) -> 50002'
check $R1 '^no row +50001 '                                  'Нет строки счётчика -> 50001'
check $R1 '^second row same id +2627 *$'                     'Вторая строка с Id = 1 отклонена PK'
check $R1 '^second row other id +547 *$'                     'Вторая строка с Id = 2 отклонена CHECK'
check $R1 '^in transaction +50006 +1 +0 '                    'Вызов в транзакции -> 50006, транзакция вызывающего фиксируема, счётчик не изменён'
check $R1 '^implicit tran +\(00\)546025410000000016 +0 +2 *$' 'IMPLICIT_TRANSACTIONS: транзакция не оставлена, режим восстановлен'
check $R1 '^counter rows +1 +0 *$'                           'Счётчик восстановлен'

check $R2 '^fn NULL +50004 +1 '                              'Функция вернула NULL -> 50004, номер пропущен'
check $R2 '^fn trailing space +50004 +2 '                    'Функция вернула хвостовой пробел -> 50004, номер пропущен'
check $R2 '^fn runtime error +8134 +3 '                      'Runtime-ошибка функции проброшена (8134), номер пропущен'
check $R2 '^fn non-digit +50004 +4 '                         'Функция вернула нецифровую контрольную цифру -> 50004, номер пропущен'
check $R2 '^stub restored +\(00\)546025410000000016 *$'      'Заглушка восстановлена после подмен'
check $R2 '^after failures +4 +\(00\)546025410000000054 *$'  'После сбоев выдаётся следующий номер, повторов нет'

check $R3 ' PASS *$'                                         "Конкурентность: $EXPECTED уникальных номеров без пропусков"

if [ "$FAILED" -eq 0 ]; then
  echo "Все проверки пройдены" | tee -a results/summary.txt
else
  echo "Есть непройденные проверки" | tee -a results/summary.txt
  exit 1
fi

