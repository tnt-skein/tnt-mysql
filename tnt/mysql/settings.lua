--- Настройки драйвера MySQL: умолчания и проверка.
---
--- Набор ключей, узел, учётная запись, сроки, предел строк, пул
--- и повторы — общие у драйверов над роком и проверяются
--- в `tnt.storage.driver` (`driver.settings`) сразу, в `mysql.new`;
--- здесь — то, что знает только MySQL: шифрование, закреплённый ключ
--- сервера и потолок выборки.
---
--- Строки соединения здесь нет: рок передаёт узел, учётную запись, пароль
--- и базу коннектору отдельными аргументами, и пароль с кавычкой входит
--- как есть.
---
--- **Шифрование — только со сверкой сертификата по корню из настроек.**
--- Коннектор без сверки на сервере без TLS — или за посредником,
--- вычеркнувшим TLS из приветствия, — молча идёт открытым текстом и шлёт
--- пароль как есть, а без корня после неудачной сверки продолжает вход.
--- Поэтому `tls` — таблица с обязательным `ca`, а `true` — исключение.
---
--- **Ключ сервера** (`server_public_key`) — файл открытого ключа RSA.
--- Им полный вход `caching_sha2_password` без TLS шифрует пароль вместо
--- ключа, который сервер шлёт по тому же открытому соединению и который
--- посредник может подменить.

local driver = require('tnt.storage.driver')
local must = require('tnt.must')

local Module = {}

--- Имя драйвера (в журнале, в имени пула и ведре повторов) и порт
--- MySQL по умолчанию.
Module.DEFAULTS = { name = 'mysql', port = 3306 }

--- Уровень вины: строка того, кто завёл драйвер.
---
--- `check` зовёт `mysql.new` не хвостовым вызовом: уровень 2 — `new`,
--- 3 — строка вызывающего.
local OWNER = 3

--- Проверки с виной на строке того, кто завёл драйвер.
local owner = must.at(OWNER)

--- Как настройки называются в отказе.
local TITLE = 'настройки mysql'

--- Ключи настроек: общие у драйверов над роком и свой — ключ сервера.
---
--- Незнакомый ключ ловится здесь, а не в `driver.settings`: там список
--- в отказе назвал бы ключи без `server_public_key`, и тот, кто ошибся
--- в его имени, не увидел бы верного.
local OPTIONS = table.copy(driver.OPTIONS)

OPTIONS.server_public_key = '?not_empty'

--- Шифрование: корень, которым подписан сертификат сервера, и сертификат
--- клиента с его ключом.
local TLS = { ca = 'not_empty', cert = '?not_empty', key = '?not_empty' }

--- Бросок `tls = true`: корня коннектору не назвали.
local NO_ROOT = 'настройки mysql.tls: нужен файл корня, которым подписан сертификат сервера, — '
    .. "tls = { ca = 'ca.pem' }, docs/mysql.md"

---@class TntMysqlTlsOptions
---@field ca string Файл корня, которым подписан сертификат сервера
---@field cert string|nil Сертификат клиента; без key — файл, где есть и ключ
---@field key string|nil Ключ клиента; без cert — файл, где есть и сертификат

---@class TntMysqlOptions
---@field host string|nil Узел; по умолчанию 127.0.0.1
---@field port integer|nil Порт; по умолчанию 3306
---@field user string Учётная запись
---@field password string|nil Пароль
---@field db string База
---@field tls false|TntMysqlTlsOptions|nil Шифрование со сверкой сертификата; без него — открытый текст
---@field server_public_key string|nil Файл открытого ключа RSA сервера для входа без TLS
---@field timeout number|nil Срок вызова по умолчанию, секунд; 5
---@field max_timeout number|nil Потолок срока вызова и max_execution_time сервера, секунд; 60
---@field max_rows integer|nil Предел строк выборки; 10 000
---@field pool table|nil Настройки пула: size, wait_timeout, idle_timeout, max_lifetime и прочие `tnt-pool`
---@field retry table|nil Настройки повторов: attempts, base, factor, jitter, max
---@field name string|nil Имя драйвера в журнале; mysql

---@class TntMysqlSettings: TntStorageDriverSettings
---@field tls TntMysqlTlsOptions|nil Шифрование: копия проверенной настройки
---@field server_public_key string|nil Файл открытого ключа RSA сервера
---@field ceiling integer Потолок работы выборки на сервере, мс: max_execution_time

--- Проверяет настройки и дополняет их умолчаниями.
---@param opts TntMysqlOptions
---@return TntMysqlSettings
function Module.check(opts)
    owner.options(opts, TITLE, OPTIONS)

    local common = table.copy(opts)

    common.server_public_key = nil

    local checked = driver.settings(common, TITLE, Module.DEFAULTS, OWNER) --[[@as TntMysqlSettings]]
    local tls = opts.tls

    if tls == true then
        error(NO_ROOT, OWNER)
    end

    -- По типу, а не по истинности: `box.NULL` из настроек в YAML проверка
    -- ключей принимает за отсутствие, а в Lua он истинен, и рок получил бы
    -- его вместо таблицы и строки.
    if type(tls) == 'table' then
        owner.options(tls, TITLE .. '.tls', TLS)
        -- Копия, а не таблица вызывающего: её правка после `mysql.new`
        -- не должна менять вход драйвера.
        checked.tls = { ca = tls.ca, cert = tls.cert, key = tls.key }
    end

    if type(opts.server_public_key) == 'string' then
        checked.server_public_key = opts.server_public_key
    end

    -- Потолок брошенной выборки на сервере — в миллисекундах, округлённых
    -- вверх: ноль значил бы «без срока».
    checked.ceiling = math.ceil(checked.limits.max_timeout * 1000)

    return checked
end

return Module
