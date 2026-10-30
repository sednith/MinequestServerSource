# Ночной рестарт PROD на systemd

## Что это

Ночной рестарт PROD выполняется на самом сервере тремя systemd-таймерами:

| Время (МСК) | Этап |
|---|---|
| 04:45 | `adjustment` — лобби |
| 05:00 | `playworld` — основной мир |
| 05:15 | `velocity` — прокси |

Каждый таймер запускает `prod-restart@<stage>.service`, а тот — уже существующий
`/home/server/prod/scripts/scheduled-restart.sh <stage>` из каталога `/home/server/prod`.
Логика этапов, идемпотентность по дате, проверка SHA и откат не менялись.

**Почему не cron в GitHub Actions.** Расписание `schedule:` в Actions работает
по принципу best-effort: запуск может задержаться на минуты и больше, а 30.10.2026
наблюдалась задержка примерно на 6 часов 30 минут. Для ночного окна это
неприемлемо, поэтому автоматику перенесли на сервер, а в workflow остался только
ручной запуск (`workflow_dispatch`).

## Состав файлов

| Файл | Назначение |
|---|---|
| `prod-restart@.service` | Шаблон юнита: запускает `scheduled-restart.sh %i` от `root` из `/home/server/prod` |
| `prod-restart-adjustment.timer` | Таймер этапа `adjustment` (04:45 MSK) |
| `prod-restart-playworld.timer` | Таймер этапа `playworld` (05:00 MSK) |
| `prod-restart-velocity.timer` | Таймер этапа `velocity` (05:15 MSK) |
| `install.sh` | Установка/обновление/удаление таймеров, опционально NTP |
| `set-schedule.sh` | Просмотр, проверка и применение другого времени этапов |

## Установка

Из корня чекаута на сервере:

```bash
sudo bash deploy/systemd/install.sh
```

Скрипт копирует юниты в `/etc/systemd/system`, делает `daemon-reload`,
включает и перезапускает таймеры (поэтому повторная установка подхватывает
изменения расписания), проверяет юниты через `systemd-analyze verify` и печатает
`systemctl list-timers 'prod-restart*' --all --no-pager`.

С настройкой синхронизации времени:

```bash
sudo bash deploy/systemd/install.sh --ntp
```

`--ntp` дополнительно создаёт drop-in `/etc/systemd/timesyncd.conf.d/50-minequest.conf`
(`time.cloudflare.com`), перезапускает `systemd-timesyncd` и ждёт до 60 секунд
синхронизации (`timedatectl show -p NTPSynchronized --value` = `yes`). Существующий
drop-in не перезаписывается.

Удаление:

```bash
sudo bash deploy/systemd/install.sh --uninstall
```

`--uninstall` не трогает данные PROD, `.scheduled-prod-restart-state` и NTP-конфиг
(последний удаляется только вместе с `--ntp`). Drop-in'ы расписания, созданные
`set-schedule.sh --apply`, удаляются вместе с таймерами — иначе они бы перебили
расписание после переустановки.

## Проверка

```bash
# список таймеров и их NEXT/LAST
systemctl list-timers 'prod-restart*' --all --no-pager

# статическая проверка юнитов (из корня чекаута)
systemd-analyze verify deploy/systemd/prod-restart@.service deploy/systemd/prod-restart-*.timer

# журнал всех этапов
journalctl -u 'prod-restart@*' --since today

# прогресс ночного рестарта
cat /home/server/prod/.scheduled-prod-restart-state
```

В `NEXT` должно быть 04:45 / 05:00 / 05:15 MSK.

## Смена расписания

```bash
# показать текущее расписание и NEXT (root не нужен)
bash deploy/systemd/set-schedule.sh

# показать план и проверить времена, ничего не меняя (root не нужен)
bash deploy/systemd/set-schedule.sh 04:30 04:45 05:00

# записать drop-in'ы и применить (нужен root)
sudo bash deploy/systemd/set-schedule.sh --apply 04:30 04:45 05:00
```

Ограничения:

- времена задаются по MSK и идут строго в порядке `adjustment -> playworld -> velocity`;
- минимальный зазор между этапами — 5 минут;
- окно — 03:00–02:59 MSK: скрипт этапов берёт дату по UTC, а 03:00 MSK = 00:00 UTC,
  поэтому времена за пределами окна ломают идемпотентность «один этап в сутки»;
- порядок этапов фиксирован: `adjustment -> playworld -> velocity`, поменять его
  расписанием нельзя.

При `--apply` сначала проверяется, что таймеры установлены и что новые времена
парсятся systemd, и только затем создаются drop-in'ы
`/etc/systemd/system/prod-restart-<stage>.timer.d/10-schedule.conf` с пустым
`OnCalendar=` (сброс базового значения), после чего выполняется `daemon-reload` и
перезапуск таймеров. Если таймеры не установлены, `--apply` завершится ошибкой,
не оставив частично применённое состояние.

## Логи и диагностика

```bash
journalctl -u 'prod-restart@*' -n 200 --no-pager
journalctl -u prod-restart@adjustment.service --since '04:40'
systemctl --failed
systemctl status prod-restart-adjustment.timer
timedatectl; timedatectl timesync-status
```

Если таймер отработал, а этап не прошёл, смотрите `.scheduled-prod-restart-state`
и журнал `scheduled-restart.sh`: при падении этапа PROD откатывается на last-good.

## Поведение при ребуте

`Persistent=false` — пропущенный из-за выключенной машины запуск **не догоняется**
(иначе рестарт мог бы прилететь среди дня). Автозапуска серверов нет:
screen-супервизоры (`startserver.sh`) после перезагрузки машины нужно поднять
руками, иначе ночной этап упадёт на отсутствии PID-файла.

## Окно деплоя

В 04:40–05:40 MSK не запускайте ни деплой, ни ручные рестарты:
`Scheduled PROD restart` с любым `stage` (`all`, `adjustment`, `playworld`,
`velocity`) и `Restart Minecraft Servers` (`environment=prod`).

Таймеры systemd не входят в concurrency-группу GitHub Actions: workflow и ночные
этапы не знают друг о друге. Возможна гонка за FIFO/PID, а также замена скриптов
в `/home/server/prod` во время выполнения этапа.

## Переход с root на отдельного пользователя

Сейчас `prod-restart@.service` работает от `root`, потому что серверы запущены
от `root`. Позже:

1. поменять `User=` в `prod-restart@.service` и переустановить юнит;
2. перезапустить супервизоры `startserver.sh` под этим пользователем;
3. сделать `chown -R <user> /home/server/prod`;
4. убедиться, что `secrets` читается этим пользователем (600 на владельца) —
   иначе не сработают `render-secrets.py` и `server_pid_is_valid`.

## Откат

```bash
sudo bash deploy/systemd/install.sh --uninstall
```

Затем вернуть блок `schedule:` в `.github/workflows/scheduled_prod_restart.yml`
(и `github.event_name == 'schedule'` в условиях job'ов).
