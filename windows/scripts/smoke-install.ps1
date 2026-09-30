param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath
)

$ErrorActionPreference = "Stop"

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Find-CoucouExe {
  $known = @(
    (Join-Path $env:LOCALAPPDATA "Coucou\Coucou.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Coucou\Coucou.exe")
  )
  foreach ($path in $known) {
    if (Test-Path -LiteralPath $path) { return $path }
  }
  $found = Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Filter "Coucou.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.FullName }
  return $null
}

$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$runtimeDir = Join-Path $env:LOCALAPPDATA "Coucou"
$settingsDir = Join-Path $env:APPDATA "Coucou"

# Make stale developer/runtime state impossible to hide a packaging bug.
Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Installing from a clean Coucou runtime/config state..."
$install = Start-Process -FilePath $installer -ArgumentList "/S" -PassThru -Wait
Require ($install.ExitCode -eq 0) "Installer exited with code $($install.ExitCode)."

$exe = Find-CoucouExe
Require ([bool]$exe) "Installer completed but Coucou.exe was not found under LOCALAPPDATA."
Write-Host "Installed app: $exe"

Write-Host "Launching Coucou..."
$app = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 6
Require (-not $app.HasExited) "Coucou exited during startup with code $($app.ExitCode)."

$relay = Join-Path $runtimeDir "bin\coucou-hook.exe"
$log = Join-Path $runtimeDir "coucou.log"
Require (Test-Path -LiteralPath $relay) "Startup did not stage coucou-hook.exe."
Require (Test-Path -LiteralPath $log) "Startup did not create coucou.log."

$payload = @{
  hook_event_name = "SessionStart"
  session_id = "ci-smoke"
  cwd = (Get-Location).Path
} | ConvertTo-Json -Compress
$payload | & $relay codex SessionStart
Start-Sleep -Seconds 1
$logText = Get-Content -LiteralPath $log -Raw
Require ($logText -match "hook SessionStart") "Relay connected, but SessionStart never reached Coucou."

Write-Host "Restarting the installed app..."
Stop-Process -Id $app.Id -Force
Start-Sleep -Seconds 1
$app2 = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
Require (-not $app2.HasExited) "Coucou exited after restart with code $($app2.ExitCode)."
Stop-Process -Id $app2.Id -Force

$installDir = Split-Path -Parent $exe
$uninstaller = Get-ChildItem -LiteralPath $installDir -Filter "*uninstall*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($uninstaller) {
  Write-Host "Running silent uninstall smoke check..."
  $uninstall = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -PassThru -Wait
  Require ($uninstall.ExitCode -eq 0) "Uninstaller exited with code $($uninstall.ExitCode)."
  Require (-not (Test-Path -LiteralPath $relay)) "Uninstall left the staged relay behind."
}

Write-Host "Clean install/start/relay/restart smoke test passed."
