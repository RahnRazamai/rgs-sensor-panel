# RGS Sensor Panel Flutter App

This is the active Windows UI for RGS Sensor Panel.

The Flutter app talks to the bundled C# backend over local HTTP:

```text
Flutter UI
  -> Dart HttpClient
  -> http://127.0.0.1:8095/data.json
  -> rgs-sensor-backend.exe
```

Build the backend before running or packaging the Flutter app:

```powershell
dotnet build ..\sensor_backend\RgsSensorBackend.csproj -c Release
flutter pub get
flutter run -d windows
```

Release builds copy `rgs-sensor-backend.exe` next to the Flutter executable from
`..\sensor_backend\bin\Release\net48`.
