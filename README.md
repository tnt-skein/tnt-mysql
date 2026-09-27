# tnt-mysql

Драйвер MySQL для Tarantool: фасад над официальным неблокирующим роком
`mysql`. Соединения живут в пуле, срок один на вызов, отказ — пара
`nil, err` с родом по errno сервера, а транзакция держится на одном
соединении.

```lua
local mysql = require('tnt.mysql')

local db = mysql.new({ host = 'db', user = 'app', password = secret, db = 'app', pool = { size = 4 } })

local rows, err = db:query('select id, name from users where votes > ?', { n = 1, 100 })
local done, err = db:execute('insert into users (name) values (?)', { n = 1, 'Анна' })   -- done.last_id — новый ключ
```

Зависимости: `tnt-must` (бросок отказа рока как есть), `tnt-log` (журнал),
`tnt-pool` (соединения), `tnt-retry` (повторы), `tnt-sql` (диалект `mysql`
для построителя запросов) и `tnt-storage` (срок, отказ с родом, значения
и драйвер SQL над роком). Рок `mysql` — форк с починками, он ставится
отдельно: `make deps-mysql`.

## Зачем

У Tarantool есть официальный рок `mysql`, но он не знает срока,
отказывает строкой и в нескольких местах молча портит выдачу. Пакет
не пишет протокол заново, а доводит рок до драйвера, на который можно
положиться:

- **Форк рока с починками** (`rocks/mysql/`): код ошибки полем, число
  затронутых строк и новый ключ, отказ второго оператора, выдача
  подготовленного пути без обрезки, число в пределах своей длины, значения
  после NULL и `BIGINT UNSIGNED` без порчи, сборка на Tarantool 3.8
  и вход через `caching_sha2_password` — MySQL 8.4 с настройками
  по умолчанию и MySQL 9; своя zlib коннектора остаётся внутри драйвера
  и не мешает gzip соседних модулей; TLS со сверкой сертификата
  и закреплённый ключ сервера.
- **Срок один на вызов**: ответ рока ждётся в отдельном файбере, а брошенную
  выборку сервер снимает сам по `max_execution_time`.
- **Отказ — пара `nil, err` с родом** (`unreachable`, `denied`, `busy`,
  `timeout`, `broken`, `rejected`, `conflict`, `overflow`, `closed`),
  признаком отправки и приговором повтору; отказ входа не теряет смысла
  после очистки от тайн.
- **Повтор после отправки — только с `idempotent = true`**, транзакция —
  на одном соединении с откатом по отказу тела.
- **Шифрование — только со сверкой**: `tls = { ca }` сверяет сертификат
  сервера по корню, `server_public_key` закрепляет ключ RSA сервера для
  входа без TLS, и посредник пароля не прочтёт. Рок без этих починок —
  исключение при заведении: молча открытый текст хуже отказа.

## Установка

```sh
tt rocks install tnt-mysql --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-mysql.git
cd tnt-mysql && tt rocks make
```

Рок `mysql` в зависимостях не объявлен: выпуск `2.1.3` на Tarantool 3.8
не собирается. Форк с починками ставит `make deps-mysql` — нужны CMake,
компилятор и заголовки OpenSSL (`libssl-dev`); без рока `mysql.new`
бросает сразу и называет эту цель.

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `mysql.new(opts)` | заводит драйвер, соединений не открывает; негодная или незнакомая настройка — исключение |
| `db:query(sql, params, opts)` | выборка: массив записей по именам столбцов; NULL — отсутствующий ключ |
| `db:execute(sql, params, opts)` | оператор без выборки: `{ affected = n, last_id = id }` |
| `db:transaction(fn, opts)` | транзакция на одном соединении: `nil, err` тела — откат и пара |
| `db:stats()` | показатели пула без учётных данных |
| `db:close()` | закрывает пул: свободные соединения сразу, занятые — когда вернут |

Настройки драйвера: `host`, `port` (3306), `user` и `db` (обязательны),
`password`, `tls` (`{ ca, cert, key }` — TLS со сверкой сертификата
сервера), `server_public_key` (файл открытого ключа RSA сервера),
`timeout` и `max_timeout` (5 и 60 с; потолок — ещё
и `max_execution_time` выборки на сервере), `max_rows` (10 000), `pool`
и `retry` (как у `tnt-pool` и `tnt-retry`), `name`. `params` — массив
с полем `n`, чтобы `nil` посреди не терялся; пару текста и параметров
собирает `tnt-sql`.

```lua
local sql = require('tnt.sql')

local users = sql.table('users', { 'id', 'name', 'votes' })
local rows, err = db:query(users:select('id', 'name'):where('votes', '>', 100):build(db.dialect))

if err ~= nil and err.kind == 'conflict' then
    -- взаимоблокировка: повторяют всю транзакцию
end

local ok, err = db:transaction(function(tx)
    local _, failed = tx:execute('update users set votes = votes - 10 where id = ?', { n = 1, 1 })

    if failed ~= nil then
        return nil, failed
    end
end)
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
make deps-mysql    # форк рока mysql в .rocks для живых проверок: CMake, компилятор и libssl-dev
make mysql-up      # MySQL 8.4 с TLS в докере для живых проверок; make mysql-down — погасить
```

Покрытие строк — 100 %, убитых мутантов — 100 % (40 проверок, 64 мутанта
в двух модулях; в точке входа мутировать нечего). Фасад проверяется
двойником рока, сборка форка — по символам его драйвера, а пятнадцать
живых проверок идут против MySQL стенда с форком рока — 8.4 с настройками
по умолчанию и 9.7, с TLS и ключом сервера стенда; без рока или без
поднятого сервера они пропускаются.

## Документ

Полное описание с форком рока, настройками, значениями, отказами, сроком,
повторами, транзакциями, соединениями, журналом, шифрованием и ключом
сервера, подменой в проверках и обоснованием решений: [docs/mysql.md](docs/mysql.md).

## Лицензия

MIT.
