# Ansible: hostname и кастомный MOTD

Плейбук задаёт hostname из inventory и полностью заменяет MOTD на собственный: отключает все стандартные скрипты `/etc/update-motd.d/` (включая рекламу ESM / Ubuntu Pro) и ставит один свой шаблон с ASCII-баннером.

## Что делает

1. Устанавливает hostname равным `inventory_hostname`.
2. Обновляет запись `127.0.1.1` в `/etc/hosts` (только если hostname изменился, с бэкапом).
3. На Debian-семействе:
   - переименовывает все скрипты в `/etc/update-motd.d/` в `*.disabled`;
   - устанавливает `figlet`;
   - разворачивает шаблон `motd_custom.j2` как `/etc/update-motd.d/99-custom-motd`;
   - очищает кэш MOTD (`/run/motd.dynamic`, `/var/lib/update-notifier/updates-available`);
   - отключает `apt_news` в Ubuntu Pro (`pro config set apt_news=false`).

## Требования

- Ansible 2.9+ (используются `ansible.builtin.*`)
- Целевые хосты: Debian / Ubuntu (блок с MOTD выполняется только для `os_family == Debian`)
- Доступ по SSH и права `sudo` (`become: yes`)
- Файл шаблона `motd_custom.j2` рядом с плейбуком или в `templates/`

## Структура

```
.
├── hostname-motd.yaml
└── templates/
    └── motd_custom.j2
```

## Переменные

| Переменная         | По умолчанию               | Описание                         |
|--------------------|----------------------------|----------------------------------|
| `motd_figlet_text` | `{{ inventory_hostname }}` | Текст ASCII-баннера в шапке MOTD |

## Пример inventory

```ini
[servers]
home-serv
vps-serv ansible_host=xxx.xxx.xxx.xxx
```

Имя хоста в inventory становится hostname на сервере.

## Запуск

```bash
# проверка без изменений
ansible-playbook -i inventory.ini hostname-motd.yaml --check --diff

# применить
ansible-playbook -i inventory.ini hostname-motd.yaml

# только на одном хосте
ansible-playbook -i inventory.ini hostname-motd.yaml --limit vps-serv
```

## Пример шаблона `motd_custom.j2`

```bash
#!/bin/sh
figlet "{{ motd_figlet_text }}"
echo
echo "Uptime : $(uptime -p)"
echo "Load   : $(cut -d' ' -f1-3 /proc/loadavg)"
echo "Disk / : $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
```

## Откат

Исходные скрипты не удаляются, а переименовываются. Чтобы вернуть, например:

```bash
sudo mv /etc/update-motd.d/10-help-text.disabled /etc/update-motd.d/10-help-text
```

Бэкапы `/etc/hosts` и шаблона лежат рядом с оригиналами (`backup: yes`).

## Примечания

- Команда `pro config set` есть только на Ubuntu с установленным `ubuntu-pro-client`; на остальных системах задача падает, но игнорируется (`ignore_errors`).
- Hostname меняется сразу, но уже открытые SSH-сессии покажут старое имя до переподключения.

## Лицензия

MIT