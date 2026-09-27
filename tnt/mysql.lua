--- MySQL по договору драйвера хранилища: фасад над роком `mysql`, пул,
--- срок, повторы, транзакции и отказ парой.
---
---     local mysql = require('tnt.mysql')
---     local sql = require('tnt.sql')
---
---     local db = mysql.new({ host = 'db', user = 'app', password = secret, db = 'app' })
---     local users = sql.table('users', { 'id', 'name' })
---
---     local rows, err = db:query(users:select('id', 'name'):where('id', '=', 7):build(db.dialect))
---     local done, err = db:execute('insert into users (name) values (?)', { n = 1, 'Анна' })
---     -- done.affected == 1, done.last_id — новый ключ AUTO_INCREMENT
---
---     local ok, err = db:transaction(function(tx)
---         local _, failed = tx:execute('insert into log (id) values (?)', { n = 1, 1 })
---
---         if failed ~= nil then
---             return nil, failed
---         end
---     end)
---
---     db:close()
---
--- Протокол не свой: у Tarantool есть официальный неблокирующий рок
--- `mysql`, и фасад приводит его к договору драйверов `tnt-storage`,
--- а не пишет MySQL заново. Рок — форк с починками: код ошибки полем,
--- отказ второго оператора, выдача подготовленного пути без обрезки,
--- число в пределах его длины, значения после NULL, число строк и новый
--- ключ, сборка на Tarantool 3.8, вход через `caching_sha2_password`,
--- TLS со сверкой сертификата и закреплённый ключ сервера
--- (`make deps-mysql`). Сервер — MySQL 8.4 или 9: у обоих это вход
--- по умолчанию, а `mysql_native_password` в 9 убран.
---
--- Решения, которые стоит знать заранее:
---
--- * **Отказ — пара `nil, err`**, где `err` — `TntStorageFailure` с родом
---   (`tnt-storage`). Исключение — только ошибка программиста: негодные
---   аргументы, незнакомый ключ, значение, которое нельзя передать,
---   `tls` без корня, настройка, которой рок без заплаты 0011 не знает.
--- * **Шифрование — только со сверкой**: `tls = { ca }` сверяет сертификат
---   сервера по корню, `server_public_key` закрепляет ключ RSA сервера
---   для входа без TLS; без них — открытый текст.
--- * **Срок один на вызов**, умолчание 5 с: ожидание пула, вход, ответ,
---   откат и паузы повторов — остатки одного мига. Ответ ждётся
---   в работнике: у рока срока нет. Брошенную выборку сервер снимает сам
---   по `max_execution_time`, равному потолку `max_timeout`; прочие
---   операторы дорабатывают до конца.
--- * **Повтор после отправки — только с `idempotent = true`**: обрыв
---   до отправки от обрыва после по тексту не отличить.
--- * **Вход — пара `sql, params`**, `params` — массив с полем `n`. Текст
---   собирает `tnt-sql` (`build(db.dialect)`), драйвер его не разбирает;
---   отказ сборки (`nil, err`) проходит насквозь той же парой.
--- * **Транзакция — `transaction(fn)`** на одном соединении: тело вернуло
---   `nil, err` — откат и пара; бросило — выброс соединения и исключение
---   дальше; первый отказ оператора помечает транзакцию, фиксации не будет.
---   Открыта ли транзакция, рок не говорит: `BEGIN` текстом через
---   `execute` — ошибка программиста, которую драйвер не увидит.
---
--- Пул, срок, повторы, транзакции и отказ у MySQL и PostgreSQL одни
--- по договору и живут в `tnt.storage.driver`; здесь — настройки
--- (`tnt.mysql.settings`) и знание рока `mysql` (`tnt.mysql.rock`).
---
--- Подробно — `docs/mysql.md`.

local driver = require('tnt.storage.driver')
local rock = require('tnt.mysql.rock')
local settings = require('tnt.mysql.settings')
local sql_dialect = require('tnt.sql.dialect')
local value = require('tnt.storage.value')

---@class TntMysqlClient: TntStorageDriver

return {
    --- Заводит драйвер. Соединений не открывает: первое откроет первый вызов.
    ---@type fun(opts: TntMysqlOptions): TntMysqlClient
    new = driver.facade({
        dialect = sql_dialect.explain(value.MYSQL) --[[@as table]],
        check = settings.check,
        rock = rock,
        log = require('tnt.log').new('tnt.mysql'),
        pool = require('tnt.pool'),
        retry = require('tnt.retry'),
    }),
}
