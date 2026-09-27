#!/usr/bin/env bash
# Ставит рок mysql — форк с починками — в дерево .rocks проекта.
#
# Форк — это официальный tarantool/mysql на закреплённом коммите master
# и заплаты из rocks/mysql/ поверх него: код ошибки полем, число
# затронутых строк и новый ключ, отказ второго оператора, выдача
# подготовленного пути без обрезки и число в пределах его длины, значения
# после NULL и BIGINT UNSIGNED без порчи, отказ на недостающий параметр,
# сборка на Tarantool 3.8, вход через caching_sha2_password, символы
# коннектора с его zlib внутри драйвера — иначе они перехватывали вызовы
# системной zlib, и gzip соседнего модуля мог уронить процесс, — и TLS
# со сверкой сертификата сервера и закреплённым ключом RSA сервера.
# Выпуск 2.1.3
# на rocks.tarantool.org на Tarantool 3.8 не собирается вовсе, а master
# собирается только CMake 3 с ослабленными ошибками clang, входит только
# через mysql_native_password и не чинит ничего из перечисленного,
# поэтому ни метка, ни master сами не годятся.
#
# Форк лежит в репозитории рецептом — коммит и заплаты, — а не копией
# рока и не отдельным репозиторием: рок собирается с чистого клона из одних
# и тех же исходников, а `make deps` его не подменяет.
#
# Коннектор MySQL вложен в рок подмодулем. Заплата 0009 переводит его
# с tarantool/mariadb-connector-c (MariaDB Connector/C 3.0.2) на выпуск
# 3.4.10 у источника: в старом нет caching_sha2_password — входа
# MySQL 8.4 и 9 по умолчанию, а mysql_native_password в MySQL 9 убран.
# Коммит подмодуля заплата несёт в себе, поэтому заплаты накладываются
# с --index: без индекса git apply смену коммита подмодуля молча
# пропускает. Подмодуль поднимается уже после заплат — с того адреса
# и на том коммите, что записала заплата.
#
# Коммит закреплён: заплаты написаны против него, и master, ушедший
# вперёд, либо не примет их, либо молча поменяет поведение, которое
# проверки tnt-mysql сверили. Подъём — отдельная правка со сверкой
# живыми проверками заново. То же — у коннектора: его коммит закреплён
# заплатой 0009.
#
# Сборка оставляет отпечаток рецепта — коммит и заплаты — в
# .rocks/mysql-fork.sha256. Новую заплату приносит обновление исходников,
# а рок, собранный до неё, остаётся в .rocks, пока его не пересоберут.
# Проверки над настоящим роком сверяют отпечаток с репозиторием и на таком
# роке пропускаются с подсказкой, а не падают на том, что чинит новая
# заплата.
#
# Пропуск молчит: прогон зелёный, а поведение форка на настоящем сервере
# не проверяет никто. Поэтому после обновления исходников сценарий зовут
# с --if-stale: рок пересобирается, только если он стоит в .rocks,
# а отпечаток не сходится с рецептом. Рок, которого в .rocks нет, этот
# ход не ставит: цель не входит в `make deps` нарочно, и машина без CMake
# и libssl-dev не должна спотыкаться о неё на каждом обновлении.
#
# Рок собирается из C: нужны CMake, компилятор и заголовки OpenSSL
# (libssl-dev) — caching_sha2_password считает SHA-256 и шифрует пароль
# открытым ключом сервера, а соединение с настройкой ssl шифрует TLS
# коннектора. Коннектор вложен в рок и с машины
# не берётся. В `make deps` цель не входит нарочно: без рока гейты
# проходят, а живые проверки tnt-mysql пропускаются.
#
# Узлы работают на Linux, поэтому сборка проверена там: на Debian 13
# и в образе tarantool/tarantool:3.8 (Ubuntu 22.04), с CMake от 3.22
# до 4.4. Сборочного в образе нет, его ставит `apt-get update &&
# apt-get install -y git build-essential cmake libssl-dev`. Узлу
# сборочное не нужно: собранный рок держится только на libssl
# и libcrypto системы (OpenSSL 3), а их в образе даёт libssl3.
# CMake 4.4 предупреждает о политике CMP0219 и печатает module.h
# Tarantool целиком: cmake/FindTarantool.cmake рока передаёт текст
# заголовка в макрос. Политика не задана, и макрос работает так же,
# как в CMake 4.3, поэтому сборка от предупреждения не меняется.
#
# Запуск:
#   tools/deps_mysql.sh             — собрать рок (или make deps-mysql)
#   tools/deps_mysql.sh --if-stale  — пересобрать, только если рок стоит,
#                                     а собран не по рецепту репозитория

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rocks_tree="${project_root}/.rocks"
patches="${project_root}/rocks/mysql"
source_dir="${project_root}/var/rocks/mysql"

stamp="${rocks_tree}/mysql-fork.sha256"

# Запись tt о поставленном роке. Стоит ли рок, судится по ней, а не
# по отпечатку: у рока, собранного до сверки отпечатков, его нет вовсе.
installed="${rocks_tree}/share/tarantool/rocks/mysql"

UPSTREAM='https://github.com/tarantool/mysql.git'
COMMIT='b88dbb8b88b6681af443975e90a229a0754d80bc'

# Отпечаток рецепта: коммит строкой, затем заплаты рока в порядке имён
# байтами. Коммит коннектора записан в заплате 0009 и в отпечаток входит
# с ней. Тот же отпечаток считает test/fork.lua и сверяет с записанным
# перед проверками над настоящим роком.
fingerprint() {
    (
        export LC_ALL=C
        printf '%s\n' "${COMMIT}"
        cat "${patches}"/*.patch
    ) | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d ' ' -f 1
}

case "$*" in
'') ;;
--if-stale)
    if [ ! -d "${installed}" ]; then
        echo 'Рок mysql не поставлен — пересобирать нечего; поставить: make deps-mysql'
        exit 0
    fi

    if [ ! -f "${stamp}" ]; then
        echo "Рок mysql без отпечатка рецепта (${stamp}) — пересборка"
    elif [ "$(cat "${stamp}")" != "$(fingerprint)" ]; then
        echo 'Рок mysql собран не по заплатам rocks/mysql — пересборка'
    else
        echo 'Рок mysql собран по заплатам rocks/mysql — пересборка не нужна'
        exit 0
    fi
    ;;
*)
    echo "Рок mysql не собран: незнакомые аргументы «$*»; запуск — tools/deps_mysql.sh [--if-stale]" >&2
    exit 2
    ;;
esac

# В macOS своего OpenSSL для сборки нет, а CMake ищет его там, куда
# укажет OPENSSL_ROOT_DIR. Путь, заданный руками, не трогается.
if [ "$(uname -s)" = 'Darwin' ] && [ -z "${OPENSSL_ROOT_DIR:-}" ] && command -v brew >/dev/null; then
    OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
    export OPENSSL_ROOT_DIR
fi

echo "[1/4] исходники ${UPSTREAM} на ${COMMIT:0:7}"
rm -rf "${source_dir}"
mkdir -p "$(dirname "${source_dir}")"
git clone --quiet "${UPSTREAM}" "${source_dir}"
git -C "${source_dir}" checkout --quiet "${COMMIT}"

echo '[2/4] заплаты рока из rocks/mysql'
for patch in "${patches}"/*.patch; do
    echo "  $(basename "${patch}")"
    git -C "${source_dir}" apply --index "${patch}"
done

echo '[3/4] коннектор на коммите из заплат'
git -C "${source_dir}" submodule --quiet update --init
# У коннектора свой подмодуль — вики с документацией. Сборка рока
# и сборка коннектора зовут `git submodule update --init --recursive`
# и без запрета клонировали бы её по сети посреди сборки.
git -C "${source_dir}/mariadb-connector-c" config submodule.docs.update none
git -C "${source_dir}" submodule status

echo "[4/4] сборка в ${rocks_tree}"
# Отпечаток прежней сборки стирается до новой: оборванная сборка
# не должна оставить подтверждения, что рок собран по этим заплатам.
rm -f "${stamp}"
# Сборка идёт из каталога исходников: чужих настроек проекта там нет.
# Сборка рока сама зовёт `git submodule update`, но коннектор уже
# на коммите из индекса, и обновлять ей нечего.
(
    cd "${source_dir}"
    tt rocks make --tree "${rocks_tree}" mysql-scm-1.rockspec
)
fingerprint >"${stamp}"

echo 'Рок mysql (форк) поставлен'
