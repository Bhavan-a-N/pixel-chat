# Android release signing

Keystore files **must not** live in the git repo. Use **`D:\pixel-chat-keys\`** (or another path outside `D:\pixel-chat`).

## 1. Create the upload keystore (one time)

```powershell
New-Item -ItemType Directory -Force -Path "D:\pixel-chat-keys"

keytool -genkeypair -v `
  -keystore "D:\pixel-chat-keys\upload-keystore.jks" `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -alias upload `
  -storetype JKS
```

Record the passwords in your password manager. **If you lose this file or passwords, you cannot update the app** under the same Play Store / signing identity.

### Backup

1. Copy `upload-keystore.jks` to encrypted backup (USB, cloud vault, password manager attachment).
2. Store alias (`upload`), store password, and key password with the file.
3. Verify backup periodically:

```powershell
keytool -list -v -keystore "D:\pixel-chat-keys\upload-keystore.jks" -alias upload
```

## 2. Configure Gradle

1. Copy `app/android/key.properties.example` → `app/android/key.properties`.
2. Edit paths and passwords to match your keystore.
3. `key.properties` is gitignored.

Gradle loads signing per [Flutter Android deployment docs](https://docs.flutter.dev/deployment/android).

## 3. Release APK

Replace the host with your Render URL (HTTPS → WSS automatically):

```powershell
cd D:\pixel-chat\app
flutter clean
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-SERVICE.onrender.com
```

Output: `app/build/app/outputs/flutter-apk/app-release.apk`

Release builds use the **main** manifest only — cleartext HTTP is **not** enabled (debug/profile manifests add `usesCleartextTraffic` for local dev).
