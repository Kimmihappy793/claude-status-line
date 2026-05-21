#!/usr/bin/env bash
# Deterministic parity checks for claude-status-line code review.
# Outputs a JSON array of pass/fail assertions to stdout.
# Requires: jq, Bash 4+
# Usage: bash check-parity.sh [project-root]

set -uo pipefail

ROOT="${1:-.}"
RESULTS="[]"

add_result() {
    local check="$1" passed="$2" file="$3" detail="$4"
    RESULTS=$(printf '%s' "$RESULTS" | jq --arg c "$check" --arg p "$passed" --arg f "$file" --arg d "$detail" \
        '. + [{"check": $c, "passed": ($p == "true"), "file": $f, "detail": $d}]')
}

get_tag() {
    local file="$1" category="$2" key="$3"
    grep "@parity:${category} ${key}=" "$file" 2>/dev/null | grep -oE "${key}=\S+" | head -1 | cut -d= -f2
}

get_block() {
    local file="$1" name="$2"
    sed -n "/@parity:${name}-begin/,/@parity:${name}-end/p" "$file" | grep -v '@parity:'
}

# --- Check 1: Every script ends with exit 0 ---
for f in "$ROOT"/macos/*.sh "$ROOT"/linux/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    dir=$(basename "$(dirname "$f")")
    last_code=$(grep -v '^\s*$' "$f" | tail -1 | sed 's/^[[:space:]]*//')
    if [[ "$last_code" == "exit 0" ]]; then
        add_result "exit-0-termination" "true" "$dir/$base" "ends with exit 0"
    else
        add_result "exit-0-termination" "false" "$dir/$base" "last non-blank line: $last_code"
    fi
done

for f in "$ROOT"/windows/*.ps1; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    last_code=$(grep -v '^\s*$' "$f" | tail -1 | sed 's/^[[:space:]]*//')
    if [[ "$last_code" == "exit 0" ]]; then
        add_result "exit-0-termination" "true" "windows/$base" "ends with exit 0"
    else
        add_result "exit-0-termination" "false" "windows/$base" "last non-blank line: $last_code"
    fi
done

# --- Check 2: No macOS-isms in Linux files ---
macos_patterns=("afplay" "terminal-notifier" "/System/Library/Sounds" "brew install" "Homebrew")
for f in "$ROOT"/linux/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    for pat in "${macos_patterns[@]}"; do
        if grep -qn "$pat" "$f" 2>/dev/null; then
            line=$(grep -n "$pat" "$f" | head -1 | cut -d: -f1)
            add_result "no-macos-isms-in-linux" "false" "linux/$base" "found '$pat' at line $line"
        fi
    done
done

# --- Check 3: No Linux-isms in macOS files ---
linux_patterns=("paplay" "aplay" "notify-send" "apt install" "dnf install" "pacman -S" "zypper install")
for f in "$ROOT"/macos/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    for pat in "${linux_patterns[@]}"; do
        if grep -qn "$pat" "$f" 2>/dev/null; then
            line=$(grep -n "$pat" "$f" | head -1 | cut -d: -f1)
            add_result "no-linux-isms-in-macos" "false" "macos/$base" "found '$pat' at line $line"
        fi
    done
done

# --- Check 4: Rendering constants match across macOS and Linux statuslines ---
for var in CACHE_VERSION LABEL_W; do
    mac_val=$(get_tag "$ROOT/macos/statusline.sh" "constant" "$var")
    lin_val=$(get_tag "$ROOT/linux/statusline.sh" "constant" "$var")
    if [[ -z "$mac_val" && -z "$lin_val" ]]; then
        add_result "constant-parity" "false" "statusline" "$var: could not extract from either platform (check @parity:constant tags)"
    elif [[ -z "$mac_val" || -z "$lin_val" ]]; then
        add_result "constant-parity" "false" "statusline" "$var: extraction failed on one platform (macOS=${mac_val:-?}, Linux=${lin_val:-?})"
    elif [[ "$mac_val" == "$lin_val" ]]; then
        add_result "constant-parity" "true" "statusline" "$var: macOS=$mac_val, Linux=$lin_val"
    else
        add_result "constant-parity" "false" "statusline" "$var: macOS=$mac_val, Linux=$lin_val (MISMATCH)"
    fi
done

# --- Check 5: Same jq fields extracted on macOS and Linux ---
extract_jq_fields() {
    local file="$1"
    get_block "$file" "json-extract" \
        | grep -oE '\.[a-z_][a-z0-9_.]*' | sort -u
}
mac_fields=$(extract_jq_fields "$ROOT/macos/statusline.sh")
lin_fields=$(extract_jq_fields "$ROOT/linux/statusline.sh")
if [[ -z "$mac_fields" && -z "$lin_fields" ]]; then
    add_result "json-field-parity" "false" "statusline" "could not extract fields from either platform (check @parity:json-extract markers)"
elif [[ -z "$mac_fields" || -z "$lin_fields" ]]; then
    add_result "json-field-parity" "false" "statusline" "extraction failed on one platform"
else
    mac_only=$(comm -23 <(echo "$mac_fields") <(echo "$lin_fields") | head -5)
    lin_only=$(comm -13 <(echo "$mac_fields") <(echo "$lin_fields") | head -5)
    if [[ -z "$mac_only" && -z "$lin_only" ]]; then
        add_result "json-field-parity" "true" "statusline" "macOS and Linux extract the same jq fields"
    else
        detail=""
        [[ -n "$mac_only" ]] && detail="macOS-only: $(echo "$mac_only" | tr '\n' ', ')"
        [[ -n "$lin_only" ]] && detail="${detail:+$detail }Linux-only: $(echo "$lin_only" | tr '\n' ', ')"
        add_result "json-field-parity" "false" "statusline" "$detail"
    fi
fi

# --- Check 6: Function naming conventions ---
for f in "$ROOT"/macos/*.sh "$ROOT"/linux/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    dir=$(basename "$(dirname "$f")")
    bad_funcs=$(awk '/^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*[[:space:]]*\(\)/ {
        line = $0; gsub(/^[[:space:]]*/, "", line); gsub(/function[[:space:]]+/, "", line)
        gsub(/[[:space:]]*\(\).*/, "", line)
        if (line ~ /[A-Z]/) print line
    }' "$f" || true)
    if [[ -n "$bad_funcs" ]]; then
        add_result "naming-convention" "false" "$dir/$base" "non-snake_case functions: $(echo "$bad_funcs" | tr '\n' ', ')"
    fi
done

for f in "$ROOT"/windows/*.ps1; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    bad_funcs=$(awk '/^[[:space:]]*function[[:space:]]+[A-Za-z]/ {
        line = $0; gsub(/^[[:space:]]*function[[:space:]]+/, "", line); gsub(/[[:space:]({].*/, "", line)
        if (line ~ /^[a-z]/) print line
    }' "$f" || true)
    if [[ -n "$bad_funcs" ]]; then
        add_result "naming-convention" "false" "windows/$base" "non-PascalCase functions: $(echo "$bad_funcs" | tr '\n' ', ')"
    fi
done

# --- Check 7: No unguarded Write-Error in Windows scripts ---
for f in "$ROOT"/windows/*.ps1; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    hits=$(grep -n 'Write-Error' "$f" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        line=$(echo "$hits" | head -1 | cut -d: -f1)
        add_result "no-stderr-output" "false" "windows/$base" "Write-Error at line $line (stderr)"
    fi
done

# --- Check 8: ANSI color variable parity across statuslines ---
extract_bash_colors() {
    local file="$1"
    get_block "$file" "colors" \
        | sed -n 's/^[[:space:]]*\([A-Z_]*\)="\${ESC}\[\([0-9;]*\)m"/\1=\2/p' | sort
}

extract_ps_colors() {
    local file="$1"
    get_block "$file" "colors" \
        | sed -n 's/^[[:space:]]*\$\([A-Z_]*\)[[:space:]]*=[[:space:]]*Ansi[[:space:]]*\([0-9;]*\)/\1=\2/p' \
        | sed "s/'//g" | sort
}

if [[ -f "$ROOT/macos/statusline.sh" && -f "$ROOT/linux/statusline.sh" && -f "$ROOT/windows/statusline.ps1" ]]; then
    mac_colors=$(extract_bash_colors "$ROOT/macos/statusline.sh")
    lin_colors=$(extract_bash_colors "$ROOT/linux/statusline.sh")
    win_colors=$(extract_ps_colors "$ROOT/windows/statusline.ps1")

    if [[ -z "$mac_colors" && -z "$lin_colors" ]]; then
        add_result "ansi-color-parity" "false" "statusline" "could not extract colors from Bash scripts (check @parity:colors markers)"
    else
        mac_only_c=$(comm -23 <(echo "$mac_colors") <(echo "$lin_colors"))
        lin_only_c=$(comm -13 <(echo "$mac_colors") <(echo "$lin_colors"))
        if [[ -z "$mac_only_c" && -z "$lin_only_c" ]]; then
            add_result "ansi-color-parity" "true" "statusline" "macOS and Linux define identical color sets"
        else
            detail=""
            [[ -n "$mac_only_c" ]] && detail="macOS-only: $(echo "$mac_only_c" | tr '\n' ', ')"
            [[ -n "$lin_only_c" ]] && detail="${detail:+$detail }Linux-only: $(echo "$lin_only_c" | tr '\n' ', ')"
            add_result "ansi-color-parity" "false" "statusline" "$detail"
        fi

        if [[ -z "$win_colors" ]]; then
            add_result "ansi-color-parity" "false" "statusline" "could not extract colors from Windows script (check @parity:colors markers)"
        else
            bash_ref="$mac_colors"
            win_only_c=$(comm -23 <(echo "$win_colors") <(echo "$bash_ref"))
            bash_only_c=$(comm -13 <(echo "$win_colors") <(echo "$bash_ref"))
            if [[ -z "$win_only_c" && -z "$bash_only_c" ]]; then
                add_result "ansi-color-parity" "true" "statusline" "Windows and Bash define identical color sets"
            else
                detail=""
                [[ -n "$bash_only_c" ]] && detail="Bash-only: $(echo "$bash_only_c" | tr '\n' ', ')"
                [[ -n "$win_only_c" ]] && detail="${detail:+$detail }Windows-only: $(echo "$win_only_c" | tr '\n' ', ')"
                add_result "ansi-color-parity" "false" "statusline" "$detail"
            fi
        fi
    fi
fi

# --- Check 9: Color threshold parity across statuslines ---
if [[ -f "$ROOT/macos/statusline.sh" && -f "$ROOT/linux/statusline.sh" && -f "$ROOT/windows/statusline.ps1" ]]; then
    mac_ctx_crit=$(get_tag "$ROOT/macos/statusline.sh" "threshold" "CONTEXT_CRIT")
    mac_ctx_warn=$(get_tag "$ROOT/macos/statusline.sh" "threshold" "CONTEXT_WARN")
    mac_cost_warn=$(get_tag "$ROOT/macos/statusline.sh" "threshold" "COST_WARN")
    lin_ctx_crit=$(get_tag "$ROOT/linux/statusline.sh" "threshold" "CONTEXT_CRIT")
    lin_ctx_warn=$(get_tag "$ROOT/linux/statusline.sh" "threshold" "CONTEXT_WARN")
    lin_cost_warn=$(get_tag "$ROOT/linux/statusline.sh" "threshold" "COST_WARN")
    win_ctx_crit=$(get_tag "$ROOT/windows/statusline.ps1" "threshold" "CONTEXT_CRIT")
    win_ctx_warn=$(get_tag "$ROOT/windows/statusline.ps1" "threshold" "CONTEXT_WARN")
    win_cost_warn=$(get_tag "$ROOT/windows/statusline.ps1" "threshold" "COST_WARN")

    mac_thresh="ctx_crit=${mac_ctx_crit:-?} ctx_warn=${mac_ctx_warn:-?} cost_warn=${mac_cost_warn:-?}"
    lin_thresh="ctx_crit=${lin_ctx_crit:-?} ctx_warn=${lin_ctx_warn:-?} cost_warn=${lin_cost_warn:-?}"
    win_thresh="ctx_crit=${win_ctx_crit:-?} ctx_warn=${win_ctx_warn:-?} cost_warn=${win_cost_warn:-?}"

    if [[ "$mac_ctx_crit" == "" && "$lin_ctx_crit" == "" && "$win_ctx_crit" == "" ]]; then
        add_result "threshold-parity" "false" "statusline" "could not extract thresholds (check @parity:threshold tags)"
    elif [[ "$mac_thresh" == "$lin_thresh" && "$mac_thresh" == "$win_thresh" ]]; then
        add_result "threshold-parity" "true" "statusline" "all platforms: $mac_thresh"
    else
        add_result "threshold-parity" "false" "statusline" "macOS=[$mac_thresh] Linux=[$lin_thresh] Windows=[$win_thresh]"
    fi
fi

# --- Check 10: Cache TTL parity across statuslines ---
if [[ -f "$ROOT/macos/statusline.sh" && -f "$ROOT/linux/statusline.sh" && -f "$ROOT/windows/statusline.ps1" ]]; then
    mac_git_ttl=$(get_tag "$ROOT/macos/statusline.sh" "cache" "GIT_TTL")
    lin_git_ttl=$(get_tag "$ROOT/linux/statusline.sh" "cache" "GIT_TTL")
    win_git_ttl=$(get_tag "$ROOT/windows/statusline.ps1" "cache" "GIT_TTL")

    mac_oc_div=$(get_tag "$ROOT/macos/statusline.sh" "cache" "OUTPUT_BUCKET")
    lin_oc_div=$(get_tag "$ROOT/linux/statusline.sh" "cache" "OUTPUT_BUCKET")
    win_oc_div=$(get_tag "$ROOT/windows/statusline.ps1" "cache" "OUTPUT_BUCKET")

    if [[ -z "$mac_git_ttl" && -z "$lin_git_ttl" && -z "$win_git_ttl" ]]; then
        add_result "cache-ttl-parity" "false" "statusline" "could not extract git TTL (check @parity:cache tags)"
    else
        git_vals="macOS=${mac_git_ttl:-?} Linux=${lin_git_ttl:-?} Windows=${win_git_ttl:-?}"
        if [[ "$mac_git_ttl" == "$lin_git_ttl" && "$mac_git_ttl" == "$win_git_ttl" ]]; then
            add_result "cache-ttl-parity" "true" "statusline" "git TTL: $git_vals"
        else
            add_result "cache-ttl-parity" "false" "statusline" "git TTL mismatch: $git_vals"
        fi
    fi

    if [[ -z "$mac_oc_div" && -z "$lin_oc_div" && -z "$win_oc_div" ]]; then
        add_result "cache-ttl-parity" "false" "statusline" "could not extract output-cache bucket divisor (check @parity:cache tags)"
    else
        oc_vals="macOS=${mac_oc_div:-?} Linux=${lin_oc_div:-?} Windows=${win_oc_div:-?}"
        if [[ "$mac_oc_div" == "$lin_oc_div" && "$mac_oc_div" == "$win_oc_div" ]]; then
            add_result "cache-ttl-parity" "true" "statusline" "output-cache bucket divisor: $oc_vals"
        else
            add_result "cache-ttl-parity" "false" "statusline" "output-cache bucket divisor mismatch: $oc_vals"
        fi
    fi
fi

# --- Check 11: Installer/uninstaller UI function symmetry ---
bash_ui_funcs="step ok warn err info human_size"
ps_ui_funcs="Step Ok Warn Err Info HumanSize Format-Json"

for dir in macos linux; do
    inst="$ROOT/$dir/install.sh"
    uninst="$ROOT/$dir/uninstall.sh"
    [[ -f "$inst" && -f "$uninst" ]] || continue

    for fn in $bash_ui_funcs; do
        in_inst=$(grep -cE "^[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "$inst" 2>/dev/null || true)
        in_uninst=$(grep -cE "^[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "$uninst" 2>/dev/null || true)
        if [[ "$in_inst" -gt 0 && "$in_uninst" -eq 0 ]]; then
            add_result "installer-uninstaller-function-symmetry" "false" "$dir" "install.sh defines $fn() but uninstall.sh does not"
        elif [[ "$in_inst" -eq 0 && "$in_uninst" -gt 0 ]]; then
            add_result "installer-uninstaller-function-symmetry" "false" "$dir" "uninstall.sh defines $fn() but install.sh does not"
        fi
    done
done

inst_ps="$ROOT/windows/install.ps1"
uninst_ps="$ROOT/windows/uninstall.ps1"
if [[ -f "$inst_ps" && -f "$uninst_ps" ]]; then
    for fn in $ps_ui_funcs; do
        in_inst=$(grep -cE "^\s*function\s+${fn}\b" "$inst_ps" 2>/dev/null || true)
        in_uninst=$(grep -cE "^\s*function\s+${fn}\b" "$uninst_ps" 2>/dev/null || true)
        if [[ "$in_inst" -gt 0 && "$in_uninst" -eq 0 ]]; then
            add_result "installer-uninstaller-function-symmetry" "false" "windows" "install.ps1 defines $fn but uninstall.ps1 does not"
        elif [[ "$in_inst" -eq 0 && "$in_uninst" -gt 0 ]]; then
            add_result "installer-uninstaller-function-symmetry" "false" "windows" "uninstall.ps1 defines $fn but install.ps1 does not"
        fi
    done
fi

# --- Check 12: JSON field coverage including Windows (extends check 5) ---
extract_ps_fields() {
    local file="$1"
    get_block "$file" "json-extract" \
        | grep -oE "Get-Val\s+\\\$json\s+@\([^)]+\)" \
        | sed "s/Get-Val[[:space:]]*\\\$json[[:space:]]*@(//; s/)$//" \
        | sed "s/'//g; s/[[:space:]]*,[[:space:]]*/./g; s/^/./" \
        | sort -u
}

if [[ -f "$ROOT/windows/statusline.ps1" && -f "$ROOT/macos/statusline.sh" ]]; then
    mac_fields_12=$(extract_jq_fields "$ROOT/macos/statusline.sh")
    win_fields_12=$(extract_ps_fields "$ROOT/windows/statusline.ps1")

    if [[ -z "$mac_fields_12" && -z "$win_fields_12" ]]; then
        add_result "json-field-coverage" "false" "statusline" "could not extract fields from either platform (check @parity:json-extract markers)"
    elif [[ -z "$mac_fields_12" || -z "$win_fields_12" ]]; then
        add_result "json-field-coverage" "false" "statusline" "extraction failed on one platform"
    else
        mac_only_12=$(comm -23 <(echo "$mac_fields_12") <(echo "$win_fields_12") | head -5)
        win_only_12=$(comm -13 <(echo "$mac_fields_12") <(echo "$win_fields_12") | head -5)

        if [[ -z "$mac_only_12" && -z "$win_only_12" ]]; then
            add_result "json-field-coverage" "true" "statusline" "Bash and Windows extract the same JSON fields"
        else
            detail=""
            [[ -n "$mac_only_12" ]] && detail="Bash-only: $(echo "$mac_only_12" | tr '\n' ', ')"
            [[ -n "$win_only_12" ]] && detail="${detail:+$detail }Windows-only: $(echo "$win_only_12" | tr '\n' ', ')"
            add_result "json-field-coverage" "false" "statusline" "$detail"
        fi
    fi
fi

# --- Check 13: Runtime tests (native Bash scripts) ---
run_rt() {
    local name="$1" input="$2" script="$3" extra="$4"
    local rel="$(basename "$(dirname "$script")")/$(basename "$script")"
    local stderr_file exit_code stdout_out stderr_out
    stderr_file=$(mktemp)
    stdout_out=$(printf '%s' "$input" | bash "$script" 2>"$stderr_file")
    exit_code=$?
    stderr_out=$(cat "$stderr_file")
    rm -f "$stderr_file"
    local detail="exit=$exit_code, stderr=${#stderr_out}b, stdout=${#stdout_out}b"

    if [[ $exit_code -ne 0 ]]; then
        add_result "$name" "false" "$rel" "non-zero exit ($exit_code): $detail"
        return
    fi
    if [[ -n "$stderr_out" ]]; then
        add_result "$name" "false" "$rel" "stderr: ${stderr_out:0:200}"
        return
    fi
    case "$extra" in
        stdout-non-empty)
            if [[ -z "$stdout_out" ]]; then
                add_result "$name" "false" "$rel" "stdout is empty"
                return
            fi ;;
        stdout-has-bad-json)
            if [[ "$stdout_out" != *"bad JSON"* ]]; then
                add_result "$name" "false" "$rel" "stdout missing 'bad JSON' marker"
                return
            fi ;;
    esac
    add_result "$name" "true" "$rel" "$detail"
}

for dir in macos linux; do
    sl="$ROOT/$dir/statusline.sh"
    nt="$ROOT/$dir/notify.sh"
    gr="$ROOT/$dir/git-refresh.sh"

    if [[ -f "$sl" ]]; then
        run_rt "runtime-empty-json"       '{}' "$sl" "stdout-non-empty"
        run_rt "runtime-malformed-input"  'not json at all' "$sl" "stdout-has-bad-json"
        run_rt "runtime-empty-stdin"      '' "$sl" ""
        run_rt "runtime-extreme-values"   '{"context_window":{"used_percentage":99.99},"cost":{"total_cost_usd":9999.99}}' "$sl" "stdout-non-empty"
        run_rt "runtime-zero-values"      '{"context_window":{"used_percentage":0},"cost":{"total_cost_usd":0}}' "$sl" "stdout-non-empty"
        run_rt "runtime-negative-pct"     '{"context_window":{"used_percentage":-5}}' "$sl" "stdout-non-empty"
        run_rt "runtime-zero-ctx-size"    '{"context_window":{"context_window_size":0}}' "$sl" "stdout-non-empty"
    fi
    if [[ -f "$nt" ]]; then
        run_rt "runtime-notify-empty"     '' "$nt" ""
    fi
    if [[ -f "$gr" ]]; then
        run_rt "runtime-gitrefresh-tool"  '{"tool_name":"Write"}' "$gr" ""
        run_rt "runtime-gitrefresh-empty" '{}' "$gr" ""
    fi
done

# Output
printf '%s\n' "$RESULTS" | jq '.'
