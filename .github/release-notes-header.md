<!--
Постоянная часть заметок выпуска: как поставить. Меняется редко - в отличие от
«что нового», которое приезжает разделом из CHANGELOG.md рядом.

Лежит здесь, а не в репозитории с кодом, по двум причинам. Это текст для
ЧИТАТЕЛЯ, и место ему рядом с остальными такими текстами - правится он вместе с
ними. И вторая, практическая: пайп выпуска чекаутит ТЕГ, а тег снят раньше, чем
пишется шапка, - файла из свежего main в нём просто нет. Отсюда заметки едут по
raw-ссылке на main этого репозитория.

{{TAG}} подставляет пайп (.github/workflows/release.yml в karexo-core).
-->
## 🚀 Как поднять сервер

**Docker** - скачайте ниже `docker-compose.yml` и `env.example`, положите рядом, переименуйте второй в `.env` и впишите свои значения:

```bash
openssl rand -hex 32     # результат - в KAREXO_TOKEN_KEY
docker compose up -d
```

**Без Docker** - скачайте архив под свою систему:

| Файл | Для чего |
|---|---|
| `karexo_{{TAG}}_linux_amd64.tar.gz` | Linux x86-64: бинарь, `install.sh`, юнит systemd |
| `karexo_{{TAG}}_linux_arm64.tar.gz` | Linux ARM (Raspberry Pi, ARM-серверы) |
| `karexo_{{TAG}}_windows_amd64.tar.gz` | Windows: бинарь и `install.ps1` (ставит службу) |
| `karexo_{{TAG}}_darwin_arm64.tar.gz` | macOS на Apple Silicon |
| `karexo_{{TAG}}_docker.tar.gz` | контур **без интернета**: сохранённый образ и инструкция |

Подробно - [install/README.md](https://github.com/mihazzzold/karexo/blob/main/install/README.md), для закрытого контура - [install/OFFLINE.md](https://github.com/mihazzzold/karexo/blob/main/install/OFFLINE.md).

## 📱 Поставить karexo как приложение

Отдельных сборок под платформы не нужно - приложение ставится из браузера и работает своей иконкой, в своём окне, без адресной строки:

- **Android**: Chrome → меню (⋮) → «Установить приложение»
- **Windows, Linux, macOS**: Chrome или Edge → значок установки в адресной строке
- **iPhone, iPad**: Safari → «Поделиться» → «На экран "Домой"»

Оболочка открывается и **без сети**: заметки лежат на устройстве, синхронизация догонит, когда связь вернётся.

---
