--- Сверка рока `mysql` в `.rocks` с рецептом форка в дереве.
---
--- Копия дерева получает `.rocks` копированием из основного, и рок,
--- собранный до новой заплаты, живёт в ней, пока его не пересоберут.
--- Живые проверки на таком роке падали бы у всех копий разом на том,
--- что чинит заплата: рок без заплаты 0008 дочитывал число за концом
--- буфера, и `false` столбца `boolean` время от времени приходил `true`.
---
--- Сверка одна на все проверки над настоящим роком — и драйвера, и тех,
--- кто ходит в MySQL через него. Файл ничего не ставит, а рок грузит
--- только по вызову `unusable` и только сверенный, поэтому его берут
--- и помощники соседних пакетов.

local digest = require('digest')
local fio = require('fio')

local Module = {}

--- Отпечаток рецепта, по которому собран рок в `.rocks` этой копии дерева.
local STAMP = '.rocks/mysql-fork.sha256'

--- Текст файла дерева; нет файла — пустая строка, и отпечаток
--- не сойдётся ни с каким записанным.
---@param path string
---@return string
local function text_of(path)
    local file = io.open(path, 'rb')

    if file == nil then
        return ''
    end

    local text = file:read('*a')

    file:close()

    return text
end

--- Отпечаток рецепта форка по дереву — тот же, что пишет
--- `tools/deps_mysql.sh`: коммит строкой, затем заплаты рока в порядке
--- имён. Коммит коннектора записан в заплате 0009 и входит с ней.
---@return string
local function recipe()
    local parts = { (text_of('tools/deps_mysql.sh'):match("\nCOMMIT='(%x+)'") or '') .. '\n' }
    local paths = fio.glob('rocks/mysql/*.patch')

    table.sort(paths)

    for _, path in ipairs(paths) do
        table.insert(parts, text_of(path))
    end

    return digest.sha256_hex(table.concat(parts))
end

--- Почему рок в `.rocks` не годится живым проверкам; годится — пусто.
---
--- Без отпечатка рок либо не стоит, либо поставлен мимо сценария сборки,
--- и то и другое лечит одна цель.
---@return string|nil
function Module.stale()
    local stamp = text_of(STAMP):match('%x+')

    if stamp == nil then
        return ('нет рока mysql, собранного по заплатам rocks/mysql (%s) — поставьте: make deps-mysql'):format(
            STAMP
        )
    end

    if stamp == recipe() then
        return nil
    end

    return ('рок mysql собран не по заплатам rocks/mysql (%s) — пересоберите: make deps-mysql'):format(
        STAMP
    )
end

--- Почему рок нельзя взять проверкам; можно — пусто, и рок загружен.
---
--- Отпечаток сверяется до загрузки: рок, собранный не по рецепту дерева,
--- в процесс проверок не попадает вовсе. Загрузка вредит и тогда, когда
--- сами живые проверки пропускаются: драйвер без заплаты 0010 отдаёт
--- наружу символы вшитой zlib, и рок, загруженный при чтении файла
--- проверок, ронял gzip соседнего набора того же прогона.
---@return string|nil
function Module.unusable()
    local stale = Module.stale()

    if stale ~= nil then
        return stale
    end

    if not pcall(require, 'mysql') then
        return 'нет рока mysql (make deps-mysql)'
    end

    return nil
end

return Module
