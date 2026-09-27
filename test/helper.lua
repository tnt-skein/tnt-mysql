--- Общие средства проверок драйвера MySQL.
---
--- Двойник здесь — не сервер, а рок `mysql`: фасад разговаривает с роком,
--- а не с протоколом, и всё, что он решает, — по тому, что рок вернул,
--- бросил и ответил `quote('')`. Двойник повторяет договор форка рока:
--- `execute` отдаёт наборы записей, `true`, число строк и новый ключ
--- (`uint64`), отказывает броском — `box.error` с полем `mysql_errno`,
--- `quote` и `close` бросают на негодном соединении, об открытой
--- транзакции рок не говорит ничего. Ожидание — настоящий `fiber.sleep`.
--- Поведение настоящего MySQL проверяет `mysql_live_test.lua`. Общее
--- для драйверов над роком — пул, срок, повторы, транзакции — проверяет
--- `tnt-storage` своим двойником; здесь — то, что знает только этот рок,
--- и фасад насквозь.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.log`, `tnt.pool`, `tnt.retry`, `tnt.sql`,
--- `tnt.storage` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников и ловушка журнала —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место. Двойник рока `test/fake_rock.lua` — общий у драйверов над
--- роком и приходит из проверок `tnt-storage` (`test/storage.lua`).
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local ffi = require('ffi')
local fio = require('fio')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

local fake_rock = dofile('test/fake_rock.lua')

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.mysql.settings', path = 'tnt/mysql/settings.lua' },
        { name = 'tnt.mysql.rock', path = 'tnt/mysql/rock.lua' },
        { name = 'tnt.mysql', path = 'tnt/mysql.lua' },
    },
}

--- Фасад пакета из исходников.
helper.mysql = testing.load_sources(helper.MODULES, 'tnt.mysql')

-- Части пакета берутся из той же загрузки, что и фасад: взятые `require`,
-- они пришли бы установленной копией из `.rocks`. Общее для драйверов
-- и построитель запросов — зависимости, и они те же, что зовёт пакет.
helper.settings = testing.module('tnt.mysql.settings')
helper.rock_of = testing.module('tnt.mysql.rock')
helper.storage = require('tnt.storage')
helper.sql = require('tnt.sql')

--- Отказ с кодом, как его бросает форк рока: `box.error` с полем
--- `mysql_errno`.
---@param reason string
---@param code integer|nil
---@return any
function helper.mysql_error(reason, code)
    -- `box.error.new` в аннотациях ядра может быть пуст; в Tarantool он есть всегда.
    ---@diagnostic disable-next-line: need-check-nil
    return box.error.new({ type = 'MySQLError', reason = reason, mysql_errno = code })
end

---@class TntMysqlFakeConn: TntStorageFakeConn Соединение двойника рока
---@field shut boolean Закрыт ли объект драйвера
---@field conn table Объект драйвера с `close`

---@class TntMysqlFakeRock: TntStorageFakeLog Двойник рока `mysql`
---@field connect fun(opts: table): TntMysqlFakeConn
---@field logins_with table[] Аргументы входа по порядку
---@field conns TntMysqlFakeConn[] Открытые соединения
---@field features table|nil Что рок берёт сверх узла и учётки: ssl, server_public_key

--- Двойник рока `mysql`.
---
--- `respond(sql, args, conn)` отвечает на оператор таблицей
--- `TntStorageFakeAnswer`: `affected` и `last_id` уходят `uint64`, как
--- у форка. Потолок `max_execution_time` за входом двойник записывает,
--- как всё, а `statements` его пропускает. `login(number)` решает вход.
--- `features` — как у форка с заплатой 0011: шифрование и ключ сервера
--- рок берёт; проверка рока без них ставит своё.
---@param respond (fun(sql: string, args: table, conn: TntStorageFakeConn): TntStorageFakeAnswer|nil)|nil
---@param login (fun(number: integer): table|nil)|nil
---@return TntMysqlFakeRock
function helper.rock(respond, login)
    ---@type TntMysqlFakeRock
    local rock = { ---@diagnostic disable-line: missing-fields
        logins_with = {},
        conns = {},
        sent = {},
        logins = 0,
        features = { ssl = true, server_public_key = true },
    }

    -- Двойник, а не класс: поля соединения ставятся на входе.
    ---@type any
    local Conn = {}

    function Conn:execute(sql, ...)
        local answer = fake_rock.execute(rock, respond, self, sql, fake_rock.pack(...))
        local affected, last_id = answer.affected, answer.last_id

        if affected ~= nil then
            affected = ffi.cast('uint64_t', affected)
        end

        return { answer.rows }, true, affected, ffi.cast('uint64_t', last_id or 0)
    end

    function Conn:quote(value)
        if self.closed or not self.alive then
            error('Connection is broken', 0)
        end

        return value
    end

    Conn.close = fake_rock.close

    Conn.__index = Conn

    rock.connect = function(opts)
        table.insert(rock.logins_with, opts)

        return fake_rock.open(rock, login, Conn)
    end

    return rock
end

--- Операторы, которые дошли до рока, без потолка на входе.
---@param rock TntMysqlFakeRock
---@return string[]
function helper.statements(rock)
    local list = {}

    for _, text in ipairs(fake_rock.statements(rock)) do
        if not text:find('^SET SESSION max_execution_time') then
            table.insert(list, text)
        end
    end

    return list
end

--- Почему рок `mysql` нельзя взять проверкам над настоящим роком; можно —
--- пусто, и рок загружен. Собран ли он по заплатам дерева, сверяется
--- до загрузки (`test/fork.lua`).
helper.unusable_rock = dofile('test/fork.lua').unusable

--- Отмена вызывающего посреди ожидания.
helper.cancelled = fake_rock.cancelled

--- Каталог стенда, общий на машину: туда `test/stand/mysql.sh` кладёт
--- сертификаты и ключ сервера контейнера с этим именем.
---
--- Контейнер стенда один на машину, а рабочих копий репозитория бывает
--- несколько, и копия, поднявшая его, уходит раньше контейнера.
--- Сертификаты и ключ в каталоге самой копии видела бы только она:
--- остальные копии пропускали бы проверки TLS и ключа, а копия со старыми
--- сертификатами после чужого подъёма падала бы на рукопожатии.
---@param container string Имя контейнера стенда
---@return string
function helper.stand_directory(container)
    return fio.pathjoin('/tmp/tnt-stand', container)
end

--- Ловушка журнала на время проверки: отказ входа виден и записью.
helper.capture_log = testing.capture_log

--- Чтение окружения для настроек живых проверок: порт стенда.
---
--- `tnt-env` приходит из `.rocks`: сам пакет окружения не читает,
--- и его зависимостью он не объявлен — его ставит `make deps`.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Обвязка: `install`, `restore`, `client(rock, opts)` и `suite(g)`.
fake_rock.harness(helper, function(given)
    local client = helper.mysql.new(given)

    return client
end)

return helper
