# Сборка Nginx с дополнительными модулями

Этот скрипт предназначен для сборки Nginx с дополнительными модулями для Ubuntu 22.04 (jammy) и 24.04 (noble), создавая Debian-пакеты, которые можно установить стандартными средствами apt.

## Особенности

- Автоматическое определение последней стабильной версии Nginx
- Сборка с дополнительными модулями, не включенными в официальные пакеты Ubuntu
- Создание отдельных пакетов для разных версий Ubuntu (`nginx-consultant-jammy`, `nginx-consultant-noble`)
- Соответствие стандартам Debian/Ubuntu для пакетов
- Используются стандартные пути файлов для совместимости с экосистемой Ubuntu

## Предустановленные модули

В сборку включены следующие дополнительные модули:

| Модуль | Описание |
|--------|----------|
| headers-more-filter | Управление HTTP-заголовками запросов/ответов |
| auth-pam | Аутентификация через PAM |
| cache-purge | Очистка кеша |
| dav-ext | Расширенная поддержка WebDAV |
| ndk | Набор инструментов разработки для Nginx |
| echo | Отладка и тестирование запросов |
| fancyindex | Улучшенный листинг директорий |
| nchan | Pub/Sub и push-уведомления в реальном времени |
| lua | Поддержка скриптов на Lua с LuaJIT |
| rtmp | Потоковое вещание (стриминг) |
| uploadprogress | Отслеживание прогресса загрузки файлов |
| subs-filter | Замена текста в ответах сервера |
| geoip2 | Геолокация по IP через MaxMind GeoIP2 |

## Стандартные модули Nginx

Кроме дополнительных модулей, включены все основные модули из полной сборки Nginx:
- HTTP SSL
- HTTP V2
- HTTP realip
- HTTP stub_status
- HTTP geoip (dynamic)
- HTTP image_filter (dynamic)
- HTTP xslt_filter (dynamic)
- HTTP addition_module
- HTTP sub_module
- Mail (dynamic)
- Stream (dynamic)
- и другие

## Использование

### Сборка пакетов

```bash
# Базовая сборка с включенным LTO
docker-compose up --build

# Сборка с отключенным LTO (для решения проблем совместимости на ARM)
DISABLE_LTO=1 docker-compose up --build
```

### Опции

- `DISABLE_LTO=1` - отключает Link Time Optimization, что может решить проблемы компиляции некоторых модулей, особенно на архитектуре ARM (Apple Silicon)

### Установка пакета

```bash
# Для Ubuntu 22.04
apt install ./nginx-consultant-jammy_*.deb

# Для Ubuntu 24.04
apt install ./nginx-consultant-noble_*.deb
```

## Примечания по установке

- Пакет конфликтует со стандартными пакетами Nginx в Ubuntu (`nginx`, `nginx-core`, `nginx-full`, `nginx-light`, `nginx-extras`, `nginx-mainline`). При установке любой из этих пакетов будет удален.
- Пакет использует стандартные пути для файлов и будет работать как замена стандартного Nginx:
  - Исполняемый файл: `/usr/sbin/nginx`
  - Модули: `/usr/lib/nginx/modules/*.so`
  - Конфигурация: `/etc/nginx/nginx.conf`
  - Логи: `/var/log/nginx/`
  - Временные директории: `/var/lib/nginx/`

## Решение проблем

### Ошибки компиляции с LTO

На некоторых архитектурах (особенно ARM) могут возникать ошибки компиляции при использовании Link Time Optimization (LTO). Если вы столкнулись с такими ошибками, попробуйте сборку с отключенным LTO:

```bash
DISABLE_LTO=1 docker-compose up --build
```

### Конфликты при установке

Если при установке возникают ошибки о конфликтах с существующими файлами, убедитесь, что все официальные пакеты Nginx удалены:

```bash
apt purge nginx nginx-core nginx-full nginx-light nginx-extras nginx-mainline
apt autoremove
```

## Структура пакета

Созданный пакет следует стандартам Debian и включает:
- Корректный control-файл с зависимостями
- Postinst-скрипт для настройки прав доступа
- Man-страницу для команды nginx
- Copyright-файл с информацией о лицензии
- Changelog с историей изменений 