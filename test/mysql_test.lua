--- Проверки фасада насквозь на двойнике рока `mysql`: диалект, вход от
--- `tnt-sql`, счёт и новый ключ, род отказа по errno и словам, отказ входа
--- словом о пароле, транзакция по отметке фасада, отмена вызывающего
--- и тексты отказов.
---
--- Пул, срок, повторы и транзакции как таковые проверяет `tnt-storage`
--- своим двойником: здесь — то, как их собирает этот фасад.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local storage = helper.storage

local g = t.group('tnt.mysql')

local connect = helper.suite(g)

g.test_new_opens_nothing_and_declares_the_dialect = function()
    local client, rock = connect(nil, { name = 'orders', max_rows = 7 })

    t.assert_equals(client.name, 'orders')
    t.assert_equals(client.features, { transaction = true })
    t.assert_equals(client.dialect.name, 'mysql')
    t.assert_equals(client.dialect.quote, '`')
    t.assert_equals(client.where, '127.0.0.1:3306/app')
    t.assert_equals(client.max_rows, 7)
    t.assert_equals(rock.logins, 0)

    -- Правка диалекта драйвера не трогает правил построителя.
    client.dialect.quote = '"'
    t.assert_equals(sql.table('t', { 'id' }):select('id'):build('mysql'), 'select `id` from `t`')
end

g.test_the_pair_from_tnt_sql_counts_and_names_the_key = function()
    local client, rock = connect(function(text)
        if text:find('^insert') then
            return { affected = 2, last_id = 41 }
        end
    end)
    local users = sql.table('users', { 'id', 'name', 'meta' })
    local query = users:insert({
        { name = 'Анна', meta = storage.json({ a = 1 }) },
        { name = 'Борис', meta = storage.json({}) },
    })

    t.assert_equals({ client:execute(query:build(client.dialect)) }, { { affected = 2, last_id = 41 } })
    t.assert_equals(helper.statements(rock), { 'insert into `users` (`meta`, `name`) values (?, ?), (?, ?)' })
    t.assert_equals(rock.sent[2].args, { n = 4, '{"a":1}', 'Анна', '[]', 'Борис' })
    t.assert_equals(rock.sent[1].sql, 'SET SESSION max_execution_time = 60000')
end

g.test_a_refusal_is_told_by_errno_and_by_words = function()
    local client = connect(function(text)
        if text == 'deadlock' then
            return { raise = helper.mysql_error('Deadlock found when trying to get lock', 1213) }
        end

        if text == 'slow' then
            return { raise = helper.mysql_error('Query execution was interrupted', 3024) }
        end

        if text == 'worded' then
            return { raise = '/x/mysql/init.lua:147: Lock wait timeout exceeded; try restarting transaction' }
        end
    end)
    local _, deadlock = client:execute('deadlock')
    local _, slow = client:query('slow', nil, { idempotent = true })
    local _, worded = client:execute('worded')

    t.assert_equals({ deadlock.kind, deadlock.server_code, deadlock.retriable }, { 'conflict', 1213, false })
    t.assert_equals({ slow.kind, slow.server_code, slow.retriable }, { 'timeout', 3024, true })
    t.assert_equals({ worded.kind, worded.server_code, worded.message }, {
        'conflict',
        nil,
        'Lock wait timeout exceeded; try restarting transaction',
    })
end

g.test_a_denied_login_tells_the_password_by_a_word = function()
    g.journal = helper.capture_log()

    local client = connect(nil, { timeout = 1 }, function()
        return {
            raise = helper.mysql_error("Access denied for user 'app'@'172.17.0.1' (using password: YES)", 1045),
        }
    end)
    local _, err = client:query('select 1')

    t.assert_equals({ err.kind, err.retriable, err.sent, err.server_code }, { 'denied', false, false, 1045 })
    t.assert_equals(
        err.message,
        "mysql 127.0.0.1:3306/app: вход не удался: Access denied for user 'app'@'172.17.0.1' (с паролем)"
    )
    t.assert_equals(json.decode(json.encode({ err = err })).err, err.message)
    t.assert(g.journal.logged('(с паролем)'))
    t.assert_not(g.journal.logged('скрыто'))
end

g.test_a_failed_statement_in_a_transaction_is_rolled_back_by_the_mark = function()
    local client, rock = connect(function(text)
        if text == 'bad' then
            return { raise = helper.mysql_error("Duplicate entry '1' for key 't.PRIMARY'", 1062) }
        end
    end)
    local _, err = client:transaction(function(tx)
        tx:execute('good')
        tx:execute('bad')

        return true
    end)

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(helper.statements(rock), { 'BEGIN', 'good', 'bad', 'ROLLBACK' })
    t.assert_equals(client:stats().idle, 1)
    t.assert_equals(client:stats().discarded, 0)
end

g.test_begin_by_hand_is_not_seen = function()
    -- Рок не говорит, открыта ли транзакция: `BEGIN` текстом — ошибка
    -- программиста, и соединение с ней уходит в пул, как пришло.
    local client = connect()

    t.assert_equals({ client:execute('BEGIN') }, { { affected = nil, last_id = 0 } })
    t.assert_equals(client:stats().idle, 1)
    t.assert_equals(client:stats().discarded, 0)
end

g.test_a_cancelled_caller_leaves_no_connection_busy = function()
    -- Отмену вызывающего `within.call` бросает мимо драйвера, и фасад,
    -- который не поймал бы её сам, держал бы соединение занятым до конца
    -- жизни узла. Выброшенное закрывает выход работника, когда рок отпустит.
    -- `idempotent` даёт повтору право на второй заход, но пауза повтора
    -- в отменённом файбере бросает, и до рока доходит один оператор.
    local client, rock = connect(function(text)
        if text == 'select sleep(1)' then
            return { delay = 1 }
        end
    end)
    local ok, err = helper.cancelled(function()
        return client:query('select sleep(1)', nil, { idempotent = true })
    end)

    t.assert_equals({ ok, tostring(err) }, { false, 'fiber is cancelled' })
    t.assert_equals(helper.statements(rock), { 'select sleep(1)' })
    t.assert_equals({ client:stats().busy, client:stats().drops, client:stats().total }, { 0, 1, 0 })
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert(rock.conns[1].closed)
    end)
end

g.test_texts_name_the_driver = function()
    local client = connect(function(text)
        if text == 'select sleep(1)' then
            return { delay = 1 }
        end
    end)
    local _, late = client:query('select sleep(1)', nil, { timeout = 0.05 })

    t.assert_equals(late.message, 'mysql 127.0.0.1:3306/app: ответа нет за 0.05 с')
    t.assert_equals(client:stats().name, 'mysql')
    client:close()

    local _, again = client:close()

    t.assert_equals(again.message, 'mysql: драйвер уже закрыт')
end
