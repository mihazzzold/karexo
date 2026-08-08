#!/bin/sh
#
# Установка и обновление karexo на Linux с systemd.
#
# Ставит один файл: приложение внутри него, папки со статикой рядом нет.
# Повторный запуск = обновление: бинарь подменяется, служба перезапускается,
# данные и настройки не трогаются.
#
#   sudo ./install.sh              поставить или обновить
#   sudo ./install.sh --uninstall  снять службу (данные остаются)
#
# Намеренно /bin/sh, а не bash: на минимальных образах (alpine, debian-slim)
# bash может не стоять, а установщик обязан работать там, куда его принесли.

set -eu

BIN_SRC="${BIN_SRC:-./karexo-server}"
BIN_DST=/usr/local/bin/karexo-server
UNIT_SRC="${UNIT_SRC:-./karexo.service}"
UNIT_DST=/etc/systemd/system/karexo.service
ENV_DIR=/etc/karexo
ENV_FILE="$ENV_DIR/karexo.env"
DATA_DIR=/var/lib/karexo
USER_NAME=karexo

say() { printf '%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "нужны права root: запустите через sudo"
command -v systemctl >/dev/null 2>&1 || die "systemd не найден - этот скрипт для систем с systemd"

if [ "${1:-}" = "--uninstall" ]; then
    say "Останавливаю службу…"
    systemctl disable --now karexo 2>/dev/null || true
    rm -f "$UNIT_DST"
    systemctl daemon-reload
    rm -f "$BIN_DST"
    say ""
    say "Служба снята. НЕ удалены (это ваши данные):"
    say "  $DATA_DIR   - база и вложения"
    say "  $ENV_FILE   - настройки"
    exit 0
fi

[ -f "$BIN_SRC" ] || die "не найден $BIN_SRC - запускайте скрипт из распакованного архива"
[ -f "$UNIT_SRC" ] || die "не найден $UNIT_SRC - запускайте скрипт из распакованного архива"

# Обновление или первая установка: от этого зависит, что сказать в конце.
FIRST_RUN=1
[ -f "$BIN_DST" ] && FIRST_RUN=0

# Служебный пользователь без домашнего каталога и без входа в систему: karexo
# не нужен ни shell, ни почта, а чем меньше у службы есть, тем меньше достанется
# тому, кто однажды найдёт в ней дыру.
if ! id "$USER_NAME" >/dev/null 2>&1; then
    say "Создаю пользователя $USER_NAME…"
    useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" 2>/dev/null \
        || adduser --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" 2>/dev/null \
        || die "не удалось создать пользователя $USER_NAME"
fi

say "Кладу каталоги…"
mkdir -p "$DATA_DIR" "$ENV_DIR"
chown "$USER_NAME:$USER_NAME" "$DATA_DIR"
# Настройки читает root (systemd) и содержат они пароль от почты - чужим глазам
# там делать нечего.
chmod 750 "$ENV_DIR"

# Ключ шифрования токенов генерируем САМИ при первой установке. Иначе человек
# либо пропустит шаг (и токены интеграций лягут нечитаемыми после перезапуска),
# либо придумает «karexo123». Меняется он потом руками, если понадобится.
if [ ! -f "$ENV_FILE" ]; then
    say "Создаю $ENV_FILE…"
    if command -v openssl >/dev/null 2>&1; then
        TOKEN_KEY=$(openssl rand -hex 32)
    else
        TOKEN_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    [ -n "$TOKEN_KEY" ] || die "не удалось сгенерировать ключ шифрования"
    cat > "$ENV_FILE" <<EOF
# Настройки karexo. Меняются здесь, затем: systemctl restart karexo
#
# Внешний адрес инстанса - уходит в письма и публичные ссылки.
# Без него приглашение приведёт человека не туда.
KAREXO_BASE_URL=http://localhost:8080

# Ключ шифрования токенов интеграций. Сгенерирован при установке.
# Смена ключа делает сохранённые токены нечитаемыми - интеграции придётся
# подключать заново.
KAREXO_TOKEN_KEY=$TOKEN_KEY

# open | invite | closed - кто может завести аккаунт
KAREXO_REGISTRATION=invite

# Почта: без неё не уходят коды входа и приглашения
#KAREXO_SMTP_HOST=
#KAREXO_SMTP_PORT=587
#KAREXO_SMTP_USER=
#KAREXO_SMTP_PASS=
#KAREXO_SMTP_FROM=

# За обратным прокси (nginx/Caddy), который терминирует TLS:
#KAREXO_TRUST_PROXY=true

# Полный список настроек - в .env.example рядом с этим скриптом.
EOF
    chmod 640 "$ENV_FILE"
    chown root:"$USER_NAME" "$ENV_FILE"
fi

say "Ставлю бинарь…"
# Через временный файл и mv: подмена работающего бинаря на месте обрывает
# запущенный процесс на середине, а mv в пределах одной файловой системы
# атомарен - служба доработает до перезапуска на старом коде.
install -m 0755 "$BIN_SRC" "$BIN_DST.new"
mv -f "$BIN_DST.new" "$BIN_DST"

say "Ставлю службу…"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload
systemctl enable karexo >/dev/null 2>&1 || true
systemctl restart karexo

# Дать службе секунду и проверить, что она правда поднялась: «установлено
# успешно» при упавшем процессе - худший из возможных ответов.
sleep 2
if ! systemctl is-active --quiet karexo; then
    say ""
    say "Служба не запустилась. Последние строки журнала:"
    journalctl -u karexo -n 20 --no-pager 2>/dev/null || true
    die "разберитесь с журналом и запустите скрипт снова"
fi

VERSION=$("$BIN_DST" -version 2>/dev/null || echo "")
say ""
if [ "$FIRST_RUN" = "1" ]; then
    say "✅ karexo установлен и запущен. ${VERSION}"
    say ""
    say "Дальше:"
    say "  1. Впишите свой адрес в $ENV_FILE (KAREXO_BASE_URL)"
    say "  2. systemctl restart karexo"
    say "  3. Откройте адрес и зарегистрируйтесь - ПЕРВЫЙ аккаунт становится владельцем"
else
    say "✅ karexo обновлён и перезапущен. ${VERSION}"
fi
say ""
say "  журнал:    journalctl -u karexo -f"
say "  данные:    $DATA_DIR"
say "  настройки: $ENV_FILE"
