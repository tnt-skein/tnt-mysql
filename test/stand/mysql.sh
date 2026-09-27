#!/usr/bin/env bash
# Поднимает MySQL для живых проверок драйвера tnt-mysql.
#
# Настоящий сервер, а не двойник рока: двойник показывает, что фасад
# правильно разговаривает сам с собой, а сервер — что его понимает
# MySQL. Разница вылезает на отказах: errno взаимоблокировки, срок
# max_execution_time, сеанс, убитый посреди запроса, отказ второго
# оператора, выдача подготовленного пути длиннее описания столбца.
#
# Сервер — с настройками по умолчанию, и учётки входят через
# caching_sha2_password: так входят в MySQL 8.4 и 9 по умолчанию,
# а mysql_native_password в 8.4 выключен и в 9 убран. Способ записан
# у учёток явно, чтобы стенд проверял его и на сервере, где умолчание
# другое.
#
# Открытый текст и TLS идут на один порт, а какой из них выбрать, решает
# клиент. Без TLS пароль при полном входе уходит обменом ключом RSA —
# ключом, который сервер шлёт по тому же соединению, либо закреплённым
# у клиента файлом. Сертификат сервера и пара ключей RSA выпускаются
# здесь же на год: сертификат, который MySQL выпускает себе сам, имени
# узла не несёт, а ключ, который он заводит сам, клиенту не виден.
#
# Каталог сертификатов и ключей — `MYSQL_TLS_DIR`, по умолчанию общий
# на машину `/tmp/tnt-stand/<контейнер>`: контейнер один на машину
# и переживает рабочую копию, которая его подняла, — сертификаты в её
# каталоге видела бы только она. Живая проверка читает ту же переменную
# и то же умолчание.
#
# Образ по умолчанию — MySQL 8.4; MySQL 9 поднимается тем же сценарием:
#
#   STAND_MYSQL_IMAGE=mysql:9 STAND_MYSQL_CONTAINER=tnt-stand-mysql-9 \
#       STAND_MYSQL_PORT=13319 test/stand/mysql.sh
#
# Имя контейнера меняется, чтобы второй сервер встал рядом с первым,
# а не на его место: стенд один на машину, и первым могут пользоваться
# соседние копии дерева.
#
# Учёток три: `app` владеет базой `app`, `reader` войти может, а таблиц
# не видит — отказ прав настоящий; `root` нужен проверкам, которые
# убивают чужой сеанс (`KILL`), смотрят список сеансов и заводят свои
# учётки. Пароль `app` с кавычкой и обратной чертой: рок передаёт его
# отдельным аргументом, и он обязан входить как есть.
#
#   test/stand/mysql.sh          # поднять
#   test/stand/mysql.sh stop     # погасить
set -euo pipefail

# Относительный каталог отсчитывается от места запуска: оттуда его
# читает и живая проверка. Ниже сценарий переходит в свой каталог, и без
# этого стенд лёг бы в одно место, а проверка искала бы его в другом.
case "${MYSQL_TLS_DIR:-}" in
    '' | /*) ;;
    *) MYSQL_TLS_DIR="${PWD}/${MYSQL_TLS_DIR}" ;;
esac

cd "$(dirname "$0")"

IMAGE="${STAND_MYSQL_IMAGE:-mysql:8.4}"
CONTAINER="${STAND_MYSQL_CONTAINER:-tnt-stand-mysql}"
PORT="${STAND_MYSQL_PORT:-13306}"
DIR="${MYSQL_TLS_DIR:-/tmp/tnt-stand/${CONTAINER}}"

# Пароли стенда: локальный сервер для проверок, а не развёртывание.
ROOT_PASSWORD='root-secret'
# В тексте SQL ниже кавычка и обратная черта экранированы: `app'se\cret`.
APP_PASSWORD_SQL="app\\'se\\\\cret"
READER_PASSWORD='reader-secret'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: MySQL поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    echo "MySQL остановлен (${CONTAINER})"
    exit 0
fi

if ! command -v openssl > /dev/null 2>&1; then
    echo 'openssl не найден: сертификаты выпустить нечем' >&2
    exit 1
fi

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Данные живут внутри контейнера и уходят с ним.
# Сносится до выпуска сертификатов: каталог смонтирован в него, и проверки
# соседних копий иначе брали бы новый корень и ключ, пока отвечает старый
# сервер.
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Сертификаты и ключи выпускаются заново на каждый подъём: вчерашний
# каталог дал бы отказ рукопожатия, неотличимый от того, ради которого
# проверка написана. Срок — год, а не сутки: контейнер общий на машину
# и живёт дольше задачи, которая его подняла.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=tnt-mysql-live-ca' \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2> /dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "${DIR}/server.ext"
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
    -keyout "${DIR}/server.key" -out "${DIR}/server.csr" 2> /dev/null
openssl x509 -req -in "${DIR}/server.csr" -days 365 \
    -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
    -extfile "${DIR}/server.ext" -out "${DIR}/server.pem" 2> /dev/null
# Пара RSA для входа caching_sha2_password без TLS: открытый ключ
# клиент закрепляет файлом, и посредник, подменивший ключ в сети,
# пароля не прочтёт.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${DIR}/private_key.pem" 2> /dev/null
openssl pkey -in "${DIR}/private_key.pem" -pubout -out "${DIR}/public_key.pem" 2> /dev/null

# Ключи сервер читает от своей учётки, а смонтированный каталог
# принадлежит пользователю машины, и ключи в нём закрыты от чужих.
# Поэтому вход образа обёрнут: ключи копируются внутрь с нужным
# владельцем, затем управление уходит обычному входу образа.
docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:3306" \
    -v "${DIR}:/certs:ro" \
    -e MYSQL_ROOT_PASSWORD="${ROOT_PASSWORD}" \
    -e MYSQL_ROOT_HOST='%' \
    -e MYSQL_DATABASE=app \
    --entrypoint sh \
    "${IMAGE}" \
    -c 'mkdir -p /stand &&
        install -o mysql -m 600 /certs/server.key /certs/private_key.pem /stand/ &&
        install -o mysql -m 644 /certs/ca.pem /certs/server.pem /certs/public_key.pem /stand/ &&
        exec docker-entrypoint.sh mysqld \
            --ssl-ca=/stand/ca.pem --ssl-cert=/stand/server.pem --ssl-key=/stand/server.key \
            --caching-sha2-password-private-key-path=/stand/private_key.pem \
            --caching-sha2-password-public-key-path=/stand/public_key.pem' > /dev/null

# Готовности ждём по настоящему запросу через TCP: образ сначала
# поднимает сервер без сети для начальных сценариев, и сокет внутри
# контейнера отвечает раньше, чем порт наружу. Проверки, запущенные
# в этот миг, пропустились бы — и это выглядело бы как «всё хорошо».
for _ in $(seq 1 200); do
    if docker exec "${CONTAINER}" mysql -h127.0.0.1 -uroot -p"${ROOT_PASSWORD}" -NBe 'select 1' 2> /dev/null | grep -q '^1$'; then
        docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -uroot -p"${ROOT_PASSWORD}" 2> /dev/null <<SQL
create user 'app'@'%' identified with caching_sha2_password by '${APP_PASSWORD_SQL}';
grant all on app.* to 'app'@'%';
create user 'reader'@'%' identified with caching_sha2_password by '${READER_PASSWORD}';
alter user 'root'@'%' identified with caching_sha2_password by '${ROOT_PASSWORD}';
SQL
        echo "MySQL поднят (${IMAGE}): 127.0.0.1:${PORT}, учётки app, reader и root," \
            "TLS на том же порту, сертификаты и ключ сервера в ${DIR}"
        exit 0
    fi

    sleep 0.5
done

echo "MySQL не ответил за 100 секунд: смотрите docker logs ${CONTAINER}" >&2
exit 1
