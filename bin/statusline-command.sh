#!/bin/bash

# Statusline command for Claude Code
# Optimized for performance: minimizes subprocess spawns

#=============================================================================
# Constants
#=============================================================================
readonly CONTEXT_WARN_PCT=50
readonly CONTEXT_CRIT_PCT=80
readonly COST_CHEAP=0.10
readonly COST_MODERATE=0.50
readonly COST_EXPENSIVE=1.00
readonly COST_VERY_EXPENSIVE=5.00
readonly DEFAULT_TERM_WIDTH=120
readonly EMOJI_WIDTH_BUFFER=10  # Extra buffer for emoji display width

#=============================================================================
# ANSI color codes
#=============================================================================
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
MAGENTA="\033[35m"
YELLOW="\033[33m"
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
WHITE="\033[37m"

#=============================================================================
# Read JSON input from stdin (avoid cat subprocess)
#=============================================================================
input=""
while IFS= read -r line || [[ -n "$line" ]]; do
    input+="$line"
done

#=============================================================================
# Check dependencies
#=============================================================================
if ! command -v jq &> /dev/null; then
    printf "jq not installed"
    exit 0
fi

#=============================================================================
# Extract values from JSON (single jq call)
#=============================================================================
vals=()
while IFS= read -r line; do
    vals+=("$line")
done < <(
    jq -r '
        (.workspace.current_dir // ""),
        ((.model.display_name // "Claude") | gsub(" "; "-")),
        (.output_style.name // "default"),
        (.vim.mode // ""),
        (.cost.total_cost_usd // 0),
        (.cost.total_lines_added // 0),
        (.cost.total_lines_removed // 0),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        (.context_window.current_usage.output_tokens // 0),
        (.context_window.context_window_size // 0),
        (.turn_count // 0),
        (.session_start_time // .session.start_time // .start_time // "")
    ' <<< "$input" 2>/dev/null
)

# Validate jq output (error handling)
if [[ ${#vals[@]} -lt 12 ]]; then
    printf "📁 ~ | Claude | (invalid data)"
    exit 0
fi

current_dir="${vals[0]}"
model_name="${vals[1]}"
output_style="${vals[2]}"
vim_mode="${vals[3]}"
cost_usd="${vals[4]}"
lines_added="${vals[5]%%.*}"      # Truncate decimals for bash arithmetic
lines_removed="${vals[6]%%.*}"
input_tokens="${vals[7]%%.*}"
cache_creation="${vals[8]%%.*}"
cache_read="${vals[9]%%.*}"
output_tokens="${vals[10]%%.*}"
context_size="${vals[11]%%.*}"
turn_count="${vals[12]%%.*}"
session_start="${vals[13]}"

#=============================================================================
# Directory name
#=============================================================================
if [[ -n "$current_dir" ]]; then
    dir_name="${current_dir##*/}"
    [[ -z "$dir_name" ]] && dir_name="/"
else
    dir_name="~"
fi

#=============================================================================
# Git branch and status
#=============================================================================
git_info=""
if [[ -n "$current_dir" && -d "$current_dir" ]]; then
    if git -C "$current_dir" rev-parse --git-dir &>/dev/null; then
        branch=$(git -C "$current_dir" --no-optional-locks branch --show-current 2>/dev/null)
        # Handle detached HEAD state
        if [[ -z "$branch" ]]; then
            branch=$(git -C "$current_dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
            [[ -n "$branch" ]] && branch=":${branch}"
        fi
        if [[ -n "$branch" ]]; then
            if ! git -C "$current_dir" --no-optional-locks diff --quiet 2>/dev/null || \
               ! git -C "$current_dir" --no-optional-locks diff --cached --quiet 2>/dev/null; then
                git_status="${YELLOW}*${RESET}"
            else
                git_status=""
            fi
            git_info=" ${DIM}[${RESET}${MAGENTA}${branch}${RESET}${git_status}${DIM}]${RESET}"
        fi
    fi
fi

#=============================================================================
# Consolidated awk call for all numeric calculations
# Computes: used_k, total_k, pct, cache_pct, context_level, tpt, cost_level
#=============================================================================
read -r used_k total_k pct cache_pct context_level tpt cost_level < <(
    awk -v i="${input_tokens:-0}" -v cc="${cache_creation:-0}" \
        -v cr="${cache_read:-0}" -v o="${output_tokens:-0}" \
        -v s="${context_size:-0}" -v turns="${turn_count:-0}" \
        -v cost="${cost_usd:-0}" \
        -v warn="$CONTEXT_WARN_PCT" -v crit="$CONTEXT_CRIT_PCT" \
        -v c_cheap="$COST_CHEAP" -v c_mod="$COST_MODERATE" \
        -v c_exp="$COST_EXPENSIVE" -v c_vexp="$COST_VERY_EXPENSIVE" \
    'BEGIN {
        # Context calculations
        used = i + cc + cr + o
        pct = (s > 0) ? (used * 100 / s) : 0
        total_input = i + cc + cr
        cache_pct = (total_input > 0) ? int(cr * 100 / total_input) : 0

        # Format K notation with appropriate precision
        used_k = used / 1000
        total_k = s / 1000
        if (used_k >= 100) used_str = sprintf("%.0fK", used_k)
        else if (used_k >= 10) used_str = sprintf("%.0fK", used_k)
        else used_str = sprintf("%.1fK", used_k)

        if (total_k >= 100) total_str = sprintf("%.0fK", total_k)
        else total_str = sprintf("%.0fK", total_k)

        # Context level (0=green, 1=yellow, 2=red)
        context_level = (pct < warn) ? 0 : (pct < crit) ? 1 : 2

        # Tokens per turn
        tpt = (turns > 0) ? sprintf("%.1f", used / turns / 1000) : "0"

        # Cost level (-1=hide, 0-4=moods)
        if (cost <= 0.001) cost_level = -1
        else if (cost < c_cheap) cost_level = 0
        else if (cost < c_mod) cost_level = 1
        else if (cost < c_exp) cost_level = 2
        else if (cost < c_vexp) cost_level = 3
        else cost_level = 4

        printf "%s %s %.1f %d %d %s %d", used_str, total_str, pct, cache_pct, context_level, tpt, cost_level
    }'
)

#=============================================================================
# Build context info string
#=============================================================================
context_info=""
cache_info=""
if [[ -n "$context_size" && "$context_size" != "0" ]]; then
    case "$context_level" in
        0) context_emoji=""; context_color="$GREEN" ;;
        1) context_emoji="⚠️ "; context_color="$YELLOW" ;;
        *) context_emoji="🔴 "; context_color="$RED" ;;
    esac
    context_info="${context_emoji}${context_color}${used_k}/${total_k}(${pct}%)${RESET}"

    # Cache efficiency indicator (numeric comparison, not string)
    if (( cache_pct > 0 )); then
        cache_info="💾 ${CYAN}${cache_pct}%${RESET}"
    fi
fi

#=============================================================================
# Tokens per turn
#=============================================================================
tokens_per_turn=""
if [[ -n "$turn_count" && "$turn_count" != "0" && "$tpt" != "0" ]]; then
    tokens_per_turn="${DIM}tok/turn:${RESET}${WHITE}${tpt}K${RESET}"
fi

#=============================================================================
# Session duration
#=============================================================================
session_duration=""
if [[ -n "$session_start" && "$session_start" != "" ]]; then
    start_epoch=$(date -d "$session_start" +%s 2>/dev/null)
    if [[ -z "$start_epoch" ]]; then
        # macOS: strip timezone and fractional seconds
        clean_ts="${session_start%%Z*}"
        clean_ts="${clean_ts%%+*}"
        clean_ts="${clean_ts%%.*}"
        start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" +%s 2>/dev/null)
    fi
    if [[ -n "$start_epoch" && "$start_epoch" =~ ^[0-9]+$ ]]; then
        now_epoch=$(date +%s)
        duration=$((now_epoch - start_epoch))
        if (( duration > 0 )); then
            if (( duration >= 3600 )); then
                hours=$((duration / 3600))
                mins=$(( (duration % 3600) / 60 ))
                session_duration="${DIM}session:${RESET}${WHITE}${hours}h${mins}m${RESET}"
            elif (( duration >= 60 )); then
                mins=$((duration / 60))
                session_duration="${DIM}session:${RESET}${WHITE}${mins}m${RESET}"
            else
                session_duration="${DIM}session:${RESET}${WHITE}${duration}s${RESET}"
            fi
        fi
    fi
fi

#=============================================================================
# Vim mode indicator
#=============================================================================
vim_indicator=""
case "$vim_mode" in
    INSERT) vim_indicator=" ${DIM}[${RESET}${GREEN}✎ INS${RESET}${DIM}]${RESET}" ;;
    NORMAL) vim_indicator=" ${DIM}[${RESET}${BLUE}◆ NOR${RESET}${DIM}]${RESET}" ;;
    VISUAL) vim_indicator=" ${DIM}[${RESET}${MAGENTA}▊ VIS${RESET}${DIM}]${RESET}" ;;
esac

#=============================================================================
# Cost with mood indicator
#=============================================================================
cost_info=""
if (( cost_level >= 0 )); then
    case "$cost_level" in
        0) mood="😊" ;;
        1) mood="😐" ;;
        2) mood="😅" ;;
        3) mood="😰" ;;
        *) mood="🔥" ;;
    esac
    cost_info="${mood} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi

#=============================================================================
# Lines changed
#=============================================================================
lines_info=""
if (( ${lines_added:-0} > 0 || ${lines_removed:-0} > 0 )); then
    lines_info="${GREEN}+${lines_added:-0}${RESET}${DIM}/${RESET}${RED}-${lines_removed:-0}${RESET}"
fi

#=============================================================================
# Model color
#=============================================================================
case "$model_name" in
    *[Oo]pus*)   model_color="$MAGENTA" ;;
    *[Ss]onnet*) model_color="$BLUE" ;;
    *[Hh]aiku*)  model_color="$GREEN" ;;
    *)           model_color="$WHITE" ;;
esac

#=============================================================================
# Terminal width detection
#=============================================================================
term_width=${COLUMNS:-0}
if (( term_width == 0 )); then
    term_width=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
fi
if [[ -z "$term_width" || "$term_width" == "0" ]]; then
    term_width=$(tput cols 2>/dev/null </dev/tty || echo 0)
fi
if (( term_width == 0 )); then
    term_width=$DEFAULT_TERM_WIDTH
fi

#=============================================================================
# Build output sections
#=============================================================================
SEP=" ${DIM}|${RESET} "

# Primary section
primary="📁 ${CYAN}${BOLD}${dir_name}${RESET}${git_info}${vim_indicator}"
primary+="${SEP}${BOLD}${model_color}${model_name}${RESET}"
[[ -n "$context_info" ]] && primary+="${SEP}${context_info}"

# Secondary section
secondary=""
sep=""
[[ -n "$cache_info" ]] && secondary+="${cache_info}" && sep="$SEP"
[[ -n "$tokens_per_turn" ]] && secondary+="${sep}${tokens_per_turn}" && sep="$SEP"
[[ -n "$session_duration" ]] && secondary+="${sep}${session_duration}" && sep="$SEP"
secondary+="${sep}${DIM}${output_style}${RESET}" && sep="$SEP"
[[ -n "$lines_info" ]] && secondary+="${sep}${lines_info}" && sep="$SEP"
[[ -n "$cost_info" ]] && secondary+="${sep}${cost_info}"

#=============================================================================
# Calculate visible length and output
# Use buffer to account for emoji width (emojis are 2 cols, counted as 1 char)
#=============================================================================
primary_expanded=$(printf "%b" "$primary")
secondary_expanded=$(printf "%b" "$secondary")
primary_text=$(printf "%s" "$primary_expanded" | sed 's/\x1b\[[0-9;]*m//g')
secondary_text=$(printf "%s" "$secondary_expanded" | sed 's/\x1b\[[0-9;]*m//g')
est_len=$(( ${#primary_text} + 3 + ${#secondary_text} + EMOJI_WIDTH_BUFFER ))

# Output: one line if fits, two lines otherwise
if (( est_len <= term_width )); then
    printf "%b" "${primary}${SEP}${secondary}"
else
    printf "%b" "${primary}\n   ${secondary}"
fi
