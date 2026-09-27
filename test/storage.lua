--- Средства помощника проверок `tnt-storage`, которыми пользуется двойник
--- рока `test/fake_rock.lua`: модуль по имени, сверка места броска
--- и значение мимо проверки типов.
---
--- Двойник рока — общий у драйверов над роком и взят из проверок
--- `tnt-storage`, где он берёт эти средства у помощника того пакета.
--- От оригинала копия отличается одной строкой — той, что берёт этот
--- файл. Исходников `tnt-storage` здесь нет: пакет стоит в `.rocks`,
--- и модуль по имени — тот экземпляр, что уже взял фасад.

local t = require('luatest')

local storage = {}

--- Модуль по имени — тот же экземпляр, что у фасада.
---@param name string
---@return any
function storage.module(name)
    return require(name)
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function storage.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function storage.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

return storage
