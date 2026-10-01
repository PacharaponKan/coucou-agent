param(
  [Parameter(Mandatory = $true)]
  [string]$InstallerPath,
  [string]$GeneratedHooksPath,
  [switch]$SkipCodexHook,
  [switch]$KeepInstalled,
  [switch]$PreserveExisting
)

$ErrorActionPreference = "Stop"
$script:SmokeLog = $null

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    if ($script:SmokeLog -and (Test-Path -LiteralPath $script:SmokeLog)) {
      Write-Host "--- Coucou log tail ---"
      Get-Content -LiteralPath $script:SmokeLog -Tail 80 -ErrorAction SilentlyContinue | Write-Host
      Write-Host "--- end log tail ---"
    }
    throw $Message
  }
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
$programDir = Join-Path $env:LOCALAPPDATA "Programs\Coucou"
$settingsFile = Join-Path $settingsDir "settings.json"

# Make stale developer/runtime state impossible to hide a packaging bug.
Get-Process -Name "coucou" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (-not $PreserveExisting) {
  Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $programDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Require (Test-Path -LiteralPath $programDir) "PreserveExisting requested, but no existing Coucou install was found."
}

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
$script:SmokeLog = $log
Require (Test-Path -LiteralPath $relay) "Startup did not stage coucou-hook.exe."
Require (Test-Path -LiteralPath $log) "Startup did not create coucou.log."

Write-Host "Checking repeated launch / single-instance behavior..."
$second = Start-Process -FilePath $exe -PassThru
Require ($second.WaitForExit(7000)) "Second Coucou launch did not hand off and exit."
Require ($second.ExitCode -eq 0) "Second Coucou launch exited with code $($second.ExitCode) instead of a clean single-instance handoff."
Require (-not $app.HasExited) "Second launch terminated the primary Coucou instance."
Start-Sleep -Milliseconds 300
$instances = @(Get-Process -Name "coucou" -ErrorAction SilentlyContinue)
Require ($instances.Count -eq 1) "Expected one Coucou process after repeated launch, found $($instances.Count)."

$payload = @{
  hook_event_name = "SessionStart"
  session_id = "ci-smoke"
  cwd = (Get-Location).Path
} | ConvertTo-Json -Compress
$manualBefore = ([regex]::Matches((Get-Content -LiteralPath $log -Raw), "hook SessionStart source=codex")).Count
$payload | & $relay codex SessionStart
Start-Sleep -Seconds 1
$logText = Get-Content -LiteralPath $log -Raw
$manualAfter = ([regex]::Matches($logText, "hook SessionStart source=codex")).Count
Require ($manualAfter -gt $manualBefore) "Relay connected, but this SessionStart never reached Coucou."

Write-Host "Checking malformed hook payload is ignored safely..."
$badIn = Join-Path $env:TEMP "coucou-hook-bad-in.json"
$badOut = Join-Path $env:TEMP "coucou-hook-bad-out.txt"
$badErr = Join-Path $env:TEMP "coucou-hook-bad-err.txt"
[System.IO.File]::WriteAllText($badIn, "{ definitely not json", (New-Object System.Text.UTF8Encoding($false)))
$badProc = Start-Process -FilePath $relay -ArgumentList @("codex", "SessionStart") `
  -PassThru -Wait -RedirectStandardInput $badIn -RedirectStandardOutput $badOut -RedirectStandardError $badErr
Require ($badProc.ExitCode -eq 0) "Relay returned $($badProc.ExitCode) for malformed JSON."
Require ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $badOut -Raw -ErrorAction SilentlyContinue))) "Malformed JSON produced stdout."
Require ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $badErr -Raw -ErrorAction SilentlyContinue))) "Malformed JSON produced stderr."
Require (-not $app.HasExited) "Malformed hook JSON crashed Coucou."
Remove-Item -LiteralPath $badIn,$badOut,$badErr -Force -ErrorAction SilentlyContinue

Write-Host "Checking empty settings recovery..."
Stop-Process -Id $app.Id -Force
Start-Sleep -Seconds 1
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
[System.IO.File]::WriteAllText($settingsFile, "")
$app = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
Require (-not $app.HasExited) "Coucou failed to start with an empty settings.json."

Write-Host "Checking invalid settings recovery and diagnostics..."
Stop-Process -Id $app.Id -Force
Start-Sleep -Seconds 1
$badSettingsBefore = ([regex]::Matches((Get-Content -LiteralPath $log -Raw), "invalid settings\.json")).Count
[System.IO.File]::WriteAllText($settingsFile, "{ broken settings")
$app = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
Require (-not $app.HasExited) "Coucou failed to start with an invalid settings.json."
$badSettingsLog = Get-Content -LiteralPath $log -Raw
$badSettingsAfter = ([regex]::Matches($badSettingsLog, "invalid settings\.json")).Count
Require ($badSettingsAfter -gt $badSettingsBefore) "This invalid settings fallback was not recorded in coucou.log."
Require ((Get-Content -LiteralPath $settingsFile -Raw) -eq "{ broken settings") "Coucou overwrote the user's invalid settings file."

if (-not $SkipCodexHook) {
# Exercise Codex's real hooks.json parser and Windows command selection. The
# generic command deliberately fails; only commandWindows points at our relay.
# A dummy key is enough to create a session and fire SessionStart before the
# expected authentication failure reaches inference.
$codexHome = Join-Path (Get-Location) ".ci-codex-home"
Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $codexHome | Out-Null
Require ([bool]$GeneratedHooksPath) "Codex smoke requires GeneratedHooksPath."
$generatedHooks = (Resolve-Path -LiteralPath $GeneratedHooksPath).Path
$codexHooks = Get-Content -LiteralPath $generatedHooks -Raw | ConvertFrom-Json
# Prove Windows uses commandWindows: the generic command is deliberately bad.
$codexHooks.hooks.SessionStart[0].hooks[0].command = "cmd /c exit 99"
$hooksJson = $codexHooks | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText(
  (Join-Path $codexHome "hooks.json"),
  $hooksJson,
  (New-Object System.Text.UTF8Encoding($false))
)
$beforeCodex = ([regex]::Matches((Get-Content -LiteralPath $log -Raw), "hook SessionStart source=codex")).Count
$oldCodexHome = $env:CODEX_HOME
$oldApiKey = $env:OPENAI_API_KEY
$env:CODEX_HOME = $codexHome
$env:OPENAI_API_KEY = "sk-test-invalid"
$codexStdout = Join-Path $codexHome "stdout.txt"
$codexStderr = Join-Path $codexHome "stderr.txt"
$codexOutput = ""
$codexExit = $null
try {
  $codexProc = Start-Process -FilePath (Get-Command codex.cmd).Source `
    -ArgumentList @("exec", "--dangerously-bypass-hook-trust", "-C", (Get-Location).Path, "ci-hook-smoke") `
    -PassThru -RedirectStandardOutput $codexStdout -RedirectStandardError $codexStderr
  if (-not $codexProc.WaitForExit(30000)) {
    $codexProc.Kill()
    throw "Codex SessionStart smoke exceeded 30 seconds."
  }
  $codexExit = $codexProc.ExitCode
  $codexOutput = (Get-Content -LiteralPath $codexStdout -Raw -ErrorAction SilentlyContinue) + "`n" +
    (Get-Content -LiteralPath $codexStderr -Raw -ErrorAction SilentlyContinue)
} finally {
  $env:CODEX_HOME = $oldCodexHome
  $env:OPENAI_API_KEY = $oldApiKey
}
  Require ($codexOutput -notmatch "failed to parse hooks config") "Codex rejected hooks.json: $codexOutput"
  Require ($codexOutput -match "hook: SessionStart Completed") "Codex never completed SessionStart hook: $codexOutput"
  Require ($codexOutput -match "401 Unauthorized|authentication|failed to connect") "Expected Codex auth/network failure did not occur: $codexOutput"
  Require ($codexExit -ne 0) "Codex unexpectedly succeeded with the deliberately invalid API key."
  Start-Sleep -Seconds 1
$afterCodex = ([regex]::Matches((Get-Content -LiteralPath $log -Raw), "hook SessionStart source=codex")).Count
Require ($afterCodex -gt $beforeCodex) "Codex did not execute commandWindows against the installed relay."
$afterCodexLog = Get-Content -LiteralPath $log -Raw
Require ($afterCodexLog -match "hook SessionStart source=codex") "Codex relay event lost its agent_source tag."
Require (-not $app.HasExited) "Expected Codex auth/network failure terminated Coucou."
Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Restarting the installed app..."
Stop-Process -Id $app.Id -Force
Start-Sleep -Seconds 1
$app2 = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 4
Require (-not $app2.HasExited) "Coucou exited after restart with code $($app2.ExitCode)."
Stop-Process -Id $app2.Id -Force
Start-Sleep -Seconds 1

# Coucou being closed must never wedge Claude/Codex. A copied relay gets the
# same payload with no pipe server: it must exit 0 quickly and print nothing.
Write-Host "Checking relay fail-open behavior with Coucou unavailable..."
$standaloneRelay = Join-Path $env:TEMP "coucou-hook-smoke.exe"
Copy-Item -LiteralPath $relay -Destination $standaloneRelay -Force
$fallbackIn = Join-Path $env:TEMP "coucou-hook-smoke-in.json"
$fallbackOut = Join-Path $env:TEMP "coucou-hook-smoke-out.txt"
$fallbackErr = Join-Path $env:TEMP "coucou-hook-smoke-err.txt"
[System.IO.File]::WriteAllText($fallbackIn, $payload, (New-Object System.Text.UTF8Encoding($false)))
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$fallbackProc = Start-Process -FilePath $standaloneRelay -ArgumentList @("codex", "SessionStart") `
  -PassThru -RedirectStandardInput $fallbackIn -RedirectStandardOutput $fallbackOut -RedirectStandardError $fallbackErr
if (-not $fallbackProc.WaitForExit(3000)) {
  $fallbackProc.Kill()
  throw "Relay exceeded 3 seconds while Coucou was closed."
}
$fallbackCode = $fallbackProc.ExitCode
$stopwatch.Stop()
$fallbackOutput = Get-Content -LiteralPath $fallbackOut -Raw -ErrorAction SilentlyContinue
$fallbackError = Get-Content -LiteralPath $fallbackErr -Raw -ErrorAction SilentlyContinue
Require ($fallbackCode -eq 0) "Relay returned $fallbackCode while Coucou was closed."
Require ($stopwatch.Elapsed.TotalSeconds -lt 2.5) "Relay blocked for $($stopwatch.Elapsed.TotalSeconds)s while Coucou was closed."
Require ([string]::IsNullOrWhiteSpace($fallbackOutput)) "Relay wrote output while Coucou was unavailable."
Require ([string]::IsNullOrWhiteSpace($fallbackError)) "Relay wrote stderr while Coucou was unavailable: $fallbackError"
Remove-Item -LiteralPath $standaloneRelay -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fallbackIn,$fallbackOut,$fallbackErr -Force -ErrorAction SilentlyContinue

if ($KeepInstalled) {
  Write-Host "Smoke workflow passed; leaving installation in place for reinstall/upgrade test."
  exit 0
}

$installDir = Split-Path -Parent $exe
$uninstaller = Get-ChildItem -LiteralPath $installDir -Filter "*uninstall*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
Require ([bool]$uninstaller) "Installed package did not provide an uninstaller."
Write-Host "Running silent uninstall smoke check..."
$uninstall = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -PassThru -Wait
Require ($uninstall.ExitCode -eq 0) "Uninstaller exited with code $($uninstall.ExitCode)."
Start-Sleep -Seconds 1
Require (-not (Test-Path -LiteralPath $relay)) "Uninstall left the staged relay behind."
Require (-not (Test-Path -LiteralPath $exe)) "Uninstall left Coucou.exe installed."

Write-Host "Clean install/start/relay/restart smoke test passed."
