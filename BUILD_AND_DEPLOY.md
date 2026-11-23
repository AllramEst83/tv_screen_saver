# Build and deploy: TV Saver

One Flutter project, two apps built as Gradle product flavors:

| App | Flavor | Application id | Entry point | Target |
| --- | --- | --- | --- | --- |
| TV (Sony XR-55X90K, Google TV, Android 12, **32-bit ARM**) | `tv` | `com.codedbykay.tvsaver.tv` | `lib/main_tv.dart` | `android-arm` |
| Phone (later stories) | `phone` | `com.codedbykay.tvsaver` | not yet | phone ABI |

Phase 1 (story 1-1) builds the TV app only: a full-screen spike that shows and logs the `DisplayReport` (what the app renders vs what the panel shows).

## 1. Prerequisites

- Flutter stable (built with 3.47) and the Android SDK; check with `flutter doctor`.
- `adb` on your PATH (Android SDK platform-tools).
- First time only: `flutter pub get`.

## 2. Release keystore (already created, back it up)

The keystore was generated when the project was created, with a random password:

- `android/app/upload-keystore.jks` (alias `tvsaver`)
- `android/key.properties` (the passwords; format in `android/key.properties.example`)

Both are git-ignored. **Back up both files now** (password manager plus an offline copy). Without this keystore you can never update the installed app: Android refuses an update signed with a different key, and you would have to uninstall it (losing its data).

If `android/key.properties` is missing, a release build still succeeds but is signed with the **debug key** and Gradle prints a warning. Never install such an APK on the TV for good.

To create a new keystore on another machine (only if the original is truly lost; `keytool` is not on PATH):

```bash
"C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe" -genkeypair -keystore android/app/upload-keystore.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias tvsaver
cp android/key.properties.example android/key.properties   # then fill in the passwords
```

## 3. Versions

`pubspec.yaml` has `version: 0.1.0+1`: the part before `+` is the version name, the number after `+` is the **versionCode**. Increase the versionCode for every release you install over an older one.

## 4. Build the TV APK

From the project root:

```bash
flutter build apk --release --flavor tv --target-platform android-arm -t lib/main_tv.dart
cp build/app/outputs/flutter-apk/app-tv-release.apk build/tv-saver-tv.apk
```

`--target-platform android-arm` is required: the Sony is 32-bit only, and the build strips the other ABIs. The APK is about 12 MB.

## 5. Install on the TV (over ADB)

1. On the TV: Settings, System, About, press "Android TV OS build" seven times; then Settings, System, Developer options: turn on **USB debugging** / network debugging.
2. Connect and install:

   ```bash
   adb connect 192.168.0.24:5555
   adb -s 192.168.0.24:5555 install -r build/tv-saver-tv.apk
   adb -s 192.168.0.24:5555 shell monkey -p com.codedbykay.tvsaver.tv -c android.intent.category.LEANBACK_LAUNCHER 1
   ```

   **TV Saver** appears in the Google TV apps row (banner) and opens full screen.
3. `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: a build signed with another key is installed. `adb uninstall com.codedbykay.tvsaver.tv` and install again (its data is lost).

## 6. Measure the display (DisplayReport)

```bash
tool/tv/display_report.sh 192.168.0.24:5555
```

(Run it from Git Bash on Windows.) It is **read-only**: it installs nothing and changes no TV setting (it never runs `wm size`/`wm density` with arguments or `settings put`). It:

1. connects over adb (exit 1 with `TV not reachable at <ip>` and no file if that fails);
2. looks for the app's `DisplayReport: renders …` line in logcat; if missing, launches the app (restarting it if it was already running) and waits up to 15 s;
3. writes `build/measurements/display-report-<timestamp>.txt` with the DisplayReport line, `wm size`, `wm density`, the display modes and HDR capabilities, and the full `dumpsys display`;
4. prints a summary. Exit 0 when complete, 2 when the app line is missing (the adb sections are still in the file).

The panel size in the line comes from the TV's native display mode (`Display.getMode()`), not from the window size Android reports, because a `wm size` override shrinks the latter. If that read fails, the line ends with `(panel unverified)`: the panel then shows the override, not the real panel, so check it against `wm size` (`Physical size`). If no view appears, the app logs `DisplayReport: unknown` and gives up after 10 frames.

The on-screen report and the log line should match the file. Record the result in the spec memlog (`_bmad-output/specs/spec-tv-screensaver/.memlog.md`).

The app's log line on its own: `adb -s 192.168.0.24:5555 logcat -d -s flutter | grep DisplayReport`.

## 7. Check a build before you ship it

```bash
flutter analyze
flutter test
```

Both must pass with no issues.
