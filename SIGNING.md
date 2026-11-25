# Android release signing

Every APK is signed with the same RDMNS release key, so new builds (and OTA updates
from `update.json`) install over the existing app.

- `android/rdmns-release.jks.enc` — the keystore, AES-256 encrypted (safe to keep in the repo).
- GitHub secret **`ANDROID_SIGNING_PASSWORD`** — decrypts it; it is also the store/key password (alias `rdmns`).
- CI decrypts it into `android/app/rdmns-release.jks` + `android/key.properties` before `flutter build apk`.
- Keep the plain `rdmns-release.jks` and password backed up privately. If they are lost, installed apps can never be updated.

Local build: put `rdmns-release.jks` in `android/app/` and create `android/key.properties`:
```
storeFile=rdmns-release.jks
storePassword=<password>
keyAlias=rdmns
keyPassword=<password>
```
