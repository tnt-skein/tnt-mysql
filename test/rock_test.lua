--- Проверки знания рока `mysql`: рок по имени, вход аргументами, шифрование
--- и ключ сервера, рок без них, потолок выборки, живость по `quote('')`,
--- errno из отказа форка, слово вместо ответа о пароле, число строк и новый
--- ключ. Закрытие и вызов у обоих роков одни — их проверяет `tnt-storage`.

local ffi = require('ffi')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local rock_of = helper.rock_of

local g = t.group('tnt.mysql.rock')

--- Настройки соединения, как их отдаёт `settings.check`.
local SETTINGS = {
    host = 'h',
    port = 3306,
    user = 'app',
    password = "pa'ss",
    db = 'app',
    where = 'h:3306/app',
    ceiling = 1500,
}

g.after_each(function()
    helper.restore()
    package.loaded['mysql'] = nil
    package.preload['mysql'] = nil
end)

g.test_the_rock_is_required_by_name = function()
    local fake = helper.rock()

    package.loaded['mysql'] = fake
    t.assert_is(rock_of.load(1), fake)

    package.loaded['mysql'] = nil
    package.preload['mysql'] = function()
        error("module 'mysql' not found:\n\tno field package.preload['mysql']", 0)
    end

    helper.assert_blamed({
        {
            function()
                helper.mysql.new(table.copy(helper.LOGIN))
            end,
            "рок mysql не установлен (module 'mysql' not found:): "
                .. 'поставьте форк с починками — make deps-mysql, docs/mysql.md',
        },
    })
end

g.test_the_rock_is_known_to_the_driver = function()
    local rock = rock_of.new(SETTINGS, helper.rock())

    t.assert_equals(rock.label, 'mysql')
    t.assert_equals(rock.where, 'h:3306/app')
    t.assert_is(rock.shut, helper.link.shut)
    t.assert_is(rock.state, rock_of.state)
    t.assert_is(rock.execute, helper.link.execute)
    t.assert_is(rock.code, rock_of.code)
    t.assert_is(rock.text, rock_of.text)
    t.assert_is(rock.count, rock_of.count)
end

g.test_connect_hands_over_the_values_and_sets_the_ceiling = function()
    local fake = helper.rock()
    local conn = rock_of.new(SETTINGS, fake).connect()

    t.assert_is(conn, fake.conns[1])
    t.assert_equals(fake.logins_with, {
        { host = 'h', port = 3306, user = 'app', password = "pa'ss", db = 'app' },
    })
    t.assert_equals(fake.sent[1].sql, 'SET SESSION max_execution_time = 1500')
    t.assert_equals(fake.sent[1].args, { n = 0 })
    t.assert_equals(conn.closed, false)
end

g.test_connect_hands_over_tls_and_the_server_key = function()
    local fake = helper.rock()
    local secured = table.copy(SETTINGS)

    secured.tls = { ca = '/ca.pem', cert = '/client.pem' }
    secured.server_public_key = '/server.pub'
    rock_of.new(secured, fake).connect()

    t.assert_equals(fake.logins_with, {
        {
            host = 'h',
            port = 3306,
            user = 'app',
            password = "pa'ss",
            db = 'app',
            ssl = { ca = '/ca.pem', cert = '/client.pem' },
            server_public_key = '/server.pub',
        },
    })
end

g.test_a_rock_without_tls_is_refused_where_the_driver_is_made = function()
    local old = helper.rock()
    local half = helper.rock()
    local message = 'настройки mysql.%s: рок mysql собран без заплаты rocks/mysql/0011 и молча пропустил бы её — '
        .. 'пересоберите: make deps-mysql, docs/mysql.md'

    old.features = nil
    half.features = { ssl = true }

    -- Рок без заплаты пропустил бы незнакомые ключи молча и вошёл бы
    -- открытым текстом: отказ — при заведении, на строке заведшего.
    helper.install(old)
    helper.assert_blamed({
        {
            function()
                helper.mysql.new(helper.with({ tls = { ca = '/ca.pem' } }))
            end,
            message:format('tls'),
        },
    })
    helper.install(half)
    helper.assert_blamed({
        {
            function()
                helper.mysql.new(helper.with({ tls = { ca = '/ca.pem' }, server_public_key = '/server.pub' }))
            end,
            message:format('server_public_key'),
        },
    })

    -- Без шифрования и ключа рок годится любой.
    t.assert_equals(rock_of.new(SETTINGS, old).label, 'mysql')
    helper.install(old)

    local plain = helper.mysql.new(helper.with())

    t.assert_equals(plain.name, 'mysql')
    plain:close()
    t.assert_equals(rock_of.new(helper.settings.check(helper.with({ tls = { ca = '/ca.pem' } })), half).label, 'mysql')
end

g.test_a_refused_ceiling_is_raised_as_the_rock_raised_it = function()
    local fake = helper.rock(function()
        return { raise = '/x/mysql/init.lua:147: Unknown system variable' }
    end)
    local ok, err = pcall(rock_of.new(SETTINGS, fake).connect)

    t.assert_equals({ ok, err }, { false, '/x/mysql/init.lua:147: Unknown system variable' })
end

g.test_a_refused_ceiling_closes_the_conn_and_is_raised = function()
    local refused = helper.mysql_error('Access denied; you need the SYSTEM_VARIABLES_ADMIN privilege', 1227)
    local fake = helper.rock(function()
        return { raise = refused }
    end)
    local ok, err = pcall(rock_of.new(SETTINGS, fake).connect)

    t.assert_equals(ok, false)
    t.assert_is(err, refused)
    t.assert_equals(fake.conns[1].closed, true)
end

g.test_state_asks_quote_and_says_nothing_of_transactions = function()
    local fake = helper.rock()
    local conn = rock_of.new(SETTINGS, fake).connect()

    conn.open = true
    t.assert_equals(helper.pack(rock_of.state(conn)), { n = 1, true })

    conn.alive = false
    t.assert_equals(helper.pack(rock_of.state(conn)), { n = 1, false })
    t.assert_equals(#fake.sent, 1)
end

g.test_code_is_read_only_from_a_box_error = function()
    t.assert_equals(rock_of.code('Lost connection to MySQL server during query'), nil)
    t.assert_equals(rock_of.code(helper.mysql_error('x')), nil)
    t.assert_equals(rock_of.code(helper.mysql_error('x', 1213)), 1213)
end

g.test_text_tells_the_password_by_a_word = function()
    local denied = "/x/mysql/init.lua:274: Access denied for user 'app'@'172.17.0.1' (using password: %s)"

    t.assert_equals(rock_of.text(denied:format('YES')), "Access denied for user 'app'@'172.17.0.1' (с паролем)")
    t.assert_equals(
        rock_of.text(denied:format('NO')),
        "Access denied for user 'app'@'172.17.0.1' (без пароля)"
    )
    -- Незнакомый ответ остаётся как есть: угадывать его смысл незачем.
    t.assert_equals(
        rock_of.text(helper.mysql_error('Access denied (using password: MAYBE) (using password: YES)', 1045)),
        'Access denied (using password: MAYBE) (с паролем)'
    )
    t.assert_equals(rock_of.text('Duplicate entry'), 'Duplicate entry')
    t.assert_equals(
        rock_of.text("Can't connect to MySQL server on '127.0.0.1' (36)"),
        "Can't connect to MySQL server on '127.0.0.1' (36)"
    )
    t.assert_equals(rock_of.text('(using password: )'), '(using password: )')
end

g.test_count_is_a_number_while_exact = function()
    local big = ffi.cast('uint64_t', 2 ^ 53) + 1

    local small = rock_of.count({ {} }, true, ffi.cast('uint64_t', 3), ffi.cast('uint64_t', 0))

    t.assert_equals(small, { affected = 3, last_id = 0 })
    t.assert_equals({ type(small.affected), type(small.last_id) }, { 'number', 'number' })

    local exact = rock_of.count({ {} }, true, ffi.cast('uint64_t', 2 ^ 53), big)

    t.assert_equals(type(exact.affected), 'number')
    t.assert_equals(exact.affected, 2 ^ 53)
    t.assert_equals(tostring(exact.last_id), '9007199254740993ULL')
    t.assert_equals(type(exact.last_id), 'cdata')
    t.assert_equals(rock_of.count({ {} }, true), {})
end
