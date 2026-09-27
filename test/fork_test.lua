--- Проверки сборки форка рока `mysql` — без стенда.
---
--- Коннектор вшит в драйвер рока вместе со своей zlib. Системная libz
--- приходит в процесс вместе с драйвером — её тянет libcrypto — и свои
--- символы ищет сначала в нём. Отданные наружу, символы вшитой zlib
--- перехватывали её внутренние вызовы: поток gzip любого модуля процесса
--- шёл по двум zlib разом, и при разных версиях процесс падал. Заплата
--- 0010 оставляет символы коннектора внутри драйвера. Проверка смотрит,
--- чьи символы видны из группы драйвера, а не ждёт падения: там, где
--- версии совпали, падения нет, а сборка всё равно негодна.
---
--- Символы прячет только компоновщик Linux: на macOS библиотека зовёт
--- свои функции напрямую, и перехвата там нет. Без рока или на роке,
--- собранном не по заплатам дерева, проверки пропускаются.

local ffi = require('ffi')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mysql.fork')

--- Поиск символов в загруженных библиотеках. Имена свои, а на функции
--- libc они ведут через `__asm__`: объявление с именем `dlopen` уронило
--- бы `ffi.cdef` соседа, объявившего его раньше, — «attempt to redefine».
if not pcall(ffi.typeof, 'tnt_mysql_fork_place') then
    ffi.cdef([[
        typedef struct tnt_mysql_fork_place {
            const char *file;
            void *base;
            const char *name;
            void *address;
        } tnt_mysql_fork_place;

        void *tnt_mysql_fork_open(const char *path, int mode) __asm__("dlopen");
        void *tnt_mysql_fork_symbol(void *handle, const char *name) __asm__("dlsym");
        int tnt_mysql_fork_where(const void *address, tnt_mysql_fork_place *place) __asm__("dladdr");
        int tnt_mysql_fork_close(void *handle) __asm__("dlclose");

        int tnt_mysql_fork_compress(unsigned char *out, unsigned long *out_size,
            const unsigned char *text, unsigned long size, int level) __asm__("compress2");
        int tnt_mysql_fork_uncompress(unsigned char *out, unsigned long *out_size,
            const unsigned char *packed, unsigned long size) __asm__("uncompress");
    ]])
end

--- `RTLD_LAZY | RTLD_NOLOAD` glibc: только уже загруженная библиотека —
--- второй копии драйвера проверке не нужно.
local LOADED_ONLY = 0x1 + 0x4

--- Символы коннектора и его zlib: те, что перехватывали вызовы системной
--- zlib, и те, которыми коннектор живёт сам.
local INNER = {
    'deflateInit2_',
    'deflateReset',
    'deflate',
    'deflateEnd',
    'inflate',
    'crc32',
    'zlibVersion',
    'mysql_init',
    'mysql_real_connect',
    'caching_sha2_password_client_plugin',
}

--- Файл, из которого виден символ при поиске в группе библиотеки;
--- не виден вовсе — пусто.
---@param handle ffi.cdata*
---@param name string
---@return string|nil
local function owner(handle, name)
    local address = ffi.C.tnt_mysql_fork_symbol(handle, name)
    -- Поля структуры `ffi.cdef` проверке типов не видны.
    ---@type any
    local place = ffi.new('tnt_mysql_fork_place')

    if address == nil or ffi.C.tnt_mysql_fork_where(address, place) == 0 then
        return nil
    end

    return ffi.string(place.file)
end

--- Сжимает и разжимает текст системной zlib; отдаёт разжатое и размер
--- сжатого.
---@param text string
---@return string restored
---@return integer packed_size
local function round_trip(text)
    local zlib = ffi.load('libz.so.1')
    local packed = ffi.new('unsigned char[?]', #text + 64)
    -- Размеры — ячейки cdata: zlib пишет в них, а проверка типов их
    -- индексов не видит.
    ---@type any
    local packed_size = ffi.new('unsigned long[1]', #text + 64)

    t.assert_equals(zlib.tnt_mysql_fork_compress(packed, packed_size, text, #text, 3), 0)

    local restored = ffi.new('unsigned char[?]', #text)
    ---@type any
    local restored_size = ffi.new('unsigned long[1]', #text)

    t.assert_equals(zlib.tnt_mysql_fork_uncompress(restored, restored_size, packed, packed_size[0]), 0)

    return ffi.string(restored, restored_size[0]), tonumber(packed_size[0]) --[[@as integer]]
end

g.before_all(function()
    t.skip_if(
        jit.os ~= 'Linux',
        'символы коннектора внутри драйвера прячет только компоновщик Linux'
    )

    local unusable = helper.unusable_rock()

    t.skip_if(unusable ~= nil, unusable)
end)

g.test_the_driver_keeps_the_symbols_of_the_connector_inside = function()
    local path = package.search('mysql.driver')
    local handle = ffi.C.tnt_mysql_fork_open(path, LOADED_ONLY)

    t.assert(handle ~= nil, path)

    local seen = { luaopen_mysql_driver = owner(handle, 'luaopen_mysql_driver') }

    for _, name in ipairs(INNER) do
        seen[name] = owner(handle, name)
    end

    ffi.C.tnt_mysql_fork_close(handle)

    -- Вход Lua — в самом драйвере: поиск смотрит в тот файл, что нужно.
    t.assert_equals(seen.luaopen_mysql_driver, path)

    -- Коннектор и его zlib снаружи не видны: `deflateReset` из группы
    -- драйвера находится в системной libz, если её тянет libcrypto,
    -- а `mysql_real_connect` — нигде.
    for _, name in ipairs(INNER) do
        t.assert_not_equals(seen[name], path, name)
    end

    -- Системная zlib рядом с драйвером сжимает и разжимает сама собой.
    -- Идёт после сверки символов: драйвер, отдающий свою zlib, при
    -- разных версиях уронил бы здесь весь прогон, а не одну проверку.
    local text = ('hello world '):rep(1000)
    local restored, packed_size = round_trip(text)

    t.assert_equals(restored, text)
    t.assert_lt(packed_size, #text / 10)
end
