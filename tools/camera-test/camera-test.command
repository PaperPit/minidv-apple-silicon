#!/bin/bash
#
#  Проверка камеры и микрофона в браузере.
#
#  Поднимает локальный сервер (на file:// Chrome иногда не даёт доступ к камере)
#  и открывает страницу проверки в Chrome. Закрыть окно терминала — сервер выключится.
#
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8765

if [ ! -f "$HERE/camera-test.html" ]; then
  echo "Рядом не найден camera-test.html"
  read -r -p "Нажмите Enter, чтобы закрыть…" _
  exit 1
fi

echo "Локальный сервер: http://localhost:$PORT/camera-test.html"
echo "Оставьте это окно открытым, пока проверяете. Ctrl+C — остановить."
( sleep 1; /usr/bin/open -a "Google Chrome" "http://localhost:$PORT/camera-test.html" ) &
exec /usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HERE"
