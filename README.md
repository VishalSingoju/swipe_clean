# Swipe Clean

Swipe **left** to send a photo or video to a folder called **Deleted**.
Swipe **right** to keep it (it won't be shown again).

## Set up

You need the Flutter SDK (https://docs.flutter.dev/get-started/install).

```bash
cd swipe_clean
flutter create . --platforms=android,ios   # generates android/ and ios/ (keeps lib/ and pubspec.yaml)
flutter pub get
```

### Android permissions

Edit `android/app/src/main/AndroidManifest.xml`. Put these inside `<manifest>`,
before `<application>`:

```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
<uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION"/>
```

and add `android:requestLegacyExternalStorage="true"` to the `<application>` tag.

### iOS permissions

Add to `ios/Runner/Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Swipe Clean shows your photos so you can choose which to keep.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Swipe Clean adds photos you swipe away to a Deleted album.</string>
```

### Run

```bash
flutter run
```

## How "Deleted" works

| Platform | What happens on swipe left |
|----------|----------------------------|
| Android  | File is copied to `Pictures/Deleted` (`Movies/Deleted` for video), then the original is removed. Android asks you to confirm once per batch (every 20 swipes, when you tap **Move N**, or when the app goes to the background). |
| iOS      | Item is added to a "Deleted" album. iOS has no real folders, and the original stays in your library. |

Nothing is ever permanently erased by the app. To really free space, empty the
Deleted folder yourself after reviewing it.

## Known limits

- **Google Photos is not included yet.** Google's Photos Library API can no
  longer read or delete your existing photos, so it needs a different approach.
- Undo only works until a batch has been moved.
- If you cancel Android's delete confirmation, the copies in `Deleted` stay and the originals remain too.
