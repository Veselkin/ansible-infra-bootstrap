#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Bootstrap сервера для Ansible (двухэтапный) ===${NC}"

# ---- Ввод данных ----
read -p "Введите IP-адрес сервера: " SERVER_IP
read -p "Введите логин для подключения (по умолчанию root): " LOGIN
LOGIN=${LOGIN:-root}
read -sp "Введите пароль для $LOGIN: " PASSWORD
echo
read -p "Введите имя нового пользователя (по умолчанию sysops): " NEW_USER
NEW_USER=${NEW_USER:-sysops}

# ---- Проверка sshpass ----
if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}sshpass не найден. Установите:${NC}"
    echo "  sudo apt install sshpass   # Debian/Ubuntu"
    echo "  sudo yum install sshpass   # CentOS/RHEL"
    exit 1
fi

# ---- Общие опции SSH для игнорирования known_hosts ----
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ---- Генерация ключей (если нет) ----
KEY_DIR="$HOME/.ssh"
KEY_FILE="$KEY_DIR/$NEW_USER"
if [ ! -f "$KEY_FILE" ]; then
    echo "Генерация SSH-ключа для $NEW_USER (ed25519)..."
    mkdir -p "$KEY_DIR"
    ssh-keygen -t ed25519 -C "$NEW_USER" -f "$KEY_FILE" -N "" 2>/dev/null || {
        echo -e "${YELLOW}ed25519 не поддерживается, генерируем RSA 4096...${NC}"
        ssh-keygen -t rsa -b 4096 -C "$NEW_USER" -f "$KEY_FILE" -N ""
    }
    chmod 700 "$KEY_DIR"
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"
else
    echo "Ключ уже существует: $KEY_FILE"
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

# Копирование и запуск первого скрипта
echo "Копирование и запуск скрипта создания пользователя..."
sshpass -p "$PASSWORD" scp $SSH_OPTS /tmp/setup_user.sh "$LOGIN@$SERVER_IP:/tmp/"
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "sudo bash /tmp/setup_user.sh '$PUBLIC_KEY' '$NEW_USER'"
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "rm -f /tmp/setup_user.sh"
rm -f /tmp/setup_user.sh

# ---- Проверка доступа по ключу (до изменения SSH) ----
echo -e "\n${GREEN}Проверка подключения по SSH-ключу...${NC}"
if ssh -i "$KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no $SSH_OPTS "$NEW_USER@$SERVER_IP" "echo OK" 2>/dev/null | grep -q OK; then
    echo -e "${GREEN}✅ Ключ работает!${NC}"
else
    echo -e "${RED}❌ Не удалось подключиться по ключу. Отмена настройки SSH.${NC}"
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

# Копирование и запуск второго скрипта
echo "Копирование и запуск скрипта настройки SSH..."
sshpass -p "$PASSWORD" scp $SSH_OPTS /tmp/setup_ssh.sh "$LOGIN@$SERVER_IP:/tmp/"
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "sudo bash /tmp/setup_ssh.sh '$NEW_USER'"
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$LOGIN@$SERVER_IP" "rm -f /tmp/setup_ssh.sh"
rm -f /tmp/setup_ssh.sh

# ---- Финальная проверка ----
echo -e "\n${GREEN}Финальная проверка подключения по ключу...${NC}"
if ssh -i "$KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no $SSH_OPTS "$NEW_USER@$SERVER_IP" "echo OK" 2>/dev/null | grep -q OK; then
    echo -e "${GREEN}✅ Всё работает! Сервер готов для Ansible.${NC}"
    echo "Подключайтесь: ssh -i $KEY_FILE $NEW_USER@$SERVER_IP"
else
    echo -e "${RED}❌ Не удалось подключиться после настройки SSH. Возможно, что-то пошло не так.${NC}"
    echo "Попробуйте восстановить доступ через консоль провайдера."
    exit 1
fi