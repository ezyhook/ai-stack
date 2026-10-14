#!/usr/bin/env bash
# ai-stack installer: lumo-tamer + open-terminal + Open WebUI on rootless Podman.
# Safe to re-run: existing keys, configs and data are never overwritten.
set -euo pipefail

LUMO_TAMER_REPO="${LUMO_TAMER_REPO:-https://github.com/ZeroTricks/lumo-tamer.git}"
LUMO_TAMER_REF="${LUMO_TAMER_REF:-main}"

SKIP_LOGIN=0
SKIP_START=0

usage() {
  cat <<EOF
Использование: ./install.sh [опции]

  --skip-login   не запускать вход в Proton (tamer auth login)
  --skip-start   только подготовить и собрать, не запускать контейнеры
  -h, --help     эта справка

Переменные окружения:
  LUMO_TAMER_REPO   репозиторий lumo-tamer (по умолчанию: $LUMO_TAMER_REPO)
  LUMO_TAMER_REF    ветка/тег/коммит      (по умолчанию: $LUMO_TAMER_REF)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-login) SKIP_LOGIN=1 ;;
    --skip-start) SKIP_START=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестная опция: $arg" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_B=""; C_0=""
fi
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '%s  ✔ %s%s\n' "$C_OK" "$*" "$C_0"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_0"; }
die()  { printf '%s  ✘ %s%s\n' "$C_ERR" "$*" "$C_0" >&2; exit 1; }

gen_key() { openssl rand -hex 24; }

cd "$(dirname "$(readlink -f "$0")")"
STACK_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
step "Проверка окружения"

[ "$(id -u)" -ne 0 ] || die "Не запускайте от root. Стек рассчитан на rootless Podman: зайдите под обычным пользователем."

for cmd in podman git openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Не найдено: $cmd. Установите его и запустите скрипт снова."
done
ok "podman $(podman --version | awk '{print $3}'), git, openssl"

# systemd user session (missing after `su - user` / `sudo -u user`)
UID_NUM="$(id -u)"
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
  export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

# lingering: user services keep running without an active login
LINGER="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)"
if [ "$LINGER" != "yes" ]; then
  warn "Linger выключен: после выхода из системы контейнеры будут остановлены."
  if sudo -n true 2>/dev/null; then
    sudo loginctl enable-linger "$USER" && ok "Linger включён"
  else
    die "Выполните от root: loginctl enable-linger $USER
     затем перезайдите под $USER и запустите ./install.sh снова."
  fi
else
  ok "Linger включён"
fi

[ -d "$XDG_RUNTIME_DIR" ] || die "Нет $XDG_RUNTIME_DIR. Перезайдите под $USER (ssh или 'machinectl shell $USER@') после включения linger."

if ! systemctl --user is-system-running >/dev/null 2>&1 \
   && ! systemctl --user status >/dev/null 2>&1; then
  die "Нет доступа к systemd user-сессии. Добавьте в ~/.bashrc:
     export XDG_RUNTIME_DIR=/run/user/\$(id -u)
     export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus
   и перезайдите."
fi
ok "systemd user-сессия доступна (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)"

# compose provider
if command -v podman-compose >/dev/null 2>&1; then
  export PODMAN_COMPOSE_PROVIDER=podman-compose
  ok "Compose-провайдер: podman-compose"
elif [ -x /usr/libexec/docker/cli-plugins/docker-compose ] \
  || [ -x /usr/lib/docker/cli-plugins/docker-compose ] \
  || command -v docker-compose >/dev/null 2>&1; then
  ok "Compose-провайдер: docker-compose (через podman.socket)"
  if ! systemctl --user is-active --quiet podman.socket; then
    systemctl --user enable --now podman.socket
  fi
  [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ] || die "podman.socket не поднялся: systemctl --user status podman.socket"
  ok "podman.socket активен"
else
  die "Не найден compose-провайдер. Установите podman-compose (apt install podman-compose) или docker-compose."
fi

compose() { podman compose "$@"; }

# autostart containers with restart policy after reboot
systemctl --user enable --now podman-restart.service >/dev/null 2>&1 \
  && ok "podman-restart.service включён (автозапуск после перезагрузки)" \
  || warn "Не удалось включить podman-restart.service: автозапуск после перезагрузки не гарантирован"

# ---------------------------------------------------------------------------
# 2. lumo-tamer source
# ---------------------------------------------------------------------------
step "Исходники lumo-tamer ($LUMO_TAMER_REF)"

if [ -d lumo-tamer/.git ]; then
  git -C lumo-tamer fetch --quiet origin
  git -C lumo-tamer checkout --quiet "$LUMO_TAMER_REF"
  git -C lumo-tamer pull --quiet --ff-only origin "$LUMO_TAMER_REF" 2>/dev/null || true
  ok "Обновлено: $(git -C lumo-tamer rev-parse --short HEAD)"
else
  [ ! -e lumo-tamer ] || die "lumo-tamer/ существует, но это не git-репозиторий. Удалите или переименуйте его."
  git clone --quiet "$LUMO_TAMER_REPO" lumo-tamer
  git -C lumo-tamer checkout --quiet "$LUMO_TAMER_REF"
  ok "Склонировано: $(git -C lumo-tamer rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------------------
# 3. Secrets & config (never overwrite)
# ---------------------------------------------------------------------------
step "Ключи и конфигурация"

umask 077
mkdir -p secrets sessions
chmod 700 secrets

# Podman turns a missing bind-mount source into a directory: undo that.
for f in config.yaml secrets/lumo-vault-key; do
  if [ -d "$f" ]; then
    if [ -z "$(ls -A "$f")" ]; then
      rmdir "$f"; warn "$f был пустым каталогом (создан Podman) — удалён"
    else
      die "$f — непустой каталог. Разберитесь вручную."
    fi
  fi
done

if [ ! -s secrets/lumo-vault-key ]; then
  openssl rand -base64 32 > secrets/lumo-vault-key
  ok "Создан secrets/lumo-vault-key — сохраните его копию: без него токены не расшифровать"
else
  ok "secrets/lumo-vault-key уже есть"
fi
chmod 600 secrets/lumo-vault-key

if [ ! -f .env ]; then
  cp .env.example .env
  sed -i "s|^LUMO_API_KEY=.*|LUMO_API_KEY=$(gen_key)|" .env
  sed -i "s|^OPEN_TERMINAL_API_KEY=.*|OPEN_TERMINAL_API_KEY=$(gen_key)|" .env
  ok "Создан .env со случайными ключами"
else
  ok ".env уже есть"
fi
chmod 600 .env

# shellcheck disable=SC1091
set -a; . ./.env; set +a
[ -n "${LUMO_API_KEY:-}" ] || die "LUMO_API_KEY пуст в .env"
[ -n "${OPEN_TERMINAL_API_KEY:-}" ] || die "OPEN_TERMINAL_API_KEY пуст в .env"

if [ ! -f config.yaml ]; then
  sed "s|__LUMO_API_KEY__|${LUMO_API_KEY}|" config.example.yaml > config.yaml
  ok "Создан config.yaml"
else
  CFG_KEY="$(grep -m1 'apiKey:' config.yaml | sed 's/.*apiKey: *"\{0,1\}//;s/".*//')"
  if [ "$CFG_KEY" != "$LUMO_API_KEY" ]; then
    warn "apiKey в config.yaml не совпадает с LUMO_API_KEY в .env — Open WebUI не сможет обратиться к Lumo"
  else
    ok "config.yaml уже есть, ключ совпадает с .env"
  fi
fi
chmod 600 config.yaml
umask 022

# ---------------------------------------------------------------------------
# 4. Build & pull
# ---------------------------------------------------------------------------
step "Сборка lumo-tamer и загрузка образов"
compose build tamer
compose pull open-terminal open-webui
ok "Образы готовы"

# ---------------------------------------------------------------------------
# 5. Proton login
# ---------------------------------------------------------------------------
if [ "$SKIP_LOGIN" -eq 0 ]; then
  step "Вход в Proton"
  if [ ! -t 0 ]; then
    warn "Нет интерактивного терминала — вход пропущен. Позже: podman compose run --rm tamer auth login"
  else
    read -r -p "  Выполнить вход сейчас? [Y/n] " ans
    case "${ans:-y}" in
      [Nn]*) warn "Пропущено. Позже: podman compose run --rm tamer auth login" ;;
      *)
        echo "  Совет: если попросят CAPTCHA, сначала войдите в Proton обычным браузером с этого же IP."
        compose run --rm tamer auth login || warn "Вход не удался. Повторите: podman compose run --rm tamer auth login"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 6. Start
# ---------------------------------------------------------------------------
if [ "$SKIP_START" -eq 0 ]; then
  step "Запуск"
  compose up -d
  sleep 3
  compose ps

  if curl -fsS -o /dev/null -H "Authorization: Bearer $LUMO_API_KEY" http://127.0.0.1:3003/v1/models 2>/dev/null; then
    ok "lumo-tamer отвечает на :3003"
  else
    warn "lumo-tamer пока не отвечает: podman compose logs tamer"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
HOST_HINT="$(hostname -f 2>/dev/null || hostname)"
cat <<EOF

${C_B}Готово.${C_0}

  Open WebUI слушает только 127.0.0.1:8080. С ноутбука:
    ssh -N -L 8080:127.0.0.1:8080 <пользователь>@${HOST_HINT}
  и откройте http://localhost:8080 — первая зарегистрированная учётка станет администратором.

  Подключение терминала: Admin Panel → Settings → Integrations → Open Terminal
    URL:     http://open-terminal:8000
    API Key: значение OPEN_TERMINAL_API_KEY из ${STACK_DIR}/.env

  Полезное:
    podman compose logs -f tamer
    podman compose run --rm tamer auth login
    ./install.sh            # повторный запуск = обновление
EOF
