# build_apk.ps1 - Force APK generation
Write-Host "=== FORCING APK GENERATION ===" -ForegroundColor Cyan

# Clean everything
Write-Host "Cleaning project..." -ForegroundColor Yellow
flutter clean
Remove-Item -Recurse -Force build, .dart_tool, .gradle -ErrorAction SilentlyContinue

# Get packages
Write-Host "Getting packages..." -ForegroundColor Green
flutter pub get

# Build for ARM64 specifically (your device CPH2421 is ARM64)
Write-Host "Building APK for ARM64..." -ForegroundColor Cyan
flutter build apk --debug --target-platform=android-arm64 --verbose

# Check if APK was created
$apkPath = "build\app\outputs\apk\debug\app-debug.apk"
if (Test-Path $apkPath) {
    Write-Host "✓ APK created successfully!" -ForegroundColor Green
    Write-Host "Location: $apkPath" -ForegroundColor Gray
    
    # Get file size
    $fileSize = (Get-Item $apkPath).Length / 1MB
    Write-Host "Size: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Gray
    
    # Install on device
    Write-Host "Installing on device..." -ForegroundColor Cyan
    adb install -r $apkPath
    
    # Launch app
    Write-Host "Launching app..." -ForegroundColor Green
    adb shell am start -n com.example.accessibility_service/.MainActivity
} else {
    Write-Host "✗ APK not found! Trying alternative build..." -ForegroundColor Red
    
    # Try alternative build method
    flutter build apk --debug --no-tree-shake-icons
}

Write-Host "`nDone!" -ForegroundColor Cyan