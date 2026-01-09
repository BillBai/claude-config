#!/bin/bash

# ANSI Color codes (dimmed for status line)
RESET='\033[0m'
CYAN='\033[36m'
BLUE='\033[34m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
GRAY='\033[90m'

# Read JSON input from stdin
input=$(cat)

# Get current directory from JSON input
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# Format directory (replace home with ~)
dir=$(echo "$cwd" | sed "s|^$HOME|~|")

# Get git branch if in a git repo
# Use --no-optional-locks to avoid lock contention
git_branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        # Check if repo is dirty
        if git -C "$cwd" --no-optional-locks diff-index --quiet HEAD -- 2>/dev/null; then
            git_branch=" ${GREEN}(${branch})${RESET}"
        else
            git_branch=" ${YELLOW}(${branch}*)${RESET}"
        fi
    fi
fi

# Get model information
model_name=$(echo "$input" | jq -r '.model.display_name')
model_id=$(echo "$input" | jq -r '.model.id')

# Get output style information
output_style=$(echo "$input" | jq -r '.output_style.name // "default"')

# Color output style based on its name
case "$output_style" in
    "Explanatory"|"explanatory")
        style_display="${YELLOW}explanatory${RESET}"
        ;;
    "Learning"|"learning")
        style_display="${GREEN}learning${RESET}"
        ;;
    "Concise"|"concise")
        style_display="${CYAN}concise${RESET}"
        ;;
    "default")
        style_display="${GRAY}default${RESET}"
        ;;
    *)
        style_display="${GRAY}${output_style}${RESET}"
        ;;
esac

# Get context window information
context_info=$(echo "$input" | jq '.context_window')
total_input=$(echo "$context_info" | jq -r '.total_input_tokens')
total_output=$(echo "$context_info" | jq -r '.total_output_tokens')
window_size=$(echo "$context_info" | jq -r '.context_window_size')
current_usage=$(echo "$context_info" | jq '.current_usage')

# Calculate context usage percentage and cost
context_display=""
cost_display=""
if [ "$current_usage" != "null" ]; then
    input_tokens=$(echo "$current_usage" | jq -r '.input_tokens')
    cache_creation=$(echo "$current_usage" | jq -r '.cache_creation_input_tokens')
    cache_read=$(echo "$current_usage" | jq -r '.cache_read_input_tokens')
    output_tokens=$(echo "$current_usage" | jq -r '.output_tokens')

    # Current context usage (input + cache tokens)
    current_used=$((input_tokens + cache_creation + cache_read))
    usage_pct=$((current_used * 100 / window_size))

    # Color code based on percentage
    if [ $usage_pct -lt 50 ]; then
        pct_color="${GREEN}"
        bar="━━━━━━━━━━"
    elif [ $usage_pct -lt 80 ]; then
        pct_color="${YELLOW}"
        bar="━━━━━━━━━━"
    else
        pct_color="${RED}"
        bar="━━━━━━━━━━"
    fi

    # Create progress bar
    filled=$((usage_pct / 10))
    if [ $filled -gt 10 ]; then filled=10; fi
    empty=$((10 - filled))
    progress_bar="${bar:0:$filled}"
    if [ $empty -gt 0 ]; then
        progress_bar="${progress_bar}${GRAY}${bar:0:$empty}${RESET}"
    fi

    context_display="${pct_color}${progress_bar} ${usage_pct}%${RESET}"
fi

# Calculate session cost
if [ "$total_input" != "null" ] && [ "$total_output" != "null" ]; then
    # Pricing per 1M tokens (as of Jan 2025)
    # Claude Sonnet 4.5: $3.00 input, $15.00 output per 1M tokens
    # Claude Opus 4.5: $15.00 input, $75.00 output per 1M tokens

    case "$model_id" in
        *"opus-4"*)
            input_price=15
            output_price=75
            ;;
        *"sonnet-4"*)
            input_price=3
            output_price=15
            ;;
        *"opus"*)
            input_price=15
            output_price=75
            ;;
        *"sonnet"*)
            input_price=3
            output_price=15
            ;;
        *"haiku"*)
            input_price=0.25
            output_price=1.25
            ;;
        *)
            # Default to Sonnet pricing
            input_price=3
            output_price=15
            ;;
    esac

    # Calculate cost in cents to avoid floating point
    # Cost = (tokens / 1,000,000) * price_per_million
    # = (tokens * price) / 1,000,000
    input_cost_cents=$((total_input * input_price * 100 / 1000000))
    output_cost_cents=$((total_output * output_price * 100 / 1000000))
    total_cost_cents=$((input_cost_cents + output_cost_cents))

    # Format as dollars
    dollars=$((total_cost_cents / 100))
    cents=$((total_cost_cents % 100))

    if [ $total_cost_cents -lt 10 ]; then
        cost_display="${GRAY}\$0.0${total_cost_cents}${RESET}"
    elif [ $total_cost_cents -lt 100 ]; then
        cost_display="${GRAY}\$0.${cents}${RESET}"
    else
        cost_display="${CYAN}\$${dollars}.$(printf "%02d" $cents)${RESET}"
    fi
fi

# Session timer (Claude API resets usage limits every 24 hours from session start)
# For simplicity, we'll show time since session start
# Note: We can't get exact session start time from JSON, so we'll use transcript modification time
session_id=$(echo "$input" | jq -r '.session_id')
transcript_path=$(echo "$input" | jq -r '.transcript_path')

timer_display=""
if [ -f "$transcript_path" ]; then
    # Get file creation/modification time
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        file_time=$(stat -f %B "$transcript_path" 2>/dev/null)
    else
        # Linux
        file_time=$(stat -c %Y "$transcript_path" 2>/dev/null)
    fi

    if [ -n "$file_time" ]; then
        current_time=$(date +%s)
        elapsed=$((current_time - file_time))

        # Calculate time until reset (24h = 86400s)
        time_to_reset=$((86400 - (elapsed % 86400)))

        hours=$((time_to_reset / 3600))
        minutes=$(((time_to_reset % 3600) / 60))

        timer_display="${GRAY}↻ ${hours}h${minutes}m${RESET}"
    fi
fi

# Build the status line with colors
directory="${BLUE}${dir}${RESET}"
model="${MAGENTA}${model_name}${RESET}"

# Construct final output (start with directory, no user@host)
output="${directory}${git_branch}"

if [ -n "$model" ]; then
    output="${output} ${GRAY}|${RESET} ${model}"
fi

if [ -n "$style_display" ]; then
    output="${output} ${GRAY}|${RESET} ${style_display}"
fi

if [ -n "$context_display" ]; then
    output="${output} ${GRAY}|${RESET} ${context_display}"
fi

if [ -n "$cost_display" ]; then
    output="${output} ${GRAY}|${RESET} ${cost_display}"
fi

if [ -n "$timer_display" ]; then
    output="${output} ${GRAY}|${RESET} ${timer_display}"
fi

# Use printf to handle ANSI escape sequences
printf "%b\n" "$output"
