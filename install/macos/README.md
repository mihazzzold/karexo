# 🍎 Запуск karexo на macOS

Один файл: приложение внутри него, папки со статикой рядом нет.

⚠️ **Готового установщика для macOS пока нет.** Служба (launchd) и `.pkg` не сделаны намеренно:
для них нужна нотаризация Apple ($99/год), а пока karexo в бете, эти деньги честнее не тратить.
Ниже - запуск руками; он рабочий, просто требует пары команд.

---

## ⚠️ Сначала про предупреждение Gatekeeper

**macOS откажется запускать файл: «не удалось проверить разработчика».** Так и есть - бинарь не
подписан и не нотаризован.

Проверьте, что файл наш, и снимите карантин:

```bash
# 1. сверить с суммой со страницы выпусков
shasum -a 256 karexo-server

# 2. снять метку «скачано из интернета»
xattr -d com.apple.quarantine karexo-server
chmod +x karexo-server
```

Сумма не совпала - **не запускайте**, напишите нам.

---

## 🚀 Запуск

```bash
mkdir -p ~/karexo-data
KAREXO_DATA=~/karexo-data \
KAREXO_BASE_URL=http://localhost:8080 \
KAREXO_TOKEN_KEY=$(openssl rand -hex 32) \
./karexo-server -addr :8080
```

Откройте `http://localhost:8080`. **Первый зарегистрированный аккаунт становится владельцем.**

⚠️ Ключ шифрования здесь генерируется на лету - при следующем запуске он будет **другим**, и
токены интеграций перестанут читаться. Для постоянной работы сохраните его и задавайте тем же
значением; полный список настроек - в `env.example` рядом.

---

## 🔁 Автозапуск (по желанию)

Файл `~/Library/LaunchAgents/pro.karexo.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>pro.karexo.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/ВЫ/karexo/karexo-server</string>
    <string>-addr</string><string>:8080</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>KAREXO_DATA</key><string>/Users/ВЫ/karexo-data</string>
    <key>KAREXO_BASE_URL</key><string>http://localhost:8080</string>
    <key>KAREXO_TOKEN_KEY</key><string>ваш-ключ-из-openssl-rand-hex-32</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/pro.karexo.server.plist
```

---

## 💾 Данные

Всё лежит в каталоге `KAREXO_DATA`: база и вложения. Его и копируйте.

Проверить архив копии, не разворачивая:

```bash
./karexo-server -verify-backup /путь/к/копии.zip
```
