#!/usr/bin/env sh

trap 'echo ""; echo "Остановка сервера..."; exit 0' INT TERM

while true; do
    SERVER_JARS=$(find . -maxdepth 1 -type f -name 'paper-*.jar' -print)
    SERVER_COUNT=$(printf '%s\n' "$SERVER_JARS" | grep -c '.')

    if [ "$SERVER_COUNT" -eq 0 ]; then
        echo "========================================"
        echo "ОШИБКА: ядро paper-*.jar не найдено!"
        echo "========================================"
        exit 1
    fi

    if [ "$SERVER_COUNT" -gt 1 ]; then
        echo "========================================"
        echo "ОШИБКА: найдено несколько ядер Paper!"
        echo "Количество: $SERVER_COUNT"
        echo ""
        echo "Найденные файлы:"
        printf '%s\n' "$SERVER_JARS"
        echo ""
        echo "Удалите лишние ядра и запустите сервер снова."
        echo "========================================"
        exit 1
    fi

    SERVER_JAR="$SERVER_JARS"

    echo "========================================"
    echo "Запуск сервера: $SERVER_JAR"
    echo "========================================"

    java @java-args -jar "$SERVER_JAR" --nogui

    echo ""
    echo "========================================"
    echo "Сервер остановлен."
    echo "Перезапуск через 5 секунд..."
    echo "Нажмите Ctrl+C для полной остановки."
    echo "========================================"

    sleep 5
done