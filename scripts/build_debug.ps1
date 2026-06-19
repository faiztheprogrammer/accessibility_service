$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$secretsFile = Join-Path $root "config\app_secrets.json"

if (!(Test-Path $secretsFile)) {
    Write-Host "Missing config\app_secrets.json"
    Write-Host "Create it from config\app_secrets.example.json and paste your Gemini key once."
    exit 1
}

$secrets = Get-Content $secretsFile -Raw | ConvertFrom-Json
if (!$secrets.GEMINI_API_KEY -or $secrets.GEMINI_API_KEY -eq "paste-your-gemini-key-here") {
    Write-Host "config\app_secrets.json still has the placeholder Gemini key."
    Write-Host "Paste the real key into config\app_secrets.json, not the example file."
    exit 1
}

Set-Location $root
flutter build apk --debug --dart-define-from-file=$secretsFile
