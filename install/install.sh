#!/bin/sh
#
# karexo - установка на свой сервер одной командой.
#
#   ./install.sh                     спросит нужное и поднимет инстанс
#   ./install.sh --update            обновить до новой версии
#   ./install.sh --uninstall         снять стек (данные остаются в томе)
#
# Неинтерактивно (ansible, CI, повторяемая установка):
#
#   ./install.sh --yes \
#       --base-url https://notes.example.org \
#       --port 8080 --registration invite \
#       --smtp-host smtp.example.org --smtp-user karexo@example.org \
#       --owner-email boss@example.org --owner-name "Начальник"
#
# Учётку владельца скрипт заводит сам, командой сервера -create-owner. Отвечать
# на этот вопрос надо: при регистрации invite и closed (а invite здесь по
# умолчанию) формы «Зарегистрироваться» на инстансе нет вовсе, пригласить
# первого человека некому - и войти в поднятый инстанс будет нечем. При
# регистрации open владелец назначится сам, но им станет тот, кто ПЕРВЫМ откроет
# адрес: на публичном адресе это гонка с кем угодно, кто узнал про инстанс
# раньше хозяина.
#
# Секреты можно не писать в командной строке - она попадает в историю оболочки
# и видна в `ps`. Любой параметр читается из окружения тем же именем, что
# уходит в .env:
#
#   KAREXO_SMTP_PASS=... ./install.sh --yes --base-url https://notes.example.org
#
# Намеренно /bin/sh, а не bash: на минимальных серверных образах (alpine,
# debian-slim) bash может не стоять, а установщик обязан работать там, куда его
# принесли.

set -eu

# ─── Где что лежит ───────────────────────────────────────────────────────────

# Каталог установки: рядом со скриптом. Там окажутся docker-compose.yml и .env,
# оттуда же потом делается `docker compose logs`.
DIR="${KAREXO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
COMPOSE_FILE="$DIR/docker-compose.yml"
ENV_FILE="$DIR/.env"

# Откуда взять docker-compose.yml, если его нет рядом (обычная установка из
# интернета). В закрытом контуре файл приезжает в архиве, и сеть не нужна.
COMPOSE_URL="https://raw.githubusercontent.com/mihazzzold/karexo/main/install/docker-compose.yml"

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

# Значения в .env экранируем: пароль от почты вполне может содержать кавычку,
# знак доллара и обратный слэш.
#
# Формат .env у compose - НЕ формат оболочки, и привычный приём с одинарными
# кавычками здесь молча ломает пароль: compose читает значение до первой
# закрывающей кавычки, а остаток отбрасывает. В двойных кавычках он понимает
# \" и \\, а доллар удваивается - иначе $HOME внутри пароля подставится
# значением переменной окружения.
q() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/$$/g'
}

# Обратное преобразование - для чтения уже записанного .env.
unq() {
    printf '%s' "$1" | sed -e 's/^"//; s/"$//' -e 's/\$\$/$/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

# Скачать по HTTP тем, что есть в системе. Пусто = не получилось; отличать
# «нет программы» от «сервер не ответил» здесь не нужно, оба случая - неудача.
http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS "$1" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1" 2>/dev/null || true
    fi
}

# ─── Разбор аргументов ───────────────────────────────────────────────────────

ASSUME_YES=0
MODE=install

# Значения берутся из окружения: так секрет можно передать, не светя его в
# командной строке. Пустая строка = «не задано», спросим или оставим умолчание.
base_url="${KAREXO_BASE_URL:-}"
port="${KAREXO_PORT:-}"
tag="${KAREXO_TAG:-}"
registration="${KAREXO_REGISTRATION:-}"
edition="${KAREXO_EDITION:-}"
token_key="${KAREXO_TOKEN_KEY:-}"
smtp_host="${KAREXO_SMTP_HOST:-}"
smtp_port="${KAREXO_SMTP_PORT:-}"
smtp_user="${KAREXO_SMTP_USER:-}"
smtp_pass="${KAREXO_SMTP_PASS:-}"
smtp_from="${KAREXO_SMTP_FROM:-}"
tls="${KAREXO_TLS:-}"
tls_domain="${KAREXO_TLS_DOMAIN:-}"
tls_email="${KAREXO_TLS_EMAIL:-}"
trust_proxy="${KAREXO_TRUST_PROXY:-}"
instance_limit="${KAREXO_INSTANCE_LIMIT:-}"
license="${KAREXO_LICENSE:-}"
allow_outbound="${KAREXO_ALLOW_OUTBOUND:-}"
# Учётка владельца инстанса. Пароль сюда флагом не передаётся - командная строка
# видна в `ps` всей машине; только окружением или вопросом со скрытым вводом.
owner_email="${KAREXO_OWNER_EMAIL:-}"
owner_name="${KAREXO_OWNER_NAME:-}"
owner_pass="${KAREXO_OWNER_PASSWORD:-}"

# Справка - это шапка файла: два места с одним текстом разъезжаются, а здесь
# человек читает ровно то, что написано в скрипте. Печатаем со второй строки и
# до конца комментария, поэтому границу не надо править при каждой правке шапки.
usage() {
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
}

# Значение следующего аргумента; отсутствие - ошибка, а не пустая строка:
# «--port» без числа не должен молча обнулить порт.
need() {
    [ $# -ge 2 ] || die "у $1 нет значения"
    printf '%s' "$2"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage ;;
        -y|--yes)         ASSUME_YES=1 ;;
        --update)         MODE=update ;;
        --uninstall)      MODE=uninstall ;;
        --env-only)       MODE=env ;;
        --base-url)       base_url=$(need "$@"); shift ;;
        --port)           port=$(need "$@"); shift ;;
        --tag)            tag=$(need "$@"); shift ;;
        --registration)   registration=$(need "$@"); shift ;;
        --edition)        edition=$(need "$@"); shift ;;
        --smtp-host)      smtp_host=$(need "$@"); shift ;;
        --smtp-port)      smtp_port=$(need "$@"); shift ;;
        --smtp-user)      smtp_user=$(need "$@"); shift ;;
        --smtp-pass)      smtp_pass=$(need "$@"); shift ;;
        --smtp-from)      smtp_from=$(need "$@"); shift ;;
        --tls)            tls=$(need "$@"); shift ;;
        --tls-domain)     tls_domain=$(need "$@"); shift ;;
        --tls-email)      tls_email=$(need "$@"); shift ;;
        --trust-proxy)    trust_proxy=$(need "$@"); shift ;;
        --instance-limit) instance_limit=$(need "$@"); shift ;;
        --license)        license=$(need "$@"); shift ;;
        --owner-email)    owner_email=$(need "$@"); shift ;;
        --owner-name)     owner_name=$(need "$@"); shift ;;
        --offline)        allow_outbound=false ;;
        *)                die "неизвестный аргумент: $1 (--help)" ;;
    esac
    shift
done

# ─── Docker ──────────────────────────────────────────────────────────────────

# Работаем ИЗ каталога установки, а не передаём -f и --env-file путями: имя
# проекта compose всё равно берёт от каталога, зато человек потом повторяет наши
# команды один в один, просто зайдя сюда. Подоболочка, чтобы не менять каталог
# самому скрипту.
compose() {
    # shellcheck disable=SC2086
    ( cd "$DIR" && $COMPOSE_CMD "$@" )
}

# `docker compose` (плагин, v2) или `docker-compose` (отдельная программа, v1).
# Проверяем ЗАПУСКОМ, а не наличием файла: плагин может быть не установлен при
# живом docker, и тогда «docker compose» отвечает ошибкой, а не работает.
detect_compose() {
    command -v docker >/dev/null 2>&1 || die \
        "docker не найден. Установите Docker Engine: https://docs.docker.com/engine/install/"
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        die "не найден docker compose. Поставьте плагин compose: https://docs.docker.com/compose/install/"
    fi
    docker info >/dev/null 2>&1 || die \
        "docker не отвечает. Демон запущен? Может не хватать прав - попробуйте через sudo"
}

detect_compose

# ─── Снятие и обновление ─────────────────────────────────────────────────────

if [ "$MODE" = uninstall ]; then
    [ -f "$COMPOSE_FILE" ] || die "рядом нет docker-compose.yml - снимать нечего"
    # Без .env compose падает на первой же обязательной переменной, а снять
    # стек надо и тогда, когда настройки уже удалили руками.
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    say "Останавливаю…"
    compose down
    say ""
    say "Стек снят. НЕ удалено (это ваши данные):"
    say "  том с базой и вложениями; найти: docker volume ls | grep karexo-data"
    say "  $ENV_FILE - настройки и секреты"
    say ""
    say "Удалить данные НАВСЕГДА: cd \"$DIR\" && docker compose down -v"
    exit 0
fi

if [ "$MODE" = update ]; then
    [ -f "$COMPOSE_FILE" ] || die "рядом нет docker-compose.yml"
    [ -f "$ENV_FILE" ] || die "рядом нет .env - сначала обычная установка"
    say "Тяну свежий образ…"
    if ! compose pull 2>/dev/null; then
        # Закрытый контур: новый образ принесли `docker load`, реестра нет.
        say "Реестр недоступен - беру образ, который уже есть на машине."
    fi
    compose up -d
    # Порт берём из .env, а не из флага: при обновлении флагов обычно нет.
    up_port=$(sed -n "s/^KAREXO_PORT=//p" "$ENV_FILE" | head -n 1 | tr -d "'\"")
    say "Обновлено. $(http_get "http://127.0.0.1:${up_port:-8080}/healthz")"
    exit 0
fi

# ─── docker-compose.yml ──────────────────────────────────────────────────────

if [ ! -f "$COMPOSE_FILE" ]; then
    say "Рядом нет docker-compose.yml - скачиваю…"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE" || die "не удалось скачать $COMPOSE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$COMPOSE_FILE" "$COMPOSE_URL" || die "не удалось скачать $COMPOSE_URL"
    else
        die "нет ни curl, ни wget. Положите docker-compose.yml рядом со скриптом вручную"
    fi
fi

# ─── Опрос ───────────────────────────────────────────────────────────────────

# Спрашиваем только то, что не задано флагом или окружением. Ответ по Enter =
# значение в скобках.
ask() {
    _prompt="$1"; _default="$2"; _current="$3"
    if [ -n "$_current" ] || [ "$ASSUME_YES" = 1 ]; then
        printf '%s' "${_current:-$_default}"
        return
    fi
    if [ -n "$_default" ]; then
        printf '%s [%s]: ' "$_prompt" "$_default" >&2
    else
        printf '%s: ' "$_prompt" >&2
    fi
    read -r _answer </dev/tty || _answer=""
    printf '%s' "${_answer:-$_default}"
}

# То же, но без эха: пароль не должен остаться на экране и в скроллбеке.
ask_secret() {
    _prompt="$1"; _current="$2"
    if [ -n "$_current" ] || [ "$ASSUME_YES" = 1 ]; then
        printf '%s' "$_current"
        return
    fi
    printf '%s (ввод скрыт, Enter - пропустить): ' "$_prompt" >&2
    stty -echo 2>/dev/null || true
    read -r _answer </dev/tty || _answer=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$_answer"
}

# Существующий .env - источник умолчаний: повторный запуск не должен стирать
# то, что уже настроено руками. Значения там экранированы (см. q) - снимаем
# кавычки и удвоенные доллары, иначе они уедут в новый файл вторым слоем и
# попадут внутрь пароля.
prev() {
    [ -f "$ENV_FILE" ] || return 0
    unq "$(sed -n "s/^$1=//p" "$ENV_FILE" | head -n 1)"
}

if [ -f "$ENV_FILE" ]; then
    say "Нашёл $ENV_FILE - подставляю оттуда то, что уже задано."
    say ""
fi

say "── Обязательное ───────────────────────────────────────────────"
base_url=$(ask "Адрес, по которому karexo открывают из браузера" "$(prev KAREXO_BASE_URL)" "$base_url")
[ -n "$base_url" ] || die "KAREXO_BASE_URL обязателен: он уходит в письма и публичные ссылки"
case "$base_url" in
    http://*|https://*) ;;
    *) die "адрес должен начинаться с http:// или https:// - сейчас «$base_url»" ;;
esac
case "$base_url" in
    */) base_url="${base_url%/}" ;;
esac

# Ключ шифрования токенов генерируем САМИ. Спрашивать его - значит получить
# «karexo123»: человек видит поле, не понимает, зачем оно, и вписывает слово.
token_key="${token_key:-$(prev KAREXO_TOKEN_KEY)}"
if [ -z "$token_key" ]; then
    if command -v openssl >/dev/null 2>&1; then
        token_key=$(openssl rand -hex 32)
    elif [ -r /dev/urandom ]; then
        token_key=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    else
        die "нечем сгенерировать KAREXO_TOKEN_KEY: нет ни openssl, ни /dev/urandom"
    fi
    say "Ключ шифрования токенов интеграций сгенерирован."
fi

say ""
say "── Параметры ──────────────────────────────────────────────────"
port=$(ask "Порт на этой машине" "$(prev KAREXO_PORT)" "${port:-}")
port="${port:-8080}"
case "$port" in
    ''|*[!0-9]*) die "порт должен быть числом - сейчас «$port»" ;;
esac
registration=$(ask "Кто может завести аккаунт (open|invite|closed)" "$(prev KAREXO_REGISTRATION)" "${registration:-}")
registration="${registration:-invite}"
case "$registration" in
    open|invite|closed) ;;
    *) die "KAREXO_REGISTRATION: ожидается open, invite или closed - сейчас «$registration»" ;;
esac
edition=$(ask "Редакция (self-hosted|enterprise)" "$(prev KAREXO_EDITION)" "${edition:-}")
edition="${edition:-self-hosted}"
case "$edition" in
    self-hosted|enterprise) ;;
    *) die "KAREXO_EDITION: ожидается self-hosted или enterprise - сейчас «$edition»" ;;
esac
tag=$(ask "Версия образа" "$(prev KAREXO_TAG)" "${tag:-}")

say ""
say "── Почта (без неё не уходят коды входа и приглашения) ──────────"
smtp_host=$(ask "SMTP-сервер (Enter - пропустить)" "$(prev KAREXO_SMTP_HOST)" "$smtp_host")
if [ -n "$smtp_host" ]; then
    smtp_port=$(ask "  порт" "$(prev KAREXO_SMTP_PORT)" "${smtp_port:-}")
    smtp_port="${smtp_port:-587}"
    smtp_user=$(ask "  пользователь" "$(prev KAREXO_SMTP_USER)" "$smtp_user")
    smtp_pass=$(ask_secret "  пароль" "${smtp_pass:-$(prev KAREXO_SMTP_PASS)}")
    smtp_from=$(ask "  от кого приходят письма" "$(prev KAREXO_SMTP_FROM)" "${smtp_from:-$smtp_user}")
fi

say ""
say "── Владелец инстанса ──────────────────────────────────────────"
# Спрашиваем ПОСЛЕ режима регистрации намеренно: цена пропуска у них разная.
# При open владелец назначится сам (первой регистрацией), при invite и closed
# формы регистрации нет вовсе и приглашать первого человека некому - пропуск
# оставляет инстанс без единственного входа.
if [ "$registration" = open ]; then
    say "Заведём учётку сразу - иначе владельцем станет тот, кто ПЕРВЫМ откроет"
    say "адрес и зарегистрируется. На публичном адресе это гонка с кем угодно."
else
    say "Регистрация «$registration»: формы «Зарегистрироваться» на инстансе не будет,"
    say "а пригласить первого человека некому - база пуста. Без этой учётки войти"
    say "в поднятый инстанс будет НЕЧЕМ."
fi
owner_email=$(ask "Почта владельца (Enter - пропустить)" "" "$owner_email")
if [ -n "$owner_email" ]; then
    owner_name=$(ask "  имя" "" "$owner_name")
    owner_pass=$(ask_secret "  пароль (не короче 8 символов)" "$owner_pass")
    if [ ${#owner_pass} -lt 8 ]; then
        die "пароль владельца короче 8 символов"
    fi
fi

say ""
say "── HTTPS ──────────────────────────────────────────────────────"
say "off  - перед karexo стоит nginx/traefik/Caddy, шифрует он"
say "auto - karexo сам берёт сертификат Let's Encrypt (нужны домен и порты 80/443 наружу)"
say "file - свой сертификат: путь укажете в .env (KAREXO_TLS_CERT / KAREXO_TLS_KEY)"
tls=$(ask "Режим" "$(prev KAREXO_TLS)" "${tls:-}")
tls="${tls:-off}"
case "$tls" in
    off|auto|file) ;;
    *) die "KAREXO_TLS: ожидается off, auto или file - сейчас «$tls»" ;;
esac
if [ "$tls" = auto ]; then
    tls_domain=$(ask "  домен сертификата (без https:// и порта)" "$(prev KAREXO_TLS_DOMAIN)" "$tls_domain")
    [ -n "$tls_domain" ] || die "для KAREXO_TLS=auto нужен KAREXO_TLS_DOMAIN"
    tls_email=$(ask "  почта для писем об истечении" "$(prev KAREXO_TLS_EMAIL)" "$tls_email")
    # Let's Encrypt - обращение к чужому серверу. В закрытом контуре его нет, и
    # инстанс об этом скажет отказом при старте; предупреждаем заранее.
    if [ "$edition" = enterprise ] || [ "$allow_outbound" = false ]; then
        die "KAREXO_TLS=auto несовместим с закрытым контуром: сертификат берётся у Let's Encrypt.
     Возьмите режим file (свой сертификат) или снимите --offline / edition=enterprise"
    fi
fi

# ─── Запись .env ─────────────────────────────────────────────────────────────

put() {
    [ -n "$2" ] || return 0
    printf '%s="%s"\n' "$1" "$(q "$2")" >> "$ENV_FILE.tmp"
}

: > "$ENV_FILE.tmp"
# Права ДО записи: между созданием файла и chmod секрет уже лежал бы на диске
# читаемым для всех.
chmod 600 "$ENV_FILE.tmp"

cat >> "$ENV_FILE.tmp" <<'HEAD'
# karexo - настройки инстанса. Файл создан install.sh.
#
# ⚠️ Внутри пароль от почты и ключ шифрования: права 600, в git не класть.
#
# Полный список настроек - в env.example рядом. Здесь только заданное при
# установке; остальное берёт умолчания.
#
# После правки: docker compose up -d

HEAD

put KAREXO_BASE_URL "$base_url"
put KAREXO_TOKEN_KEY "$token_key"
put KAREXO_PORT "$port"
put KAREXO_TAG "$tag"
put KAREXO_REGISTRATION "$registration"
put KAREXO_EDITION "$edition"
put KAREXO_SMTP_HOST "$smtp_host"
put KAREXO_SMTP_PORT "$smtp_port"
put KAREXO_SMTP_USER "$smtp_user"
put KAREXO_SMTP_PASS "$smtp_pass"
put KAREXO_SMTP_FROM "$smtp_from"
put KAREXO_TLS "$tls"
put KAREXO_TLS_DOMAIN "$tls_domain"
put KAREXO_TLS_EMAIL "$tls_email"
put KAREXO_TRUST_PROXY "$trust_proxy"
put KAREXO_INSTANCE_LIMIT "$instance_limit"
put KAREXO_LICENSE "$license"
put KAREXO_ALLOW_OUTBOUND "$allow_outbound"

# Старый .env не затираем, а отодвигаем: если человек правил его руками, а
# скрипт чего-то не спросил, значения останутся рядом и их видно.
if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.bak"
    chmod 600 "$ENV_FILE.bak"
fi
mv "$ENV_FILE.tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"

say ""
say "Настройки записаны: $ENV_FILE"
if [ -f "$ENV_FILE.bak" ]; then
    say "Прежние сохранены рядом: $ENV_FILE.bak"
fi

if [ "$MODE" = env ]; then
    say ""
    say "Поднять вручную: docker compose up -d"
    exit 0
fi

# ─── Запуск ──────────────────────────────────────────────────────────────────

say ""
say "Поднимаю инстанс…"
# Тянем образ, но НЕ падаем, если не вышло: в закрытом контуре его приносят
# `docker load` из архива, реестра там нет вовсе - а инструкция по оффлайн-
# установке зовёт ровно этот скрипт. Нет образа и локально - об этом честно
# скажет `up`, ему для этого нечего подсказывать.
if ! compose pull 2>/dev/null; then
    say "Реестр недоступен - беру образ, который уже есть на машине."
fi
compose up -d

# «Установлено успешно» при упавшем контейнере - худший из возможных ответов,
# поэтому дожидаемся ответа от самого сервера.
say "Жду ответа сервера…"
i=0
health=""
while [ $i -lt 30 ]; do
    health=$(http_get "http://127.0.0.1:$port/healthz")
    if [ -n "$health" ]; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

say ""
if [ -z "$health" ]; then
    warn "Сервер не ответил за 30 секунд."
    say "Что смотреть:"
    say "  cd \"$DIR\" && docker compose logs --tail 50"
    exit 1
fi

say "✅ karexo поднят. $health"

# Владельца заводит сам сервер той же командой, что и мастер для Windows:
# правило «первая учётка - владелец» живёт в его INSERT, и повторять его в
# скрипте значило бы завести вторую копию правила.
#
# Пароль уходит в stdin контейнера (-T без псевдотерминала), а не аргументом:
# аргументы видно в `docker inspect` и в списке процессов хоста.
owner_done=""
if [ -n "$owner_email" ]; then
    say ""
    say "Завожу учётную запись владельца…"
    if printf '%s
' "$owner_pass" | compose exec -T karexo         karexo-server -create-owner -data /data         -owner-email "$owner_email" -owner-name "$owner_name"; then
        owner_done="да"
    else
        # Код 10 - «учётки уже есть»: повторная установка поверх рабочего
        # инстанса, ронять из-за этого нечего. Не 2: кодом 2 отвечает сам Go на
        # неизвестный флаг, и старый образ выдавал бы «уже есть» вместо отказа.
        if [ $? -eq 10 ]; then
            say "Учётные записи уже есть - владельца не трогал."
        else
            # Отсылаем к повтору той же команды, а не «зарегистрируйтесь первым»:
            # при invite и closed формы регистрации на инстансе нет.
            warn "Владельца завести не вышло. Повторите вручную:"
            warn "  cd \"$DIR\" && printf '%s\\n' 'пароль' | docker compose exec -T karexo \\"
            warn "      karexo-server -create-owner -data /data -owner-email $owner_email"
        fi
    fi
fi

say ""
say "Дальше:"
if [ -n "$owner_done" ]; then
    say "  1. Откройте $base_url и войдите: $owner_email"
elif [ "$registration" = open ]; then
    say "  1. Откройте $base_url - ПЕРВЫЙ зарегистрированный аккаунт становится владельцем"
else
    # Владельца не завели, а регистрация закрыта: войти сейчас нечем, и молчать
    # об этом нельзя - человек упрётся в форму входа без единой учётки.
    say "  1. Владельца нет, а регистрация «$registration» - войти НЕЧЕМ. Заведите его:"
    say "     cd \"$DIR\" && printf '%s\\n' 'пароль' | docker compose exec -T karexo \\"
    say "         karexo-server -create-owner -data /data -owner-email you@example.org"
fi
[ -z "$smtp_host" ] && say "  2. Почта не настроена: коды входа и приглашения уходить не будут (KAREXO_SMTP_* в .env)"
say ""
say "  данные:    том с базой и вложениями (docker volume ls | grep karexo-data)"
say "  настройки: $ENV_FILE"
say "  журнал:    cd \"$DIR\" && docker compose logs -f"
say "  обновить:  cd \"$DIR\" && ./install.sh --update"
