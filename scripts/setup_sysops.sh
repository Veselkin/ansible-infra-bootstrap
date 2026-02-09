#!/bin/bash
set -e

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запустите от sudo" >&2
    exit 1
fi

USER_NAME="sysops"

if ! id -u $USER_NAME >/dev/null 2>&1; then
    echo "Создание пользователя $USER_NAME..."
    adduser --disabled-password --gecos "" $USER_NAME
else
    echo "Пользователь $USER_NAME уже существует"
fi

# Настройка sudo без пароля
SUDOERS_FILE="/etc/sudoers.d/$USER_NAME"
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

# Проверка синтаксиса sudoers
if ! visudo -cf "$SUDOERS_FILE"; then
    echo "Ошибка в конфиге sudoers!"
    rm -f "$SUDOERS_FILE"
    exit 1
fi

echo "✓ Пользователь $USER_NAME готов к работе."