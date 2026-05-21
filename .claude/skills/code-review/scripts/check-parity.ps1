# Deterministic parity checks for claude-status-line code review.
# Outputs a JSON array of pass/fail assertions to stdout.
# Usage: powershell -NoProfile -File check-parity.ps1 [project-root]

param([string]$Root = ".")

$results = [System.Collections.ArrayList]::new()

function Add-CheckResult {
    param([string]$Check, [bool]$Passed, [string]$File, [string]$Detail)
    $null = $script:results.Add([PSCustomObject]@{
        check  = $Check
        passed = $Passed
        file   = $File
        detail = $Detail
    })
}

function Get-Tag([string]$FilePath, [string]$Category, [string]$Key) {
    foreach ($line in (Get-Content $FilePath -ErrorAction SilentlyContinue)) {
        if ($line -match "@parity:${Category}\s+${Key}=(\S+)") { return $Matches[1] }
    }
    return $null
}

function Get-Block([string]$FilePath, [string]$Name) {
    $lines = Get-Content $FilePath -ErrorAction SilentlyContinue
    $inBlock = $false
    $result = [System.Collections.ArrayList]::new()
    foreach ($line in $lines) {
        if ($line -match "@parity:${Name}-begin") { $inBlock = $true; continue }
        if ($line -match "@parity:${Name}-end") { break }
        if ($inBlock) { $null = $result.Add($line) }
    }
    return $result
}

# --- Check 1: Every script ends with exit 0 ---
foreach ($dir in @("macos", "linux")) {
    $shFiles = Get-ChildItem -Path "$Root/$dir" -Filter "*.sh" -ErrorAction SilentlyContinue
    foreach ($f in $shFiles) {
        $lines = (Get-Content $f.FullName) -match '\S'
        $lastLine = if ($lines.Count -gt 0) { ($lines[-1]).Trim() } else { "" }
        $relPath = "$dir/$($f.Name)"
        if ($lastLine -eq "exit 0") {
            Add-CheckResult "exit-0-termination" $true $relPath "ends with exit 0"
        } else {
            Add-CheckResult "exit-0-termination" $false $relPath "last non-blank line: $lastLine"
        }
    }
}

$ps1Files = Get-ChildItem -Path "$Root/windows" -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($f in $ps1Files) {
    $lines = (Get-Content $f.FullName) -match '\S'
    $lastLine = if ($lines.Count -gt 0) { ($lines[-1]).Trim() } else { "" }
    $relPath = "windows/$($f.Name)"
    if ($lastLine -eq "exit 0") {
        Add-CheckResult "exit-0-termination" $true $relPath "ends with exit 0"
    } else {
        Add-CheckResult "exit-0-termination" $false $relPath "last non-blank line: $lastLine"
    }
}

# --- Check 2: No macOS-isms in Linux files ---
$macosPatterns = @("afplay", "terminal-notifier", "/System/Library/Sounds", "brew install", "Homebrew")
$linuxShFiles = Get-ChildItem -Path "$Root/linux" -Filter "*.sh" -ErrorAction SilentlyContinue
foreach ($f in $linuxShFiles) {
    $content = Get-Content $f.FullName
    foreach ($pat in $macosPatterns) {
        $escaped = [regex]::Escape($pat)
        for ($i = 0; $i -lt $content.Count; $i++) {
            if ($content[$i] -match $escaped) {
                Add-CheckResult "no-macos-isms-in-linux" $false "linux/$($f.Name)" "found '$pat' at line $($i + 1)"
                break
            }
        }
    }
}

# --- Check 3: No Linux-isms in macOS files ---
$linuxPatterns = @("paplay", "aplay", "notify-send", "apt install", "dnf install", "pacman -S", "zypper install")
$macosShFiles = Get-ChildItem -Path "$Root/macos" -Filter "*.sh" -ErrorAction SilentlyContinue
foreach ($f in $macosShFiles) {
    $content = Get-Content $f.FullName
    foreach ($pat in $linuxPatterns) {
        $escaped = [regex]::Escape($pat)
        for ($i = 0; $i -lt $content.Count; $i++) {
            if ($content[$i] -match $escaped) {
                Add-CheckResult "no-linux-isms-in-macos" $false "macos/$($f.Name)" "found '$pat' at line $($i + 1)"
                break
            }
        }
    }
}

# --- Check 4: Rendering constants match across macOS and Linux statuslines ---
$macStatusline = Join-Path $Root "macos/statusline.sh"
$linStatusline = Join-Path $Root "linux/statusline.sh"
$constantVars = @("CACHE_VERSION", "LABEL_W")
if ((Test-Path $macStatusline) -and (Test-Path $linStatusline)) {
    foreach ($var in $constantVars) {
        $macVal = Get-Tag $macStatusline "constant" $var
        $linVal = Get-Tag $linStatusline "constant" $var
        if (-not $macVal -and -not $linVal) {
            Add-CheckResult "constant-parity" $false "statusline" "${var}: could not extract from either platform (check @parity:constant tags)"
        } elseif (-not $macVal -or -not $linVal) {
            Add-CheckResult "constant-parity" $false "statusline" "${var}: extraction failed on one platform (macOS=$macVal, Linux=$linVal)"
        } elseif ($macVal -eq $linVal) {
            Add-CheckResult "constant-parity" $true "statusline" "${var}: macOS=$macVal, Linux=$linVal"
        } else {
            Add-CheckResult "constant-parity" $false "statusline" "${var}: macOS=$macVal, Linux=$linVal (MISMATCH)"
        }
    }
}

# --- Check 5: Same jq fields extracted on macOS and Linux ---
function Get-JqFields([string]$FilePath) {
    $block = Get-Block $FilePath "json-extract"
    $fields = [System.Collections.ArrayList]::new()
    foreach ($line in $block) {
        $fieldMatches = [regex]::Matches($line, '\.[a-z_][a-z0-9_.]*')
        foreach ($m in $fieldMatches) { $null = $fields.Add($m.Value) }
    }
    return ($fields | Sort-Object -Unique)
}

if ((Test-Path $macStatusline) -and (Test-Path $linStatusline)) {
    $macFields = @(Get-JqFields $macStatusline)
    $linFields = @(Get-JqFields $linStatusline)
    if ($macFields.Count -eq 0 -and $linFields.Count -eq 0) {
        Add-CheckResult "json-field-parity" $false "statusline" "could not extract fields from either platform (check @parity:json-extract markers)"
    } elseif ($macFields.Count -eq 0 -or $linFields.Count -eq 0) {
        Add-CheckResult "json-field-parity" $false "statusline" "extraction failed on one platform"
    } else {
        $macOnly = @($macFields | Where-Object { $_ -notin $linFields }) | Select-Object -First 5
        $linOnly = @($linFields | Where-Object { $_ -notin $macFields }) | Select-Object -First 5
        if ($macOnly.Count -eq 0 -and $linOnly.Count -eq 0) {
            Add-CheckResult "json-field-parity" $true "statusline" "macOS and Linux extract the same jq fields"
        } else {
            $detail = ""
            if ($macOnly.Count -gt 0) { $detail = "macOS-only: $($macOnly -join ', ')" }
            if ($linOnly.Count -gt 0) { $detail = "$detail Linux-only: $($linOnly -join ', ')".Trim() }
            Add-CheckResult "json-field-parity" $false "statusline" $detail
        }
    }
}

# --- Check 6: Function naming conventions ---
# Bash: functions should be snake_case
foreach ($dir in @("macos", "linux")) {
    $shFiles = Get-ChildItem -Path "$Root/$dir" -Filter "*.sh" -ErrorAction SilentlyContinue
    foreach ($f in $shFiles) {
        $badFuncs = [System.Collections.ArrayList]::new()
        foreach ($line in (Get-Content $f.FullName)) {
            if ($line -match '^\s*(function\s+)?([A-Za-z_]\w*)\s*\(\)') {
                $name = $Matches[2]
                if ($name -cmatch '[A-Z]') { $null = $badFuncs.Add($name) }
            }
        }
        if ($badFuncs.Count -gt 0) {
            Add-CheckResult "naming-convention" $false "$dir/$($f.Name)" "non-snake_case functions: $($badFuncs -join ', ')"
        }
    }
}

# PowerShell: functions should be PascalCase
foreach ($f in (Get-ChildItem -Path "$Root/windows" -Filter "*.ps1" -ErrorAction SilentlyContinue)) {
    $badFuncs = [System.Collections.ArrayList]::new()
    foreach ($line in (Get-Content $f.FullName)) {
        if ($line -match '^\s*function\s+([A-Za-z]\w*)') {
            $name = $Matches[1]
            if ($name -cmatch '^[a-z]') { $null = $badFuncs.Add($name) }
        }
    }
    if ($badFuncs.Count -gt 0) {
        Add-CheckResult "naming-convention" $false "windows/$($f.Name)" "non-PascalCase functions: $($badFuncs -join ', ')"
    }
}

# --- Check 7: No unguarded Write-Error in Windows scripts ---
foreach ($f in (Get-ChildItem -Path "$Root/windows" -Filter "*.ps1" -ErrorAction SilentlyContinue)) {
    $hits = Select-String -Path $f.FullName -Pattern 'Write-Error'
    if ($hits) {
        $line = $hits[0].LineNumber
        Add-CheckResult "no-stderr-output" $false "windows/$($f.Name)" "Write-Error at line $line (stderr)"
    }
}

# --- Check 8: ANSI color variable parity across statuslines ---
function Get-BashColors([string]$FilePath) {
    $block = Get-Block $FilePath "colors"
    $colors = @{}
    foreach ($line in $block) {
        if ($line -match '^\s*([A-Z_]+)="\$\{ESC\}\[(\d+(?:;\d+)*)m"') {
            $colors[$Matches[1]] = $Matches[2]
        }
    }
    return $colors
}

function Get-PsColors([string]$FilePath) {
    $block = Get-Block $FilePath "colors"
    $colors = @{}
    foreach ($line in $block) {
        if ($line -match '^\s*\$([A-Z_]+)\s*=\s*Ansi\s+[''"]?([0-9;]+)[''"]?') {
            $colors[$Matches[1]] = $Matches[2]
        }
    }
    return $colors
}

$macSl = Join-Path $Root "macos/statusline.sh"
$linSl = Join-Path $Root "linux/statusline.sh"
$winSl = Join-Path $Root "windows/statusline.ps1"

if ((Test-Path $macSl) -and (Test-Path $linSl) -and (Test-Path $winSl)) {
    $macColors = Get-BashColors $macSl
    $linColors = Get-BashColors $linSl
    $winColors = Get-PsColors  $winSl

    if ($macColors.Count -eq 0 -and $linColors.Count -eq 0) {
        Add-CheckResult "ansi-color-parity" $false "statusline" "could not extract colors from Bash scripts (check @parity:colors markers)"
    } else {
        $macOnlyC = @($macColors.Keys | Where-Object { -not $linColors.ContainsKey($_) -or $linColors[$_] -ne $macColors[$_] })
        $linOnlyC = @($linColors.Keys | Where-Object { -not $macColors.ContainsKey($_) -or $macColors[$_] -ne $linColors[$_] })
        if ($macOnlyC.Count -eq 0 -and $linOnlyC.Count -eq 0) {
            Add-CheckResult "ansi-color-parity" $true "statusline" "macOS and Linux define identical color sets"
        } else {
            $detail = ""
            if ($macOnlyC.Count -gt 0) { $detail = "macOS-only/differs: $($macOnlyC -join ', ')" }
            if ($linOnlyC.Count -gt 0) { $detail = "$detail Linux-only/differs: $($linOnlyC -join ', ')".Trim() }
            Add-CheckResult "ansi-color-parity" $false "statusline" $detail
        }

        if ($winColors.Count -eq 0) {
            Add-CheckResult "ansi-color-parity" $false "statusline" "could not extract colors from Windows script (check @parity:colors markers)"
        } else {
            $bashOnlyC = @($macColors.Keys | Where-Object { -not $winColors.ContainsKey($_) -or $winColors[$_] -ne $macColors[$_] })
            $winOnlyC  = @($winColors.Keys | Where-Object { -not $macColors.ContainsKey($_) -or $macColors[$_] -ne $winColors[$_] })
            if ($bashOnlyC.Count -eq 0 -and $winOnlyC.Count -eq 0) {
                Add-CheckResult "ansi-color-parity" $true "statusline" "Windows and Bash define identical color sets"
            } else {
                $detail = ""
                if ($bashOnlyC.Count -gt 0) { $detail = "Bash-only/differs: $($bashOnlyC -join ', ')" }
                if ($winOnlyC.Count  -gt 0) { $detail = "$detail Windows-only/differs: $($winOnlyC -join ', ')".Trim() }
                Add-CheckResult "ansi-color-parity" $false "statusline" $detail
            }
        }
    }
}

# --- Check 9: Color threshold parity across statuslines ---
if ((Test-Path $macSl) -and (Test-Path $linSl) -and (Test-Path $winSl)) {
    $macCtxCrit  = Get-Tag $macSl "threshold" "CONTEXT_CRIT"
    $macCtxWarn  = Get-Tag $macSl "threshold" "CONTEXT_WARN"
    $macCostWarn = Get-Tag $macSl "threshold" "COST_WARN"
    $linCtxCrit  = Get-Tag $linSl "threshold" "CONTEXT_CRIT"
    $linCtxWarn  = Get-Tag $linSl "threshold" "CONTEXT_WARN"
    $linCostWarn = Get-Tag $linSl "threshold" "COST_WARN"
    $winCtxCrit  = Get-Tag $winSl "threshold" "CONTEXT_CRIT"
    $winCtxWarn  = Get-Tag $winSl "threshold" "CONTEXT_WARN"
    $winCostWarn = Get-Tag $winSl "threshold" "COST_WARN"

    $macThresh = "ctx_crit=$(if($macCtxCrit){$macCtxCrit}else{'?'}) ctx_warn=$(if($macCtxWarn){$macCtxWarn}else{'?'}) cost_warn=$(if($macCostWarn){$macCostWarn}else{'?'})"
    $linThresh = "ctx_crit=$(if($linCtxCrit){$linCtxCrit}else{'?'}) ctx_warn=$(if($linCtxWarn){$linCtxWarn}else{'?'}) cost_warn=$(if($linCostWarn){$linCostWarn}else{'?'})"
    $winThresh = "ctx_crit=$(if($winCtxCrit){$winCtxCrit}else{'?'}) ctx_warn=$(if($winCtxWarn){$winCtxWarn}else{'?'}) cost_warn=$(if($winCostWarn){$winCostWarn}else{'?'})"

    if (-not $macCtxCrit -and -not $linCtxCrit -and -not $winCtxCrit) {
        Add-CheckResult "threshold-parity" $false "statusline" "could not extract thresholds (check @parity:threshold tags)"
    } elseif ($macThresh -eq $linThresh -and $macThresh -eq $winThresh) {
        Add-CheckResult "threshold-parity" $true "statusline" "all platforms: $macThresh"
    } else {
        Add-CheckResult "threshold-parity" $false "statusline" "macOS=[$macThresh] Linux=[$linThresh] Windows=[$winThresh]"
    }
}

# --- Check 10: Cache TTL parity across statuslines ---
if ((Test-Path $macSl) -and (Test-Path $linSl) -and (Test-Path $winSl)) {
    $macGitTtl = Get-Tag $macSl "cache" "GIT_TTL"
    $linGitTtl = Get-Tag $linSl "cache" "GIT_TTL"
    $winGitTtl = Get-Tag $winSl "cache" "GIT_TTL"

    $macOcDiv = Get-Tag $macSl "cache" "OUTPUT_BUCKET"
    $linOcDiv = Get-Tag $linSl "cache" "OUTPUT_BUCKET"
    $winOcDiv = Get-Tag $winSl "cache" "OUTPUT_BUCKET"

    if (-not $macGitTtl -and -not $linGitTtl -and -not $winGitTtl) {
        Add-CheckResult "cache-ttl-parity" $false "statusline" "could not extract git TTL (check @parity:cache tags)"
    } else {
        $gitVals = "macOS=$macGitTtl Linux=$linGitTtl Windows=$winGitTtl"
        if ($macGitTtl -eq $linGitTtl -and $macGitTtl -eq $winGitTtl) {
            Add-CheckResult "cache-ttl-parity" $true "statusline" "git TTL: $gitVals"
        } else {
            Add-CheckResult "cache-ttl-parity" $false "statusline" "git TTL mismatch: $gitVals"
        }
    }

    if (-not $macOcDiv -and -not $linOcDiv -and -not $winOcDiv) {
        Add-CheckResult "cache-ttl-parity" $false "statusline" "could not extract output-cache bucket divisor (check @parity:cache tags)"
    } else {
        $ocVals = "macOS=$macOcDiv Linux=$linOcDiv Windows=$winOcDiv"
        if ($macOcDiv -eq $linOcDiv -and $macOcDiv -eq $winOcDiv) {
            Add-CheckResult "cache-ttl-parity" $true "statusline" "output-cache bucket divisor: $ocVals"
        } else {
            Add-CheckResult "cache-ttl-parity" $false "statusline" "output-cache bucket divisor mismatch: $ocVals"
        }
    }
}

# --- Check 11: Installer/uninstaller UI function symmetry ---
$bashUiFuncs = @("step", "ok", "warn", "err", "info", "human_size")
$psUiFuncs   = @("Step", "Ok", "Warn", "Err", "Info", "HumanSize", "Format-Json")

foreach ($dir in @("macos", "linux")) {
    $inst   = Join-Path $Root "$dir/install.sh"
    $uninst = Join-Path $Root "$dir/uninstall.sh"
    if (-not ((Test-Path $inst) -and (Test-Path $uninst))) { continue }

    $instContent   = Get-Content $inst
    $uninstContent = Get-Content $uninst
    foreach ($fn in $bashUiFuncs) {
        $inInst   = @($instContent   | Where-Object { $_ -match "^\s*(function\s+)?${fn}\s*\(\)" }).Count
        $inUninst = @($uninstContent | Where-Object { $_ -match "^\s*(function\s+)?${fn}\s*\(\)" }).Count
        if ($inInst -gt 0 -and $inUninst -eq 0) {
            Add-CheckResult "installer-uninstaller-function-symmetry" $false $dir "install.sh defines ${fn}() but uninstall.sh does not"
        } elseif ($inInst -eq 0 -and $inUninst -gt 0) {
            Add-CheckResult "installer-uninstaller-function-symmetry" $false $dir "uninstall.sh defines ${fn}() but install.sh does not"
        }
    }
}

$instPs   = Join-Path $Root "windows/install.ps1"
$uninstPs = Join-Path $Root "windows/uninstall.ps1"
if ((Test-Path $instPs) -and (Test-Path $uninstPs)) {
    $instPsContent   = Get-Content $instPs
    $uninstPsContent = Get-Content $uninstPs
    foreach ($fn in $psUiFuncs) {
        $inInst   = @($instPsContent   | Where-Object { $_ -match "^\s*function\s+${fn}\b" }).Count
        $inUninst = @($uninstPsContent | Where-Object { $_ -match "^\s*function\s+${fn}\b" }).Count
        if ($inInst -gt 0 -and $inUninst -eq 0) {
            Add-CheckResult "installer-uninstaller-function-symmetry" $false "windows" "install.ps1 defines $fn but uninstall.ps1 does not"
        } elseif ($inInst -eq 0 -and $inUninst -gt 0) {
            Add-CheckResult "installer-uninstaller-function-symmetry" $false "windows" "uninstall.ps1 defines $fn but install.ps1 does not"
        }
    }
}

# --- Check 12: JSON field coverage including Windows (extends check 5) ---
function Get-PsJsonFields([string]$FilePath) {
    $block = Get-Block $FilePath "json-extract"
    $fields = [System.Collections.ArrayList]::new()
    foreach ($line in $block) {
        if ($line -match 'Get-Val\s+\$json\s+@\(([^)]+)\)') {
            $raw = $Matches[1] -replace "'", "" -replace "\s*,\s*", "."
            $null = $fields.Add(".$raw")
        }
    }
    return ($fields | Sort-Object -Unique)
}

if ((Test-Path $macSl) -and (Test-Path $winSl)) {
    $macFields12 = @(Get-JqFields $macSl)
    $winFields12 = @(Get-PsJsonFields $winSl)

    if ($macFields12.Count -eq 0 -and $winFields12.Count -eq 0) {
        Add-CheckResult "json-field-coverage" $false "statusline" "could not extract fields from either platform (check @parity:json-extract markers)"
    } elseif ($macFields12.Count -eq 0 -or $winFields12.Count -eq 0) {
        Add-CheckResult "json-field-coverage" $false "statusline" "extraction failed on one platform"
    } else {
        $macOnly12 = @($macFields12 | Where-Object { $_ -notin $winFields12 }) | Select-Object -First 5
        $winOnly12 = @($winFields12 | Where-Object { $_ -notin $macFields12 }) | Select-Object -First 5

        if ($macOnly12.Count -eq 0 -and $winOnly12.Count -eq 0) {
            Add-CheckResult "json-field-coverage" $true "statusline" "Bash and Windows extract the same JSON fields"
        } else {
            $detail = ""
            if ($macOnly12.Count -gt 0) { $detail = "Bash-only: $($macOnly12 -join ', ')" }
            if ($winOnly12.Count -gt 0) { $detail = "$detail Windows-only: $($winOnly12 -join ', ')".Trim() }
            Add-CheckResult "json-field-coverage" $false "statusline" $detail
        }
    }
}

# --- Check 13: Runtime tests (native Windows scripts) ---
function Run-RuntimeTest {
    param([string]$Name, [string]$Input, [string]$Script, [string]$Extra)
    $relPath = "windows/" + (Split-Path -Leaf $Script)
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -File `"$Script`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $Input) { $proc.StandardInput.Write($Input) }
        $proc.StandardInput.Close()
        $stdoutContent = $proc.StandardOutput.ReadToEnd()
        $stderrContent = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(30000)
        $exitCode = $proc.ExitCode
        $proc.Dispose()
    } catch {
        Add-CheckResult $Name $false $relPath ("process error: " + $_.Exception.Message)
        return
    } finally {
        if (Test-Path $stderrFile) { Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue }
    }

    $detail = "exit=$exitCode, stderr=$($stderrContent.Length)b, stdout=$($stdoutContent.Length)b"
    if ($exitCode -ne 0) {
        Add-CheckResult $Name $false $relPath "non-zero exit ($exitCode): $detail"
        return
    }
    if ($stderrContent.Length -gt 0) {
        Add-CheckResult $Name $false $relPath ("stderr: " + $stderrContent.Substring(0, [Math]::Min(200, $stderrContent.Length)))
        return
    }
    switch ($Extra) {
        'stdout-non-empty' {
            if ($stdoutContent.Length -eq 0) {
                Add-CheckResult $Name $false $relPath "stdout is empty"
                return
            }
        }
        'stdout-has-bad-json' {
            if ($stdoutContent -notmatch 'bad JSON') {
                Add-CheckResult $Name $false $relPath "stdout missing 'bad JSON' marker"
                return
            }
        }
    }
    Add-CheckResult $Name $true $relPath $detail
}

$slPs = Join-Path $Root "windows/statusline.ps1"
$ntPs = Join-Path $Root "windows/notify.ps1"
$grPs = Join-Path $Root "windows/git-refresh.ps1"

if (Test-Path $slPs) {
    Run-RuntimeTest "runtime-empty-json"      '{}'  $slPs "stdout-non-empty"
    Run-RuntimeTest "runtime-malformed-input"  'not json at all' $slPs "stdout-has-bad-json"
    Run-RuntimeTest "runtime-empty-stdin"      ''    $slPs ""
    Run-RuntimeTest "runtime-extreme-values"   '{"context_window":{"used_percentage":99.99},"cost":{"total_cost_usd":9999.99}}' $slPs "stdout-non-empty"
    Run-RuntimeTest "runtime-zero-values"      '{"context_window":{"used_percentage":0},"cost":{"total_cost_usd":0}}' $slPs "stdout-non-empty"
    Run-RuntimeTest "runtime-negative-pct"     '{"context_window":{"used_percentage":-5}}' $slPs "stdout-non-empty"
    Run-RuntimeTest "runtime-zero-ctx-size"    '{"context_window":{"context_window_size":0}}' $slPs "stdout-non-empty"
}
if (Test-Path $ntPs) {
    Run-RuntimeTest "runtime-notify-empty"     '' $ntPs ""
}
if (Test-Path $grPs) {
    Run-RuntimeTest "runtime-gitrefresh-tool"  '{"tool_name":"Write"}' $grPs ""
    Run-RuntimeTest "runtime-gitrefresh-empty" '{}' $grPs ""
}

# --- Output ---
if ($results.Count -eq 0) {
    Write-Output "[]"
} elseif ($results.Count -eq 1) {
    Write-Output "[$($results[0] | ConvertTo-Json -Depth 5 -Compress)]"
} else {
    $results | ConvertTo-Json -Depth 5
}
