#!/usr/bin/env sh

# Скрипт запуска Velocity с проверкой ядра и автоматическим перезапуском.
# Запускайте из каталога, где лежат velocity-*.jar и java-args.

trap 'echo ""; echo "Получен сигнал остановки. Завершение скрипта..."; exit 0' INT TERM

while true; do
    SERVER_JARS=$(find . -maxdepth 1 -type f -name 'velocity-*.jar' -print | sort)
    SERVER_COUNT=$(printf '%s\n' "$SERVER_JARS" | grep -c '.')

    if [ "$SERVER_COUNT" -eq 0 ]; then
        echo "========================================"
        echo "ОШИБКА: ядро velocity-*.jar не найдено!"
        echo "========================================"
        exit 1
    fi

    if [ "$SERVER_COUNT" -gt 1 ]; then
        echo "========================================"
        echo "ОШИБКА: найдено несколько ядер Velocity!"
        echo "Количество: $SERVER_COUNT"
        echo ""
        echo "Найденные файлы:"
        printf '%s\n' "$SERVER_JARS"
        echo ""
        echo "Оставьте одно ядро Velocity в каталоге и запустите снова."
        echo "========================================"
        exit 1
    fi

    SERVER_JAR="$SERVER_JARS"

    if [ ! -f "./java-args" ]; then
        echo "========================================"
        echo "ОШИБКА: файл java-args не найден!"
        echo "Создайте его рядом со скриптом запуска."
        echo "========================================"
        exit 1
    fi

    if ! command -v java >/dev/null 2>&1; then
        echo "========================================"
        echo "ОШИБКА: команда java не найдена!"
        echo "Установите Java и проверьте PATH."
        echo "========================================"
        exit 1
    fi

    echo "========================================"
    echo "Запуск прокси Velocity: $SERVER_JAR"
    echo "Аргументы JVM: ./java-args"
    echo "========================================"

    java @java-args -jar "$SERVER_JAR"
    EXIT_CODE=$?

    echo ""
    echo "========================================"
    echo "Velocity завершился с кодом: $EXIT_CODE"
    echo "Перезапуск через 5 секунд..."
    echo "Нажмите Ctrl+C для полной остановки."
    echo "========================================"

    sleep 5
done
