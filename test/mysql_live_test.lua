--- Живые проверки драйвера против настоящего MySQL стенда
--- (`test/stand/mysql.sh`, `make mysql-up`).
---
--- Двойник рока показывает, что фасад верно понимает рок; здесь — что
--- форк рока и сервер ведут себя так, как фасад думает: errno и счёт строк,
--- значения после NULL, выдача подготовленного пути без обрезки, число
--- во всю длину столбца, `false` столбца `boolean`, где бы ни лёг его
--- буфер, отказ второго оператора, срок и потолок выборки,
--- сеанс, убитый посреди запроса, взаимоблокировка, пароль с кавычкой,
--- отказ входа словом, вход через `caching_sha2_password` — ключом RSA
--- без TLS и по кэшу сервера, — TLS со сверкой по корню стенда и отказ
--- с чужим корнем, вход с закреплённым ключом сервера и отказ с чужим.
---
--- Без рока `mysql` (`make deps-mysql`), на роке, собранном не по заплатам
--- дерева, или без поднятого стенда проверки пропускаются, а не падают:
--- гейты от докера не зависят. Проверки шифрования и ключа пропускаются
--- ещё и на стенде, поднятом без сертификатов и ключа из его каталога.

local clock = require('clock')
local datetime = require('datetime')
local decimal = require('decimal')
local ffi = require('ffi')
local fiber = require('fiber')
local fio = require('fio')
local popen = require('popen')
local t = require('luatest')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local mysql = helper.mysql

local g = t.group('tnt.mysql.live')

--- Куча glibc, которую двигает проверка короткого значения. Имена свои,
--- а на функции libc они ведут через `__asm__`: объявление с именем
--- `malloc` уронило бы `ffi.cdef` соседа, объявившего его иначе, —
--- «attempt to redefine».
if not pcall(function()
    return ffi.C.tnt_mysql_live_malloc
end) then
    ffi.cdef([[
        void *tnt_mysql_live_malloc(size_t size) __asm__("malloc");
        void tnt_mysql_live_free(void *pointer) __asm__("free");
    ]])
end

--- Окружение стенда — через `tnt-env`: мимо него окружение не читают.
local env = helper.stand_env()

--- Порт стенда.
local PORT = env.int('STAND_MYSQL_PORT', 13306)

--- Корень TLS и открытый ключ RSA стенда: в общем на машину каталоге
--- контейнера, как и сам контейнер (`test/stand/mysql.sh`).
local CONTAINER = env.string('STAND_MYSQL_CONTAINER', 'tnt-stand-mysql')
local STAND_DIR = env.string('MYSQL_TLS_DIR', helper.stand_directory(CONTAINER))
local CA = fio.pathjoin(STAND_DIR, 'ca.pem')
local PUBLIC_KEY = fio.pathjoin(STAND_DIR, 'public_key.pem')

--- Учётки стенда: пароль `app` — с кавычкой и обратной чертой нарочно.
local ACCOUNTS = {
    app = "app'se\\cret",
    reader = 'reader-secret',
    root = 'root-secret',
}

--- Таблица проверок — своя у каждого прогона. Стенд один на машину,
--- а проверки идут разом из нескольких рабочих копий дерева: общую
--- таблицу соседний прогон сносил бы и заводил заново посреди этого.
local TABLE = 'live_rows_' .. uuid.str():sub(1, 8)

--- Сколько раз проверка короткого значения читает его, каждый раз
--- с кучей, сдвинутой по-своему: рок без заплаты 0008 ошибался
--- на десятках чтений из 2000 — в каждом прогоне.
local SHORT_READS = 2000

--- Сдвигает кучу glibc перед чтением: берёт несколько мелких кусков
--- и вразнобой отпускает часть взятых раньше. Мелкий буфер рока ложится
--- тогда на другое место, и за ним оказывается другой байт.
---@param round integer Номер чтения: от него — сколько взять и отпустить
---@param held ffi.cdata*[] Взятые куски; отпускает их вызывающий
local function shake_heap(round, held)
    for _ = 1, 1 + round % 7 do
        table.insert(held, ffi.C.tnt_mysql_live_malloc(1 + round * 5 % 24))
    end

    for step = 1, math.min(round % 8, #held) do
        ffi.C.tnt_mysql_live_free(table.remove(held, (round * 13 + step) % #held + 1))
    end
end

--- Драйвер к стенду под учёткой.
---@param user string
---@param extra table|nil
---@return any
local function open(user, extra)
    local given = { port = PORT, user = user, password = ACCOUNTS[user], db = 'app', timeout = 2 }

    for key, value in pairs(extra or {}) do
        given[key] = value
    end

    return mysql.new(given)
end

--- Почему живые проверки не идут; идут — пусто.
---
--- Рок, собранный не по заплатам дерева, проверки не гоняют и не грузят:
--- они падали бы на том, что чинит заплата, а сама загрузка такого рока
--- роняла gzip соседних наборов прогона (`helper.unusable_rock`).
---@return string|nil
local function unavailable()
    local unusable = helper.unusable_rock()

    if unusable ~= nil then
        return unusable
    end

    local probe = open('app', { timeout = 0.3, pool = { wait_timeout = 0.3 } })
    local rows = probe:query('select 1 as one')

    probe:close()

    if rows == nil then
        return 'нет стенда MySQL (make mysql-up)'
    end

    return nil
end

local UNAVAILABLE = unavailable()

--- Почему проверки шифрования и ключа не идут; идут — пусто.
---
--- Каталог стенда общий на машину, а контейнер могли поднять заново
--- прежним сценарием, без сертификатов и ключа: тогда проверки падали бы
--- на чужом корне и чужом ключе — ровно на том, что они и сверяют.
--- Поэтому ключ из каталога сверяется с тем, который сервер отдаёт сам.
---@return string|nil
local function unsecured()
    local file = io.open(PUBLIC_KEY, 'rb')

    if file == nil then
        return 'сертификатов и ключа стенда нет: make mysql-up'
    end

    local key = file:read('*a')

    file:close()

    local served = assert(g.root:query("show status like 'Caching_sha2_password_rsa_public_key'"))

    if served[1].Value ~= key then
        return ('сервер стенда поднят без ключа из %s: make mysql-up'):format(STAND_DIR)
    end

    return nil
end

--- Выпускает в каталог самоподписанный корень, которым сертификат стенда
--- не подписан, и открытый ключ RSA, которого у сервера нет.
---
--- openssl есть везде, где поднят стенд: без него `test/stand/mysql.sh`
--- сертификатов не выпускает.
---@param dir string
---@return string root
---@return string key
local function strangers(dir)
    local secret = fio.pathjoin(dir, 'stranger.key')
    local root = fio.pathjoin(dir, 'stranger.pem')
    local key = fio.pathjoin(dir, 'stranger_public.pem')
    local handle = popen.shell(
        ('openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=tnt-mysql-stranger -keyout %s -out %s'):format(
            secret,
            root
        )
            .. (' && openssl pkey -in %s -pubout -out %s'):format(secret, key)
            .. ' > /dev/null 2>&1'
    )

    t.assert_equals(handle:wait().exit_code, 0, 'openssl не выпустил чужие корень и ключ')
    handle:close()

    return root, key
end

--- Заводит свежую учётку: хеша её пароля в кэше сервера нет, и первый
--- вход идёт полным путём.
---@param password string Пароль в тексте SQL, с экранированием
---@return string name
local function fresh_account(password)
    local name = 'live_' .. uuid.str():sub(1, 8)

    assert(
        g.root:execute(("create user '%s'@'%%' identified with caching_sha2_password by '%s'"):format(name, password))
    )
    table.insert(g.accounts, name)
    assert(g.root:execute(("grant select on app.* to '%s'@'%%'"):format(name)))

    return name
end

--- Драйвер к стенду, вход которого может не состояться: отказ входа
--- приходит за 0,3 с ожидания пула и без повтора, а не в срок вызова.
---@param user string
---@param extra table Настройки поверх
---@return any
local function doomed(user, extra)
    extra.pool = { wait_timeout = 0.3 }
    extra.retry = { attempts = 1 }

    return open(user, extra)
end

--- Шифр соединения по словам сервера: пусто — открытый текст.
---@param db any Драйвер
---@return string|nil cipher
---@return any err
local function cipher_of(db)
    local rows, err = db:query("show session status like 'Ssl_cipher'")

    db:close()

    if rows == nil then
        return nil, err
    end

    return rows[1].Value
end

g.before_all(function()
    t.skip_if(UNAVAILABLE ~= nil, UNAVAILABLE)

    g.db = open('app', { pool = { size = 2 } })
    g.root = open('root')
    -- Учётки, которые проверки заводят сами; уходят вместе с таблицей.
    g.accounts = {}
    assert(
        g.db:execute(
            ('create table %s (id bigint auto_increment primary key, name varchar(50), '):format(TABLE)
                .. 'amount decimal(30, 3), big bigint unsigned, seen datetime(6), tag char(36), flag boolean)'
        )
    )
end)

g.after_all(function()
    if g.db ~= nil then
        g.db:execute('drop table if exists ' .. TABLE)
        g.db:close()

        for _, name in ipairs(g.accounts) do
            g.root:execute(("drop user if exists '%s'@'%%'"):format(name))
        end

        g.root:close()
    end
end)

g.before_each(function()
    assert(g.db:execute('truncate ' .. TABLE))
end)

g.test_values_counts_and_the_new_key = function()
    local db = g.db
    local rows = helper.sql.table(TABLE, { 'id', 'name', 'amount', 'big', 'seen', 'tag' })
    local tag = uuid.fromstr('0b4ae1c4-3b0f-4c4c-9a55-2f4e3b3a1d10')
    local seen = datetime.new({ year = 2026, month = 9, day = 13, hour = 15, min = 34, sec = 56, tzoffset = 180 })
    local inserted = assert(db:execute(rows:insert({
        {
            name = 'Анна',
            amount = decimal.new('12345678901234567890.123'),
            big = 18446744073709551615ULL,
            seen = seen,
            tag = tag,
        },
        { name = box.NULL, amount = box.NULL, big = 1ULL, seen = seen, tag = tag },
    }):build(db.dialect)))

    t.assert_equals(inserted, { affected = 2, last_id = 1 })

    local read = assert(db:query(rows:select('id', 'name', 'amount', 'big', 'seen', 'tag'):build(db.dialect)))

    t.assert_equals(#read, 2)
    t.assert_equals(read[1].name, 'Анна')
    t.assert_equals(read[1].amount, '12345678901234567890.123')
    t.assert_equals(tostring(read[1].big), '18446744073709551615ULL')
    -- Время ушло мигом в UTC: DATETIME пояса не хранит.
    t.assert_equals(read[1].seen, '2026-09-13 12:34:56.000000')
    t.assert_equals(read[1].tag, tostring(tag))
    t.assert_equals(read[2].name, nil)
    t.assert_equals(read[2].amount, nil)
end

g.test_values_after_a_null_are_kept = function()
    local plain = assert(g.db:query('select * from (select 1 as a union all select null union all select 3) t'))
    local prepared =
        assert(g.db:query('select * from (select ? as a union all select null union all select 3) t', { n = 1, 1 }))

    t.assert_equals(plain, { { a = 1 }, {}, { a = 3 } })
    t.assert_equals(prepared, { { a = 1 }, {}, { a = 3 } })
end

g.test_the_prepared_path_returns_every_row = function()
    local counted = assert(
        g.db:query(
            'with recursive cte (n) as (select 1 union all select n + 1 from cte where n < ?) select n from cte',
            { n = 1, 200 }
        )
    )
    local long = string.rep('я', 5000)
    local echoed = assert(g.db:query('select ? as s', { n = 1, long }))

    t.assert_equals(#counted, 200)

    -- Каждая строка, а не последняя: с сотой строки число заполняет
    -- выросший буфер до конца, и рок без починки читал его вместе
    -- с байтом за буфером — 200 приходило числом 2003 или 2006.
    for index, row in ipairs(counted) do
        t.assert_equals(row.n, index)
    end

    t.assert_equals(echoed[1].s, long)
end

g.test_a_number_as_long_as_its_column_is_read_whole = function()
    local db = g.db

    -- BIGINT объявляет 20 знаков, и оба числа заполняют буфер
    -- подготовленного пути целиком: NUL за ними нет, и читать их можно
    -- только в пределах их длины.
    assert(db:execute(('insert into %s (id, name, big) values (?, ?, ?)'):format(TABLE), {
        n = 3,
        -1000000000000000000LL,
        'край',
        10000000000000000000ULL,
    }))

    local read = assert(db:query(('select id, big from %s where name = ?'):format(TABLE), { n = 1, 'край' }))

    t.assert_equals(
        { tostring(read[1].id), tostring(read[1].big) },
        { '-1000000000000000000LL', '10000000000000000000ULL' }
    )
end

g.test_a_false_boolean_is_read_false_wherever_its_buffer_lies = function()
    local db = g.db

    assert(
        db:execute(('insert into %s (id, name, flag) values (?, ?, ?)'):format(TABLE), { n = 3, 1, 'ложь', false })
    )

    -- `boolean` у MySQL — `tinyint(1)`: сервер объявляет столбцу длину 1,
    -- и «0» заполняет буфер подготовленного пути целиком, NUL за ним нет.
    -- Рок без заплаты 0008 читал число вместе с байтом кучи за буфером,
    -- и `false` время от времени приходил числом от 1 до 9 — истиной
    -- у tnt-orm. Где ляжет буфер, решает куча, и в одном процессе это
    -- одно и то же место: без сдвигов порок ловился бы только удачей
    -- общего прогона, где кучу двигают соседние наборы.
    local held = {}
    local seen = {}

    for round = 1, SHORT_READS do
        shake_heap(round, held)

        local rows = assert(db:query(('select flag from %s where id = ?'):format(TABLE), { n = 1, 1 }))
        local flag = tostring(rows[1].flag)

        seen[flag] = (seen[flag] or 0) + 1
    end

    for _, piece in ipairs(held) do
        ffi.C.tnt_mysql_live_free(piece)
    end

    t.assert_equals(seen, { ['0'] = SHORT_READS })
end

g.test_errno_decides_the_kind = function()
    local db = g.db

    assert(db:execute(("insert into %s (id, name) values (1, 'a')"):format(TABLE)))

    local _, syntax = db:query('selec 1')
    local _, duplicate = db:execute(('insert into %s (id, name) values (?, ?)'):format(TABLE), { n = 2, 1, 'b' })
    local _, missing = db:query('select ? as a, ? as b', { n = 1, 1 })
    local reader = open('reader')
    local _, denied = reader:query('select * from ' .. TABLE)

    reader:close()
    t.assert_equals({ syntax.kind, syntax.server_code }, { 'rejected', 1064 })
    t.assert_equals({ duplicate.kind, duplicate.server_code }, { 'rejected', 1062 })
    t.assert_equals({ missing.kind, missing.server_code, missing.sent }, { 'rejected', 2031, true })
    t.assert_equals(missing.message, 'The statement has 2 parameters, but 1 values are given')
    -- Учётке без прав на базу сервер отказывает во входе.
    t.assert_equals({ denied.kind, denied.server_code, denied.retriable }, { 'denied', 1044, false })
end

g.test_a_later_statement_is_not_lost = function()
    local _, err = g.db:execute(
        ("insert into %s (id, name) values (100, 'a'); insert into %s (id, name) values (100, 'b')"):format(
            TABLE,
            TABLE
        )
    )

    t.assert_equals({ err.kind, err.server_code }, { 'rejected', 1062 })
    -- Первый оператор выполнен: сервер делает их по одному, и отказ
    -- говорит только о том, что остальное — нет.
    t.assert_equals(g.db:query(('select name from %s where id = 100'):format(TABLE)), { { name = 'a' } })
end

g.test_a_denied_login_is_told_by_a_word = function()
    local wrong = open('app', { password = 'wrong', timeout = 1 })
    local started = clock.monotonic()
    local _, err = wrong:query('select 1')

    wrong:close()
    t.assert_equals({ err.kind, err.server_code, err.retriable }, { 'denied', 1045, false })
    t.assert_str_matches(
        err.message,
        "mysql 127%.0%.0%.1:%d+/app: вход не удался: Access denied for user 'app'@'.*' %(с паролем%)"
    )
    t.assert(clock.monotonic() - started < 0.5)
end

g.test_a_new_account_logs_in_by_the_key_and_then_by_the_cache = function()
    -- Хеша пароля свежей учётки в кэше сервера нет: первый вход идёт
    -- полным путём, и без TLS пароль уходит зашифрованным открытым
    -- ключом сервера. Второй вход сервер пропускает по кэшу. Пароль
    -- с кавычкой и обратной чертой: ключом шифруется он как есть.
    local name = fresh_account("sha2\\'pa\\\\ss")

    for _ = 1, 2 do
        local fresh = open(name, { password = "sha2'pa\\ss" })
        local rows, err = fresh:query("show session status like 'Ssl_cipher'")

        fresh:close()
        t.assert_equals(err, nil)
        -- Шифра нет: соединение без TLS, и полный вход мог пройти только
        -- ключом RSA.
        t.assert_equals(rows, { { Variable_name = 'Ssl_cipher', Value = '' } })
    end
end

g.test_tls_verifies_the_certificate_of_the_server = function()
    local skip = unsecured()

    t.skip_if(skip ~= nil, skip)

    local dir = fio.tempdir()
    local stranger = strangers(dir)
    local secured = cipher_of(open('app', { tls = { ca = CA } }))
    local plain = cipher_of(open('app'))

    -- Корень есть, а сертификат сервера им не подписан. Коннектор отдаёт
    -- это тем же кодом 2026, что и обрыв посреди рукопожатия TLS, и род —
    -- тот же, что у отказа сети.
    local _, foreign = cipher_of(doomed('app', { tls = { ca = stranger } }))
    local _, lost = cipher_of(doomed('app', { tls = { ca = fio.pathjoin(dir, 'absent.pem') } }))

    fio.rmtree(dir)
    t.assert_not_equals(secured, '')
    t.assert_str_matches(secured, 'TLS_.+')
    t.assert_equals(plain, '')
    t.assert_equals({ foreign.kind, foreign.sent, foreign.retriable }, { 'unreachable', false, true })
    t.assert_str_contains(foreign.message, 'self-signed certificate in certificate chain')
    t.assert_equals({ lost.kind, lost.retriable }, { 'unreachable', true })
    t.assert_str_contains(lost.message, 'No such file or directory')
end

g.test_a_pinned_server_key_carries_the_password = function()
    local skip = unsecured()

    t.skip_if(skip ~= nil, skip)

    local dir = fio.tempdir()
    local _, stranger = strangers(dir)
    local name = fresh_account('pinned-secret')
    local function login(key)
        return cipher_of(doomed(name, { password = 'pinned-secret', server_public_key = key }))
    end

    -- Чужим ключом пароль не прочесть и серверу: вход отвергнут. Хеша
    -- в кэше после отказа нет, и следующий вход — снова полный.
    local _, denied = login(stranger)
    -- Файла нет — вход не начинается: коннектор иначе спросил бы ключ
    -- у сервера по тому же соединению.
    local _, missing = login(fio.pathjoin(dir, 'absent.pem'))
    local pinned = login(PUBLIC_KEY)

    fio.rmtree(dir)
    t.assert_equals({ denied.kind, denied.server_code, denied.retriable }, { 'denied', 1045, false })
    t.assert_equals({ missing.kind, missing.retriable }, { 'unreachable', true })
    t.assert_str_contains(missing.message, "Can't read the server public key file")
    -- Полный вход без TLS прошёл закреплённым ключом.
    t.assert_equals(pinned, '')
end

g.test_the_deadline_holds_after_work_without_yielding = function()
    local started = clock.monotonic()
    local busy = clock.monotonic() + 0.2

    -- Работа без уступки до вызова: срок меряется настоящими часами.
    while clock.monotonic() < busy do
        math.sqrt(2)
    end

    local _, err = g.db:query('select sleep(2) as s', nil, { timeout = 0.3 })
    local spent = clock.monotonic() - started - 0.2

    t.assert_equals({ err.kind, err.sent }, { 'timeout', true })
    t.assert(spent >= 0.29 and spent <= 0.35, spent)
end

g.test_the_ceiling_bounds_a_selection = function()
    local short = open('app', { timeout = 0.5, max_timeout = 0.75 })
    local rows = assert(short:query('select @@session.max_execution_time as ms'))

    short:close()
    t.assert_equals(rows, { { ms = 750 } })
end

g.test_a_killed_session_is_repeated_only_when_idempotent = function()
    local db = open('app', { pool = { size = 1 } })
    local id = assert(db:query('select connection_id() as id'))[1].id
    local function kill_soon()
        fiber.create(function()
            fiber.sleep(0.1)
            assert(g.root:execute(('kill %d'):format(tonumber(id))))
        end)
    end

    kill_soon()

    local _, broken = db:query('select sleep(1) as s')

    t.assert_equals({ broken.kind, broken.sent, broken.retriable }, { 'broken', true, false })

    id = assert(db:query('select connection_id() as id'))[1].id
    kill_soon()

    local rows = assert(db:query('select sleep(0.3) as s', nil, { idempotent = true }))

    t.assert_equals(rows, { { s = 0 } })
    t.assert_equals(db:stats().drops, 2)
    db:close()
end

g.test_a_deadlock_is_a_conflict = function()
    local db = g.db

    assert(db:execute(("insert into %s (id, name) values (1, 'a'), (2, 'b')"):format(TABLE)))

    local other = open('app')
    local first_locked = fiber.cond()
    local outcome = {}
    local worker = fiber.new(function()
        outcome.done, outcome.err = other:transaction(function(tx)
            assert(tx:execute(("update %s set name = 'x' where id = 2"):format(TABLE)))
            first_locked:signal()
            fiber.sleep(0.2)

            return tx:execute(("update %s set name = 'x' where id = 1"):format(TABLE))
        end)
    end)

    worker:set_joinable(true)

    local _, err = db:transaction(function(tx)
        assert(tx:execute(("update %s set name = 'y' where id = 1"):format(TABLE)))
        first_locked:wait(1)

        return tx:execute(("update %s set name = 'y' where id = 2"):format(TABLE))
    end)

    worker:join()
    other:close()

    -- Сервер выбирает жертву сам: взаимоблокировка у одной из двух.
    local victim = err or outcome.err

    t.assert_equals({ victim.kind, victim.server_code }, { 'conflict', 1213 })
end
