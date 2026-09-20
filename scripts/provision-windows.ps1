# Windows provisioning for zclaw: writes WiFi / LLM / Telegram settings to the NVS partition.
# Secrets are read interactively (secure prompts) and never stored in this file.
#
# Usage (from PowerShell, no ESP-IDF shell needed):
#   .\scripts\provision-windows.ps1 -Port COM10
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [string]$Backend = "nvidia",
    [string]$Model = "deepseek-ai/deepseek-v4-flash-0731",
    [string]$TgChatIds = "",
    [string]$IdfPath = "C:\Espressif\frameworks\esp-idf-v5.5.4",
    [string]$Python = "C:\Espressif\python_env\idf5.5_py3.13_env\Scripts\python.exe"
)

$ErrorActionPreference = "Stop"

function Read-Secret([string]$prompt) {
    $secure = Read-Host -Prompt $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Csv-Escape([string]$value) {
    if ($value -match '[",\r\n]') { return '"' + $value.Replace('"', '""') + '"' }
    return $value
}

$nvsGen = Join-Path $IdfPath "components\nvs_flash\nvs_partition_generator\nvs_partition_gen.py"
if (-not (Test-Path $Python)) { throw "Python not found: $Python" }
if (-not (Test-Path $nvsGen)) { throw "nvs_partition_gen.py not found: $nvsGen" }

$validBackends = @("anthropic", "openai", "openrouter", "ollama", "nvidia")
$backendIn = Read-Host -Prompt "LLM backend name, press Enter for [$Backend] (one of: $($validBackends -join ', '))"
if ($backendIn) { $Backend = $backendIn.Trim().ToLower() }
if ($validBackends -notcontains $Backend) {
    throw "Invalid backend '$Backend'. Enter only a provider name (not a URL): $($validBackends -join ', ')"
}
$modelIn = Read-Host -Prompt "Model, press Enter for [$Model]"
if ($modelIn) { $Model = $modelIn.Trim() }
if ($Model -match '^https?://') { throw "Model must be a model ID, not a URL: $Model" }

$ssid = Read-Host -Prompt "WiFi SSID"
$wifiPass = Read-Secret "WiFi password"
$apiKey = Read-Secret "LLM API key"
$tgToken = Read-Secret "Telegram bot token (leave empty to skip)"
if ($tgToken -and -not $TgChatIds) {
    $TgChatIds = Read-Host -Prompt "Telegram chat ID(s), comma separated"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("zclaw-nvs-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $rows = @("key,type,encoding,value", "zclaw,namespace,,")
    $rows += "wifi_ssid,data,string,$(Csv-Escape $ssid)"
    $rows += "wifi_pass,data,string,$(Csv-Escape $wifiPass)"
    $rows += "llm_backend,data,string,$(Csv-Escape $Backend)"
    $rows += "api_key,data,string,$(Csv-Escape $apiKey)"
    $rows += "llm_model,data,string,$(Csv-Escape $Model)"
    if ($tgToken) {
        $rows += "tg_token,data,string,$(Csv-Escape $tgToken)"
        if ($TgChatIds) {
            $primary = ($TgChatIds -split ",")[0].Trim()
            $rows += "tg_chat_id,data,string,$(Csv-Escape $primary)"
            $rows += "tg_chat_ids,data,string,$(Csv-Escape $TgChatIds)"
        }
    }

    $csv = Join-Path $tmp "nvs.csv"
    $bin = Join-Path $tmp "nvs.bin"
    [IO.File]::WriteAllLines($csv, $rows, (New-Object Text.UTF8Encoding($false)))

    & $Python $nvsGen generate $csv $bin 0x4000
    if ($LASTEXITCODE -ne 0) { throw "nvs_partition_gen failed" }

    Write-Host "Writing NVS partition to $Port (0x9000)..."
    & $Python -m esptool --chip esp32c3 -p $Port write_flash 0x9000 $bin
    if ($LASTEXITCODE -ne 0) { throw "esptool write_flash failed" }

    Write-Host "Provisioning done. The board was reset by esptool; open the monitor to check logs."
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    $wifiPass = $null; $apiKey = $null; $tgToken = $null
}
