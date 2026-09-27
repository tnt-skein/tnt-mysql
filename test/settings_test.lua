--- Проверки настроек: умолчания, потолок выборки, шифрование с корнем
--- и ключ сервера, отказ негодной настройки на строке того, кто завёл
--- драйвер.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local mysql = helper.mysql
local settings = helper.settings

local g = t.group('tnt.mysql.settings')

--- Проверка настроек на глубине `new` и уборка за проверкой.
local check = helper.checking(g)

--- Настройки входа и поверх них данные.
local with = helper.with

g.test_defaults = function()
    t.assert_equals(check({ user = 'app', db = 'shop' }), {
        name = 'mysql',
        host = '127.0.0.1',
        port = 3306,
        user = 'app',
        db = 'shop',
        where = '127.0.0.1:3306/shop',
        ceiling = 60000,
        limits = { timeout = 5, max_timeout = 60 },
        max_rows = 10000,
        pool = {},
        retry = {},
    })
    t.assert_equals(settings.DEFAULTS, { name = 'mysql', port = 3306 })
end

g.test_values_are_kept_as_given = function()
    local checked = check({
        host = 'db.local',
        port = 3307,
        user = "o'neil",
        password = [[pa'ss\word]],
        db = 'app db',
        max_timeout = 0.3,
        timeout = 0.2,
        max_rows = 5,
        name = 'orders',
        pool = { size = 2 },
        retry = { attempts = 4 },
        tls = { ca = '/etc/mysql/ca.pem', cert = '/etc/mysql/client.pem', key = '/etc/mysql/client.key' },
        server_public_key = '/etc/mysql/server.pub',
    })

    t.assert_equals(checked, {
        name = 'orders',
        host = 'db.local',
        port = 3307,
        user = "o'neil",
        password = [[pa'ss\word]],
        db = 'app db',
        where = 'db.local:3307/app db',
        ceiling = 300,
        limits = { timeout = 0.2, max_timeout = 0.3 },
        max_rows = 5,
        pool = { size = 2 },
        retry = { attempts = 4 },
        tls = { ca = '/etc/mysql/ca.pem', cert = '/etc/mysql/client.pem', key = '/etc/mysql/client.key' },
        server_public_key = '/etc/mysql/server.pub',
    })
end

g.test_tls_is_a_copy_and_false_is_plain_text = function()
    local tls = { ca = '/ca.pem' }
    local checked = check(with({ tls = tls }))

    -- Правка таблицы вызывающего после заведения входа не меняет.
    tls.ca = '/other.pem'
    tls.cert = '/client.pem'
    t.assert_equals(checked.tls, { ca = '/ca.pem' })

    local plain = check(with({ tls = false }))
    -- Пустое значение из YAML — `box.NULL`: проверка ключей берёт его
    -- за отсутствие, и до рока оно не доходит.
    local empty = check(with({ tls = box.NULL, server_public_key = box.NULL }))

    t.assert_equals({ rawequal(plain.tls, nil), rawequal(plain.server_public_key, nil) }, { true, true })
    t.assert_equals({ rawequal(empty.tls, nil), rawequal(empty.server_public_key, nil) }, { true, true })
end

g.test_the_ceiling_is_rounded_up_to_a_millisecond = function()
    t.assert_equals(check(with({ timeout = 1, max_timeout = 1.0001 })).ceiling, 1001)
end

g.test_wrong_settings_blame_the_caller = function()
    -- Общие ключи проверяет `tnt-storage`; здесь — что вина идёт
    -- на строку заведшего и через `mysql.new`, свои ключи и отказы `tls`.
    helper.assert_blamed({
        {
            function()
                mysql.new({ user = 'app' })
            end,
            'настройки mysql.db — непустая строка, а не nil',
        },
        {
            function()
                mysql.new(with({ pasword = 'x' }))
            end,
            'настройки mysql: ключа «pasword» нет, есть db, host, max_rows, max_timeout, name, password, '
                .. 'pool, port, retry, server_public_key, timeout, tls, user',
        },
        {
            function()
                mysql.new(with({ tls = true }))
            end,
            'настройки mysql.tls: нужен файл корня, которым подписан сертификат сервера, — '
                .. "tls = { ca = 'ca.pem' }, docs/mysql.md",
        },
        {
            function()
                mysql.new(with({ tls = {} }))
            end,
            'настройки mysql.tls.ca — непустая строка, а не nil',
        },
        {
            function()
                mysql.new(with({ tls = { ca = '/ca.pem', mode = 'verify-full' } }))
            end,
            'настройки mysql.tls: ключа «mode» нет, есть ca, cert, key',
        },
        {
            function()
                mysql.new(with({ tls = { ca = '/ca.pem', key = '' } }))
            end,
            'настройки mysql.tls.key — непустая строка, а не пустая',
        },
        {
            function()
                mysql.new(with({ tls = 'yes' }))
            end,
            'настройки mysql.tls — логическое значение или таблица, а не «yes»',
        },
        {
            function()
                mysql.new(with({ server_public_key = 5 }))
            end,
            'настройки mysql.server_public_key — непустая строка, а не число',
        },
        {
            function()
                mysql.new(with({ retry = { attempts = 0 } }))
            end,
            'настройки повторов: настройка attempts — целое число от 1, а пришло: 0',
        },
    })
end
