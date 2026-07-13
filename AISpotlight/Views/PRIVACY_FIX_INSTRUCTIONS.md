# Privacy-Sensitive Data Error Fix

## Problem
The app crashes with the error:
```
This app has crashed because it attempted to access privacy-sensitive data without a usage description. The app's Info.plist must contain an NSMicrophoneUsageDescription key with a string value explaining to the user how the app uses this data.
```

## Solution

### 1. Locate the Info.plist file
In Xcode, find your project's `Info.plist` file (usually in the folder with the project name).

### 2. Add permission keys
Add the following keys to your `Info.plist`:

#### Method 1: Via Xcode Interface
1. Open `Info.plist` in Xcode
2. Click `+` to add a new key
3. Add the following keys:

**NSMicrophoneUsageDescription**
```
Value: "This app uses the microphone to record voice messages for the AI assistant."
```

**NSCameraUsageDescription** (optional, but recommended)
```
Value: "This app may need camera access for enhanced features."
```

#### Method 2: Via XML source code
Add these lines to your `Info.plist`:

```xml
<dict>
    <!-- ... existing keys ... -->

    <!-- Microphone permission -->
    <key>NSMicrophoneUsageDescription</key>
    <string>This app uses the microphone to record voice messages for the AI assistant.</string>

    <!-- Camera permission (optional) -->
    <key>NSCameraUsageDescription</key>
    <string>This app may need camera access for enhanced features.</string>

    <!-- ... other keys ... -->
</dict>
```

### 3. Alternative descriptions in Russian
If you want Russian descriptions:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Приложение использует микрофон для записи голосовых сообщений для ИИ-ассистента.</string>

<key>NSCameraUsageDescription</key>
<string>Приложение может использовать камеру для дополнительных функций.</string>
```

### 4. Rebuild the project
After adding the keys:
1. Clean the project: `Product → Clean Build Folder`
2. Rebuild the project: `Product → Build`
3. Run the application

### 5. Check permissions
When using the microphone for the first time, the system will show a permission dialog. If the dialog doesn't appear:
1. Go to `System Settings → Privacy & Security → Microphone`
2. Find your application and enable the permission

## Result
After these changes, the app should correctly request permissions and not crash when attempting to record voice messages.
