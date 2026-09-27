--- Что фасад знает о роке `mysql`: как войти, закрыть, проверить без сети,
--- позвать и прочесть отказ.
---
--- Всё прочее — пул, срок, повторы, транзакции, решение о соединении —
--- у драйверов над роком одно по договору `tnt-storage` и живёт
--- в `tnt.storage.driver`. Здесь — только то, чем рок `mysql` отличается.
---
--- * Вход — аргументами, пароль не экранируется. Сразу за входом
---   соединению ставится `max_execution_time`, равный потолку срока:
---   отменённый запрос дорабатывает на сервере, и выборку сервер снимет
---   сам не позже потолка. Прочие операторы потолка у MySQL не имеют.
--- * Шифрование и ключ сервера рок берёт с заплаты 0011 форка и говорит
---   об этом полем `features`. Рок без неё незнакомые ключи пропускает
---   молча и вошёл бы открытым текстом, поэтому настройка, которой рок
---   не знает, — исключение при заведении драйвера.
--- * Живость — `quote('')`: экранирует на клиенте, без сети, и бросает ровно
---   тогда, когда рок пометил соединение негодным. Открыта ли транзакция,
---   рок не говорит вовсе — её ведёт отметка фасада.
--- * Закрытие и вызов у роков `mysql` и `pg` одинаковы (`link.shut`,
---   `link.execute`): без параметров рок идёт простым путём, с параметрами —
---   подготовленным на сервере; выдача у обоих путей одна.
--- * Код отказа — errno полем `mysql_errno` у `box.error` форка рока;
---   рок без починки отказывает строкой, и род решают слова.
--- * Отказ входа «Access denied … (using password: YES)» `tnt-log.scrub`
---   принимает за пару с тайной и съедает хвост. Смысл скобки здесь
---   переводится в слово до `scrub`: тайны в ней нет, а «с паролем»
---   или «без пароля» — ровно то, что нужно знать о входе.
--- * Число строк и новый ключ — третье и четвёртое значения `execute`
---   у форка, `uint64`; числом — пока точны.

local fail = require('tnt.must.fail')
local failure = require('tnt.storage.failure')
local link = require('tnt.storage.link')

local Module = {}

--- Имя в начале текста отказа.
Module.LABEL = 'mysql'

--- Что сказать, если рока нет.
local HINT = 'поставьте форк с починками — make deps-mysql, docs/mysql.md'

--- Потолок работы выборки на сервере, мс.
local CEILING = 'SET SESSION max_execution_time = %d'

--- Уровень вины внутри `new`: 2 — `mysql.new`, 3 — строка вызывающего.
local OWNER = 3

--- Настройки, которые рок берёт только с заплатой 0011, и признаки
--- в `features` рока, которые о них говорят.
local NEEDS = { { 'tls', 'ssl' }, { 'server_public_key', 'server_public_key' } }

--- Бросок настройки, которую рок без заплаты 0011 молча пропустил бы.
local UNKNOWN = 'настройки mysql.%s: рок mysql собран без заплаты rocks/mysql/0011 и молча пропустил бы её — '
    .. 'пересоберите: make deps-mysql, docs/mysql.md'

--- Больше этого целое в double уже неточно.
local EXACT = 2 ^ 53

--- Что значит ответ MySQL о пароле во входе: скобка целиком и её слово.
local PASSWORD_SAID = {
    ['(using password: YES)'] = '(с паролем)',
    ['(using password: NO)'] = '(без пароля)',
}

---@class TntMysqlRockConn Соединение рока `mysql`
---@field conn { close: fun(self: any) } Объект драйвера рока: его `close` закрывает и оборванное
---@field execute fun(self: TntMysqlRockConn, sql: string, ...: any): table, boolean, any, any
---@field quote fun(self: TntMysqlRockConn, value: string): string
---@field close fun(self: TntMysqlRockConn): boolean

--- Рок `mysql` либо исключение: без рока драйвер не откроет ни одного
--- соединения.
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return table mysql
function Module.load(level)
    local mysql = link.require('mysql', HINT, level + 1)

    return mysql
end

--- Годно ли соединение — без сети. Открыта ли транзакция, рок не знает.
---@param conn TntMysqlRockConn
---@return boolean alive
function Module.state(conn)
    return (pcall(conn.quote, conn, ''))
end

--- errno отказа: его несёт `box.error` форка рока (поле `mysql_errno`).
---@param err any
---@return integer|nil
function Module.code(err)
    -- `box.error.is` в аннотациях ядра не описан.
    ---@diagnostic disable-next-line: undefined-field
    if box.error.is(err) then
        return err.mysql_errno
    end

    return nil
end

--- Текст отказа: без приписки места и со словом вместо ответа о пароле.
---
--- Сверяется скобка целиком: прочие скобки текста — «(36)» у отказа сети —
--- остаются как есть.
---@param err any
---@return string
function Module.text(err)
    return (failure.text(err):gsub('%b()', PASSWORD_SAID))
end

--- Счёт числом, пока он точен; дальше — как дал рок.
---@param count any uint64 либо nil
---@return any
local function exact(count)
    if count ~= nil and count <= EXACT then
        return tonumber(count)
    end

    return count
end

--- Ответ оператора без выборки: сколько строк затронуто и новый ключ
--- AUTO_INCREMENT (0 — ключа оператор не завёл). У рока без починки — пусто.
---@param _ table Наборы записей
---@param _ok boolean
---@param affected any
---@param last_id any
---@return { affected: any, last_id: any }
function Module.count(_, _ok, affected, last_id)
    return { affected = exact(affected), last_id = exact(last_id) }
end

--- Знание рока для `tnt.storage.driver`.
---
--- Настройка, которой рок не знает, — исключение на строке того, кто
--- завёл драйвер: шифрование, которое молча не включилось, хуже отказа.
---@param settings TntMysqlSettings
---@param mysql table Рок
---@return TntStorageRock
function Module.new(settings, mysql)
    local features = mysql.features or {}

    for _, need in ipairs(NEEDS) do
        if settings[need[1]] ~= nil and not features[need[2]] then
            error(UNKNOWN:format(need[1]), OWNER)
        end
    end

    return {
        label = Module.LABEL,
        where = settings.where,
        connect = function()
            local conn = mysql.connect({
                host = settings.host,
                port = settings.port,
                user = settings.user,
                password = settings.password,
                db = settings.db,
                ssl = settings.tls,
                server_public_key = settings.server_public_key,
            })
            local set, refused = pcall(conn.execute, conn, CEILING:format(settings.ceiling))

            -- Отказ уходит тем, что бросил рок: без своей приписки места,
            -- по нему решается род входа.
            if not set then
                link.shut(conn)
                fail.raise(refused)
            end

            return conn
        end,
        shut = link.shut,
        state = Module.state,
        execute = link.execute,
        code = Module.code,
        text = Module.text,
        count = Module.count,
    }
end

return Module
