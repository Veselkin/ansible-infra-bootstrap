#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Bootstrap сервера для Ansible (двухэтапный) ===${NC}"

# ---- Проверка наличия необходимых утилит ----
echo -n "Проверка утилит: "
MISSING=()
for cmd in sshpass ssh scp ssh-keygen; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING+=("$cmd")
    fi
done
if [ ${#MISSING[@]} -eq 0 ]; then
    echo -e "${GREEN}✅ Все необходимые утилиты найдены.${NC}"
else
    echo -e "${RED}❌ Отсутствуют: ${MISSING[*]}. Установите их.${NC}"
    exit 1
fi

# ---- Ввод данных ----
read -p "Введите IP-адрес сервера: " SERVER_IP
read -p "Введите логин для подключения (по умолчанию root): " LOGIN
LOGIN=${LOGIN:-root}
read -sp "Введите пароль для $LOGIN: " PASSWORD
echo
read -p "Введите имя нового пользователя (по умолчанию sysops): " NEW_USER
NEW_USER=${NEW_USER:-sysops}

# ---- Проверка готовности (если ключ уже работает) ----
KEY_DIR="$HOME/.ssh"
KEY_FILE="$KEY_DIR/$NEW_USER"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

if [ -f "$KEY_FILE" ]; then
    echo -n "Проверка, не настроен ли уже сервер для $NEW_USER: "
    if ssh -i "$KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no $SSH_OPTS "$NEW_USER@$SERVER_IP" "echo OK" 2>/dev/null | grep -q OK; then
        echo -e "${GREEN}✅ Сервер уже настроен. Выход.${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠️ Ключ есть, но подключение не удалось. Продолжаем настройку...${NC}"
    fi
fi

# ---- Проверка доступности порта 22 ----
echo -n "Проверка порта 22 на $SERVER_IP: "
if command -v nc &> /dev/null; then
    if nc -zv -w 3 "$SERVER_IP" 22 &> /dev/null; then
        echo -e "${GREEN}✅ Доступен.${NC}"
    else
        echo -e "${RED}❌ Недоступен.${NC}"
        exit 1
    fi
elif (exec 3<>/dev/tcp/"$SERVER_IP"/22) 2>/dev/null; then
    echo -e "${GREEN}✅ Доступен.${NC}"
    exec 3<&-
else
    echo -e "${YELLOW}⚠️ Не удалось проверить (nc или /dev/tcp не работают). Продолжаем...${NC}"
fi

# ---- Проверка возможности подключения с паролем ----
echo -n "Проверка подключения к $SERVER_IP с паролем: "
if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$LOGIN@$SERVER_IP" "exit" &> /dev/null; then
    echo -e "${GREEN}✅ Успешно.${NC}"
else
    echo -e "${RED}❌ Не удалось подключиться. Проверьте логин/пароль.${NC}"
    exit 1
fi

# ---- Генерация ключей (если нет) ----
if [ ! -f "$KEY_FILE" ]; then
    echo -n "Генерация SSH-ключа для $NEW_USER (ed25519): "
    mkdir -p "$KEY_DIR"
    if ssh-keygen -t ed25519 -C "$NEW_USER" -f "$KEY_FILE" -N "" 2>/dev/null; then
        echo -e "${GREEN}✅ Сгенерирован.${NC}"
    else
        echo -e "${YELLOW}⚠️ ed25519 не поддерживается, пробуем RSA 4096...${NC}"
        if ssh-keygen -t rsa -b 4096 -C "$NEW_USER" -f "$KEY_FILE" -N ""; then
            echo -e "${GREEN}✅ Сгенерирован RSA.${NC}"
        else
            echo -e "${RED}❌ Ошибка генерации ключа.${NC}"
            exit 1
        fi
    fi
    chmod 700 "$KEY_DIR"
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"
else
    echo -e "Ключ уже существует: ${GREEN}$KEY_FILE${NC}"
fi
PUBLIC_KEY=$(cat "$KEY_FILE.pub")

# ---- ЭТАП 1: Создание пользователя и установка ключа ----
echo -e "\n${GREEN}Этап 1: Создание пользователя $NEW_USER и добавление ключа${NC}"

cat > /tmp/setup_user.sh <<EOF
#!/bin/bash
set -e
PUBLIC_KEY="\$1"
NEW_USER="\$2"

# Определение группы sudo
if getent group sudo >/dev/null; then
    SUDO_GROUP="sudo"
elif getent group wheel >/dev/null; then
    SUDO_GROUP="wheel"
else
    groupadd sudo
    SUDO_GROUP="sudo"
fi

# Создание пользователя
if ! id -u "\$NEW_USER" >/dev/null 2>&1; then
    if command -v adduser &>/dev/null; then
        adduser --disabled-password --gecos "" "\$NEW_USER"
    else
        useradd -m -s /bin/bash "\$NEW_USER"
    fi
    echo "✅ Пользователь \$NEW_USER создан"
else
    echo "✅ Пользователь \$NEW_USER уже существует"
fi

# Добавление в группу sudo
if ! groups "\$NEW_USER" | grep -q "\$SUDO_GROUP"; then
    usermod -aG "\$SUDO_GROUP" "\$NEW_USER"
    echo "✅ Добавлен в группу \$SUDO_GROUP"
fi

# Настройка NOPASSWD
echo "\$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/\$NEW_USER
chmod 0440 /etc/sudoers.d/\$NEW_USER
visudo -cf /etc/sudoers.d/\$NEW_USER &>/dev/null || { echo "❌ Ошибка sudoers"; rm -f /etc/sudoers.d/\$NEW_USER; exit 1; }

# Установка публичного ключа
mkdir -p /home/\$NEW_USER/.ssh
echo "\$PUBLIC_KEY" > /home/\$NEW_USER/.ssh/authorized_keys
chown -R \$NEW_USER:\$NEW_USER /home/\$NEW_USER/.ssh
chmod 700 /home/\$NEW_USER/.ssh
chmod 600 /home/\$NEW_USER/.ssh/authorized_keys
echo "✅ Публичный ключ установлен"
EOF

# Копирование и запуск первого скрипта (подавляем stderr)
echo "Копирование и запуск скрипта создания пользователя..."
sshpass -p "$PASSWORD" scp $SSH_OPTS /tmp/setup_user.sh "$LOGIN@$SERVER_IP:/tmp/" 2>/dev/null
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "sudo bash /tmp/setup_user.sh '$PUBLIC_KEY' '$NEW_USER'" 2>/dev/null
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "rm -f /tmp/setup_user.sh" 2>/dev/null
rm -f /tmp/setup_user.sh

# ---- Проверка доступа по ключу (до изменения SSH) ----
echo -n "Проверка подключения по SSH-ключу: "
if ssh -i "$KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no $SSH_OPTS "$NEW_USER@$SERVER_IP" "echo OK" 2>/dev/null | grep -q OK; then
    echo -e "${GREEN}✅ Ключ работает!${NC}"
else
    echo -e "${RED}❌ Не удалось подключиться. Отмена настройки SSH.${NC}"
    exit 1
fi

# ---- ЭТАП 2: Настройка SSH (отключение пароля и т.д.) ----
echo -e "\n${GREEN}Этап 2: Настройка SSH (отключение пароля, разрешение только ключей)${NC}"

cat > /tmp/setup_ssh.sh <<'EOF'
#!/bin/bash
set -e
NEW_USER="$1"

BACKUP_FILE="/etc/ssh/sshd_config.$(date +%Y%m%d-%H%M%S).bak"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "✅ Бэкап создан: $BACKUP_FILE"

# Функция замены или добавления
replace_or_append() {
    local pattern="$1"
    local replacement="$2"
    local file="/etc/ssh/sshd_config"
    if grep -Eq "^\s*${pattern}" "$file"; then
        sed -i "s|^\s*${pattern}.*|${replacement}|" "$file"
    else
        echo "$replacement" >> "$file"
    fi
}

# Применяем настройки
sed -i 's|^\s*Include|#&|' /etc/ssh/sshd_config
sed -i 's|^\s*PermitRootLogin|#PermitRootLogin|' /etc/ssh/sshd_config
replace_or_append "PermitRootLogin" "PermitRootLogin prohibit-password"
replace_or_append "PasswordAuthentication" "PasswordAuthentication no"
replace_or_append "PubkeyAuthentication" "PubkeyAuthentication yes"
replace_or_append "AuthorizedKeysFile" "AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2"

if ! grep -q "^AllowUsers\s\+$NEW_USER" /etc/ssh/sshd_config; then
    echo "AllowUsers $NEW_USER" >> /etc/ssh/sshd_config
fi

replace_or_append "ClientAliveInterval" "ClientAliveInterval 60"
replace_or_append "ClientAliveCountMax" "ClientAliveCountMax 3"
replace_or_append "TCPKeepAlive" "TCPKeepAlive yes"

# Проверка синтаксиса
if ! sshd -t; then
    echo "❌ Ошибка конфигурации! Откат."
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    # Попытка перезапустить SSH после отката
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || true
    exit 1
fi

# ---- Универсальная перезагрузка SSH ----
echo "Перезагрузка SSH..."
if command -v systemctl &>/dev/null; then
    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
        echo "✅ SSH перезагружен через systemctl"
    else
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || {
            echo "❌ Не удалось перезагрузить SSH через systemctl"
            exit 1
        }
        echo "✅ SSH перезапущен через systemctl"
    fi
elif command -v service &>/dev/null; then
    if service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
        echo "✅ SSH перезагружен через service"
    else
        service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || {
            echo "❌ Не удалось перезагрузить SSH через service"
            exit 1
        }
        echo "✅ SSH перезапущен через service"
    fi
else
    # Отправляем HUP сигнал основному процессу
    PID=$(pgrep -x sshd | head -1)
    if [ -n "$PID" ]; then
        kill -HUP "$PID" && echo "✅ SSH перезагружен сигналом HUP"
    else
        echo "❌ Не найден процесс sshd, перезагрузка не удалась"
        exit 1
    fi
fi
EOF

# Копирование и запуск второго скрипта (подавляем stderr)
echo "Копирование и запуск скрипта настройки SSH..."
sshpass -p "$PASSWORD" scp $SSH_OPTS /tmp/setup_ssh.sh "$LOGIN@$SERVER_IP:/tmp/" 2>/dev/null
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "sudo bash /tmp/setup_ssh.sh '$NEW_USER'" 2>/dev/null
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "rm -f /tmp/setup_ssh.sh" 2>/dev/null
rm -f /tmp/setup_ssh.sh

# ---- Финальная проверка ----
echo -n "Финальная проверка подключения по ключу: "
if ssh -i "$KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no $SSH_OPTS "$NEW_USER@$SERVER_IP" "echo OK" 2>/dev/null | grep -q OK; then
    echo -e "${GREEN}✅ Всё работает! Сервер готов для Ansible.${NC}"
    echo "Подключайтесь: ssh -i $KEY_FILE $NEW_USER@$SERVER_IP"
else
    echo -e "${RED}❌ Не удалось подключиться после настройки SSH. Возможно, что-то пошло не так.${NC}"
    echo "Попробуйте восстановить доступ через консоль провайдера."
    exit 1
fi