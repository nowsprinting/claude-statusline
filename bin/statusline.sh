#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# ── Extract JSON data ───────────────────────────────────
# ponytail: line-per-field instead of @tsv — bash IFS collapses empty tab fields
{
    read -r model_name
    read -r pct_used
    read -r cwd
    read -r duration_ms
    read -r five_hour_pct
    read -r five_hour_reset_epoch
    read -r seven_day_pct
    read -r seven_day_reset_epoch
    read -r effort
    read -r pc_warm
    read -r pc_ttl
    read -r pc_expires_at
    read -r pc_hit_pct
    read -r pc_misses
    read -r pc_miss_cause
    read -r pc_recache_k
} <<EOF
$(echo "$input" | jq -r '
    (.model.display_name // "Claude"),
    ((.context_window.used_percentage // 0) | floor),
    (.cwd // ""),
    (.cost.total_duration_ms // 0),
    ((.rate_limits.five_hour.used_percentage // -1) | round),
    (.rate_limits.five_hour.resets_at // 0),
    ((.rate_limits.seven_day.used_percentage // -1) | round),
    (.rate_limits.seven_day.resets_at // 0),
    (.effort.level // ""),
    # ponytail: not `// ""` — it treats false as absent and would hide a cold cache
    (.prompt_cache.warm | if . == null then "" else tostring end),
    (.prompt_cache.ttl // ""),
    (.prompt_cache.expires_at // ""),
    (.prompt_cache.hit_ratio | if . == null then "" else . * 100 | round end),
    (.prompt_cache.misses // ""),
    (.prompt_cache.last_miss_cause.causes // [] | join(", ")),
    (.prompt_cache.recache_tokens_if_cold | if . == null then "" else . / 1000 | round end)')
EOF

# ponytail: stdin, not settings.json — /effort is session-scoped and never
# writes effortLevel; stdin carries the resolved level (settings + flag + /effort)
if [ -z "$effort" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null || echo default)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Effort ──
pct_color=$(color_for_pct "$pct_used")
[ -z "$cwd" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
elapsed=$(( duration_ms / 1000 ))
if [ "$elapsed" -ge 3600 ]; then
    session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
elif [ "$elapsed" -ge 60 ]; then
    session_duration="$(( elapsed / 60 ))m"
elif [ "$elapsed" -gt 0 ]; then
    session_duration="${elapsed}s"
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high|xhigh|max) line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=10

add_rate_line() {
    local label=$1 pct=$2 reset_epoch=$3 style=$4
    local bar pct_color pct_fmt reset_str
    bar=$(build_bar "$pct" "$bar_width")
    pct_color=$(color_for_pct "$pct")
    pct_fmt=$(printf "%3d" "$pct")
    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}$(printf '%-12s' "$label")${reset} ${bar} ${pct_color}${pct_fmt}%${reset}"
    reset_str=$(format_epoch_time "$reset_epoch" "$style")
    [ -n "$reset_str" ] && rate_lines+=" ${dim}⟳${reset} ${white}${reset_str}${reset}"
}

# ponytail: OAuth usage API, not stdin — as of 2.1.251 stdin rate_limits carries
# no model-scoped weekly window, which Claude Desktop shows as "Weekly Fable"
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude

needs_refresh=true
if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    [ $(( $(date +%s) - cache_mtime )) -lt "$cache_max_age" ] && needs_refresh=false
fi

if $needs_refresh; then
    token="$CLAUDE_CODE_OAUTH_TOKEN"
    if [ -z "$token" ] && command -v security >/dev/null 2>&1; then
        token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
    if [ -z "$token" ] && command -v secret-tool >/dev/null 2>&1; then
        token=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi

    if [ -n "$token" ]; then
        response=$(curl -s --max-time 5 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if echo "$response" | jq -e '.limits' >/dev/null 2>&1; then
            echo "$response" > "$cache_file"
        fi
    fi
fi

usage_data=""
[ -f "$cache_file" ] && usage_data=$(cat "$cache_file" 2>/dev/null)

if [ -n "$usage_data" ]; then
    while IFS= read -r label && IFS= read -r pct && IFS= read -r reset_iso && IFS= read -r style; do
        add_rate_line "$label" "$pct" "$(iso_to_epoch "$reset_iso")" "$style"
    done <<EOF
$(echo "$usage_data" | jq -r '.limits[]? | select(.kind == "session" or .kind == "weekly_all" or .kind == "weekly_scoped") |
    (if .kind == "session" then "current"
     elif .kind == "weekly_all" then "weekly"
     else "weekly " + ((.scope.model.display_name // "model") | ascii_downcase) end),
    ((.percent // 0) | round),
    (.resets_at // "0"),
    (if .kind == "session" then "time" else "datetime" end)' 2>/dev/null)
EOF
fi

# stdin fallback carries only the five_hour/seven_day windows
if [ -z "$rate_lines" ]; then
    [ "$five_hour_pct" -ge 0 ] 2>/dev/null && add_rate_line "current" "$five_hour_pct" "$five_hour_reset_epoch" "time"
    [ "$seven_day_pct" -ge 0 ] 2>/dev/null && add_rate_line "weekly" "$seven_day_pct" "$seven_day_reset_epoch" "datetime"
fi

# ── Prompt cache line ───────────────────────────────────
if [ -n "$pc_warm" ]; then
    pc_left=""
    [ -n "$pc_expires_at" ] && pc_left=$(( pc_expires_at - $(date +%s) ))
    # stdin may still say warm when the expires_at re-run fires, so trust the clock
    [ -n "$pc_left" ] && [ "$pc_left" -le 0 ] && pc_warm=false

    if [ "$pc_warm" = "true" ]; then
        case "$pc_ttl" in
            *h) pc_ttl_secs=$(( ${pc_ttl%h} * 3600 )) ;;
            *m) pc_ttl_secs=$(( ${pc_ttl%m} * 60 )) ;;
            *)  pc_ttl_secs="" ;;
        esac
        pc_color=$green
        pc_tail=""
        cache_line="●"
        [ -n "$pc_ttl" ] && cache_line+=" ${pc_ttl}"
        if [ -n "$pc_ttl_secs" ] && [ -n "$pc_left" ]; then
            [ $(( pc_left * 5 )) -lt "$pc_ttl_secs" ] && pc_color=$yellow
            # not build_bar: its colors rank usage, where full means danger
            pc_width=6
            pc_filled=$(( (pc_left * pc_width * 2 + pc_ttl_secs) / (pc_ttl_secs * 2) ))
            [ "$pc_filled" -gt "$pc_width" ] && pc_filled=$pc_width
            pc_bar=""
            for ((i=0; i<pc_width; i++)); do
                [ "$i" -lt "$pc_filled" ] && pc_bar+="█" || pc_bar+="░"
            done
            cache_line+=" ${pc_bar}"
        fi
        if [ -n "$pc_left" ]; then
            # ceil, not floor — "0m left" would read as already cold
            if [ "$pc_left" -lt 60 ]; then cache_line+=" ${pc_left}s left"
            else cache_line+=" $(( (pc_left + 59) / 60 ))m left"
            fi
        fi
        [ -n "$pc_hit_pct" ] && pc_tail+="${sep}${white}hit ${pc_hit_pct}%${reset}"
        [ -n "$pc_misses" ] && pc_tail+="${sep}${white}misses ${pc_misses}${reset}"
    else
        pc_color=$red
        pc_tail=""
        cache_line="○ cold"
        [ -n "$pc_recache_k" ] && pc_tail+="${sep}${white}next message re-caches ${pc_recache_k}k tokens${reset}"
        [ -n "$pc_miss_cause" ] && pc_tail+="${sep}${white}last miss: ${pc_miss_cause}${reset}"
    fi

    # prepended here, not before the usage loop — the stdin fallback keys off an empty rate_lines
    rate_lines="${white}cache${reset} ${pc_color}${cache_line}${reset}${pc_tail}${rate_lines:+\n}${rate_lines}"
fi

if [ -n "$usage_data" ] && [ "$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')" = "true" ]; then
    extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
    extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}$(printf '%-12s' "extra")${reset} ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
