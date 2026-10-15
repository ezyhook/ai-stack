# ai-stack

[Proton Lumo](https://lumo.proton.me/) в [Open WebUI](https://github.com/open-webui/open-webui) с терминалом для выполнения команд. Всё работает в rootless Podman.

| Сервис | Что делает | Порт (только 127.0.0.1) |
|---|---|---|
| [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer) | OpenAI-совместимый прокси к Lumo | 3003 |
| [open-terminal](https://github.com/open-webui/open-terminal) | Песочница, в которой модель запускает команды и работает с файлами | 8000 |
| [Open WebUI](https://github.com/open-webui/open-webui) | Веб-интерфейс чата | 8080 |

```
ноутбук ──ssh -L 8080──► Open WebUI ──► lumo-tamer ──► Proton Lumo
                              └──────► open-terminal
```

## Требования

- Linux с systemd (проверено на Ubuntu 24.04)
- `podman`, `git`, `openssl`
- compose-провайдер: `podman-compose` (рекомендуется) или `docker-compose`
- аккаунт Proton

```bash
sudo apt install podman podman-compose git openssl
```

## Установка

Запускайте под **обычным пользователем**, не root. Если вы переключаетесь на этого пользователя через `su`, сначала один раз выполните от root:

```bash
sudo loginctl enable-linger <пользователь>
```

Затем:

```bash
git clone https://github.com/ezyhook/ai-stack.git
cd ai-stack
./install.sh
```

Скрипт:

1. проверяет Podman, systemd user-сессию и linger, при необходимости включает `podman.socket` и автозапуск;
2. клонирует lumo-tamer в `./lumo-tamer`;
3. создаёт `secrets/lumo-vault-key`, `.env` и `config.yaml` со случайными ключами (существующие файлы не трогает);
4. собирает lumo-tamer и скачивает образы;
5. предлагает войти в Proton (`tamer auth login`);
6. запускает стек.

Повторный запуск `./install.sh` безопасен и работает как обновление.

Опции:

```bash
./install.sh --skip-login      # без входа в Proton
./install.sh --skip-start      # только подготовить и собрать
LUMO_TAMER_REF=v1.2.3 ./install.sh   # зафиксировать версию lumo-tamer
```

## Доступ с ноутбука

```bash
ssh -N -L 8080:127.0.0.1:8080 user@server
```

Откройте http://localhost:8080. **Первая зарегистрированная учётная запись становится администратором**, поэтому зарегистрируйтесь сразу.

## Подключение терминала

Делать ничего не нужно: Open Terminal подключается к Open WebUI автоматически для всех пользователей через переменную `TERMINAL_SERVER_CONNECTIONS` в `compose.yml`. Подключение видно в **Admin Panel → Settings → Integrations → Open Terminal**.

Проверка: в **новом** чате попросите «Выполни `ls -la ~` в терминале и покажи результат».

Работать с терминалом напрямую:

```bash
podman exec -it open-terminal bash
```

> Инструменты (tool calling) в lumo-tamer пока экспериментальные: Lumo может ошибаться в вызовах команд и неточно пересказывать их вывод.

## Что настроено для работы терминала

| Где | Настройка | Зачем |
|---|---|---|
| `config.yaml` | `server.customTools.enabled: true` | без неё lumo-tamer отбрасывает инструменты Open WebUI |
| `config.yaml` | `server.instructions.injectInto: "last"` | описание инструментов уходит в каждом запросе; при `"first"` Lumo «забывает» про терминал |
| `compose.yml` | `TERMINAL_SERVER_CONNECTIONS` | терминал подключён сразу, ручная настройка не нужна |
| `compose.yml` | `ENABLE_TITLE/TAGS/FOLLOW_UP/AUTOCOMPLETE_GENERATION=false` | фоновые запросы Open WebUI не расходуют лимит Lumo |
| `compose.yml` | `ENABLE_OLLAMA_API=false` | нет ошибок подключения к несуществующему Ollama |
| модель в Open WebUI | Function Calling: **Native** (по умолчанию с v0.10) | инструменты передаются в поле `tools`, которое понимает lumo-tamer |

`install.sh` проверяет существующий `config.yaml` и предупреждает, если первых двух настроек нет.

**Обновление существующей установки.** Флаги `ENABLE_*_GENERATION` и `ENABLE_OLLAMA_API` Open WebUI читает из переменных только при первом запуске, а дальше берёт из своей базы. На уже работающей установке выключите их вручную в **Admin Panel → Settings → Interface** и **Connections**. `TERMINAL_SERVER_CONNECTIONS` применяется при каждом запуске. Если терминал после обновления показан дважды, удалите тот, что добавляли вручную.

Советы:

- Просите конкретное действие («выполни `ls -la ~`»), а не «есть ли у тебя терминал?».
- Если Lumo отвечает, что терминала нет, начните **новый** чат: старая история тянет модель к прежнему ответу.
- Для отладки включите в `config.yaml` `log.level: debug`. Успешный вызов в `podman compose logs -f tamer` выглядит как `Tool call detected`, промах — как `Bouncing misrouted tool call`.

## Повседневные команды

```bash
podman compose ps
podman compose logs -f tamer
podman compose restart tamer              # после правки config.yaml
podman compose run --rm tamer auth login  # повторный вход в Proton
podman compose down                       # остановить (данные сохраняются)
```

## Файлы

| Файл | В git | Назначение |
|---|---|---|
| `compose.yml` | да | описание сервисов |
| `install.sh` | да | установка и обновление |
| `config.example.yaml` | да | шаблон конфигурации lumo-tamer |
| `.env.example` | да | шаблон ключей, портов, тегов образов |
| `config.yaml` | **нет** | конфигурация lumo-tamer ([все опции](https://github.com/ZeroTricks/lumo-tamer/blob/main/config.defaults.yaml)) |
| `.env` | **нет** | API-ключи |
| `secrets/lumo-vault-key` | **нет** | ключ шифрования токенов Proton. **Сделайте резервную копию** |
| `sessions/` | **нет** | зашифрованные токены |
| `lumo-tamer/` | **нет** | исходники, клонируются скриптом |

## Безопасность

- Все порты опубликованы только на `127.0.0.1`. Не меняйте это на `0.0.0.0` на сервере с публичным IP: open-terminal выполняет произвольные команды.
- Доступ к Open WebUI равен доступу к терминалу и к вашему аккаунту Lumo.
- Если ключ из `.env` скомпрометирован, сгенерируйте новый (`openssl rand -hex 24`), обновите `.env` и `config.yaml`, затем выполните `podman compose up -d`.

## Решение проблем

**`Cannot connect to the Docker daemon at unix:///run/user/…/podman.sock`.** Используется провайдер docker-compose, а сокет не запущен. Установите `podman-compose` или выполните `systemctl --user enable --now podman.socket`.

**`no systemd user session available` / ошибки про bus.** Добавьте в `~/.bashrc`:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
```

**Lumo отвечает «терминала у меня нет».** Проверьте две настройки из таблицы выше в `config.yaml`, выполните `podman compose restart tamer` и начните новый чат.

**`config.yaml is a directory`.** Podman создал каталог на месте отсутствующего файла. Удалите его (`rm -rf config.yaml`) и запустите `./install.sh` ещё раз.

**CAPTCHA при входе.** Сначала войдите в Proton обычным браузером с того же IP.

**Permission denied на `sessions/`.** Выполните `podman unshare chown -R 1000:1000 sessions`.

## Отказ от ответственности

lumo-tamer — неофициальный проект, не связанный с Proton. Его использование может нарушать условия Proton. Подробности в [README lumo-tamer](https://github.com/ZeroTricks/lumo-tamer#full-disclaimer).
