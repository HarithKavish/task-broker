#requires -Version 7
<#
taskctl - local broker for delegating text-in/text-out tasks to NVIDIA NIM,
so any CLI-driven agent (Claude Code, Codex, or otherwise) can offload a
subtask to a separate, cheaper model without spending its own primary-session
tokens gathering context or processing the subtask's reasoning.

Companion to secretctl (HarithKavish/secrets-vault): that tool keeps a
secret's plaintext out of a calling agent's context; this one keeps a
subtask's raw input and reasoning out of it. Same shape, different resource.

taskctl is a single completion, not an agent: it has no tools of its own, no
file access beyond -Files (which it reads itself, so the caller never has to),
and no iteration loop. It is for delegating a well-specified prompt-and-context
task -- summarize this, extract that, draft this text -- not for open-ended
exploration that needs Read/Grep/Bash/web access along the way. That kind of
task still belongs to a real subagent.
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('run', 'models', 'import-key', 'key-status')]
    [string]$Command,

    [string]$Model,
    [string]$Prompt,
    [string]$System,
    [string[]]$Files,
    [double]$Temperature = 0.2,
    [int]$MaxTokens = 2048,
    [string]$Path,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$VaultDir = Join-Path $env:LOCALAPPDATA 'taskctl'
$VaultFile = Join-Path $VaultDir 'vault.json'
$AuditFile = Join-Path $VaultDir 'audit.log'

function Ensure-VaultDir {
    if (-not (Test-Path $VaultDir)) {
        New-Item -ItemType Directory -Path $VaultDir | Out-Null
    }
}

function Write-Audit([string]$Verb, [hashtable]$Fields) {
    Ensure-VaultDir
    $entry = [ordered]@{ verb = $Verb; timestamp = (Get-Date).ToString('o') }
    foreach ($k in $Fields.Keys) { $entry[$k] = $Fields[$k] }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $AuditFile
}

function Load-Key {
    if (-not (Test-Path $VaultFile)) {
        throw "No NVIDIA NIM key stored. Run: secretctl push -Name <key-name> -Target file:<tmp-path>, then: taskctl import-key -Path <tmp-path>"
    }
    $data = Get-Content $VaultFile -Raw | ConvertFrom-Json
    if (-not $data.nvidia) {
        throw "Vault exists but holds no 'nvidia' key. Run taskctl import-key first."
    }
    $secure = ConvertTo-SecureString $data.nvidia
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

switch ($Command) {
    'import-key' {
        if (-not $Path) { throw "import-key requires -Path <file containing the key on one line>" }
        if (-not (Test-Path $Path -PathType Leaf)) { throw "No such file: $Path" }
        $value = (Get-Content $Path -Raw).Trim()
        if (-not $value) { throw "File is empty." }

        Ensure-VaultDir
        $existing = [ordered]@{}
        if (Test-Path $VaultFile) {
            $loaded = Get-Content $VaultFile -Raw | ConvertFrom-Json
            $loaded.PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value }
        }
        if ($existing.Contains('nvidia') -and -not $Force) {
            throw "A key is already stored. Pass -Force to replace it."
        }

        $existing['nvidia'] = ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)
        ($existing | ConvertTo-Json) | Set-Content -Path $VaultFile
        Remove-Item -Path $Path -Force

        Write-Audit 'import-key' @{ provider = 'nvidia' }
        Write-Host "Stored NVIDIA NIM key. Source file deleted."
    }

    'key-status' {
        $configured = $false
        if (Test-Path $VaultFile) {
            $data = Get-Content $VaultFile -Raw | ConvertFrom-Json
            $configured = [bool]$data.nvidia
        }
        Write-Host "NVIDIA NIM key: $(if ($configured) { 'configured' } else { 'not configured' })"
    }

    'models' {
        @'
Known-good NVIDIA NIM models (full catalog: https://build.nvidia.com/models):
  deepseek-ai/deepseek-v4-pro              general reasoning, 262K context -- already
                                            in use elsewhere in this ecosystem
  meta/llama-3.3-70b-instruct               fast, capable general-purpose instruct model
  nvidia/llama-3.1-nemotron-70b-instruct    NVIDIA-tuned, strong instruction following

Pass any valid NIM model ID via -Model; this list is a starting point, not a limit.
'@ | Write-Host
    }

    'run' {
        if (-not $Model) { throw "run requires -Model <nim-model-id>. See: taskctl models" }
        if (-not $Prompt) { throw "run requires -Prompt <text, or a path to a file>" }

        $promptText = if (Test-Path $Prompt -PathType Leaf) { Get-Content $Prompt -Raw } else { $Prompt }

        $context = ''
        if ($Files) {
            foreach ($f in $Files) {
                if (-not (Test-Path $f -PathType Leaf)) { throw "No such file: $f" }
                $context += "`n`n--- $f ---`n" + (Get-Content $f -Raw)
            }
        }
        $userContent = if ($context) { "$promptText$context" } else { $promptText }

        $messages = [System.Collections.Generic.List[hashtable]]::new()
        if ($System) {
            $sysText = if (Test-Path $System -PathType Leaf) { Get-Content $System -Raw } else { $System }
            $messages.Add(@{ role = 'system'; content = $sysText })
        }
        $messages.Add(@{ role = 'user'; content = $userContent })

        $key = Load-Key
        $body = @{
            model       = $Model
            messages    = $messages
            temperature = $Temperature
            max_tokens  = $MaxTokens
        } | ConvertTo-Json -Depth 10

        try {
            $response = Invoke-RestMethod -Uri 'https://integrate.api.nvidia.com/v1/chat/completions' `
                -Method Post `
                -Headers @{ Authorization = "Bearer $key" } `
                -ContentType 'application/json' `
                -Body $body
        }
        catch {
            throw "NVIDIA NIM request failed: $($_.Exception.Message)"
        }

        $answer = $response.choices[0].message.content
        Write-Audit 'run' @{
            model             = $Model
            prompt_chars      = $userContent.Length
            response_chars    = $answer.Length
            prompt_tokens     = $response.usage.prompt_tokens
            completion_tokens = $response.usage.completion_tokens
        }
        Write-Output $answer
    }
}
