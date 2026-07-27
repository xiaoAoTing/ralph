#!/bin/bash
# Qoder/Ralph Long-running AI Agent Loop
# Usage: ./qoder-loop.sh [--tool qoder|claude|amp|custom] [--cmd "custom command"] [max_iterations]

set -eo pipefail

# 默认配置
TOOL="qoder"          # 默认使用 qodercli
MAX_ITERATIONS=10
CUSTOM_CMD=""
TIMEOUT_SECS=900      # 单次迭代超时（秒），默认 15 分钟

# 帮助信息
show_help() {
  echo "Usage: $0 [OPTIONS] [max_iterations]"
  echo ""
  echo "Options:"
  echo "  --tool TOOL         指定 AI 工具 (qoder|claude|amp|custom)，默认: qoder"
  echo "  --cmd COMMAND       当 --tool=custom 时使用的自定义命令"
  echo "  --timeout SECS      单次迭代超时秒数，默认: 900 (15分钟)"
  echo "  -h, --help          显示帮助信息"
  echo ""
  echo "Examples:"
  echo "  $0 --tool qoder 15"
  echo "  $0 --tool claude"
  echo "  $0 --tool custom --cmd \"aider --yes-always\" 5"
  exit 0
}

# 参数解析
while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --cmd)
      CUSTOM_CMD="$2"
      shift 2
      ;;
    --cmd=*)
      CUSTOM_CMD="${1#*=}"
      shift
      ;;
    --timeout)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT_SECS="${1#*=}"
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

# 归档逻辑 (保持原有分支切换自动归档)
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||; s|^qoder/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    echo "# Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# 追踪当前分支
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# 初始化进度日志
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# 动态 Prompt 选择逻辑
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
if [ ! -f "$PROMPT_FILE" ] && [ -f "$SCRIPT_DIR/CLAUDE.md" ]; then
  PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
fi

# 核心：AI 工具执行路由适配器
run_ai_tool() {
  local tool_type="$1"
  local prompt_path="$2"

  cd "$SCRIPT_DIR"

  case "$tool_type" in
    qoder|qodercli)
      # qodercli 模式：非交互 + 流式 JSON 输出 + 跳过权限确认
      qodercli -p --output-format stream-json --dangerously-skip-permissions "$(cat "$prompt_path")" 2>&1
      ;;
    claude)
      # Claude Code 模式
      claude --dangerously-skip-permissions --print < "$prompt_path" 2>&1
      ;;
    amp)
      # Amp 模式
      cat "$prompt_path" | amp --dangerously-allow-all 2>&1
      ;;
    custom)
      if [ -z "$CUSTOM_CMD" ]; then
        echo "Error: --tool=custom requires --cmd parameter." >&2
        return 1
      fi
      # 自定义命令模式
      cat "$prompt_path" | eval "$CUSTOM_CMD" 2>&1
      ;;
    *)
      echo "Error: Unsupported tool '$tool_type'." >&2
      return 1
      ;;
  esac
}

# 前置校验
if ! command -v jq &>/dev/null; then
  echo "Error: 'jq' is required but not installed. Install it via: brew install jq" >&2
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: Prompt file not found: $PROMPT_FILE" >&2
  echo "Create a prompt.md (or CLAUDE.md) in $SCRIPT_DIR" >&2
  exit 1
fi

echo "Starting Agent Loop - Tool: $TOOL - Max iterations: $MAX_ITERATIONS - Timeout: ${TIMEOUT_SECS}s/iteration"

# 格式化耗时
format_duration() {
  local secs=$1
  if [ "$secs" -ge 60 ]; then
    printf "%dm%02ds" $((secs / 60)) $((secs % 60))
  else
    printf "%ds" "$secs"
  fi
}

# 解析 stream-json 输出为可读进度
parse_stream() {
  local tool_count=0
  while IFS= read -r line; do
    local type
    type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue

    case "$type" in
      assistant)
        local tools
        tools=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name' 2>/dev/null)
        for tool in $tools; do
          tool_count=$((tool_count + 1))
          echo "  [$tool_count] Tool: $tool"
        done
        local text
        text=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null | head -c 120)
        if [ -n "$text" ]; then
          echo "  >> ${text}..."
        fi
        ;;
      result)
        local subtype
        subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
        echo "  [result] $subtype"
        ;;
    esac
  done
}

# macOS 兼容的超时控制 + 实时输出
# 使用临时文件 + 后台进程组 kill，避免 $() 缓冲导致无输出
TMP_OUTPUT=$(mktemp)
trap "rm -f $TMP_OUTPUT" EXIT

run_iteration() {
  local timeout_secs=$1
  local tool_type=$2
  local prompt_path=$3

  # 启动 AI 工具：原始 JSON 写入临时文件，同时通过解析器实时显示进度
  run_ai_tool "$tool_type" "$prompt_path" 2>&1 | tee "$TMP_OUTPUT" | parse_stream &
  local cmd_pid=$!

  # 后台心跳：每 30 秒打印一个点，让用户知道还活着
  (
    local elapsed=0
    while [ "$elapsed" -lt "$timeout_secs" ]; do
      sleep 30
      elapsed=$((elapsed + 30))
      echo "  [heartbeat] running... $(format_duration $elapsed)"
    done
  ) &
  local heartbeat_pid=$!

  # 后台超时计时器
  ( sleep "$timeout_secs" && kill -- -$$ 2>/dev/null ) &
  local timer_pid=$!

  # 等待 AI 工具完成
  wait "$cmd_pid" 2>/dev/null
  local exit_code=$?

  # 清理后台进程
  kill "$timer_pid" "$heartbeat_pid" 2>/dev/null
  wait "$timer_pid" "$heartbeat_pid" 2>/dev/null

  if [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 143 ]; then
    return 124
  fi
  return $exit_code
}

LOOP_START=$(date +%s)
FAILED_ITERATIONS=0

for i in $(seq 1 $MAX_ITERATIONS); do
  ITER_START=$(date +%s)
  ELAPSED_TOTAL=$(( ITER_START - LOOP_START ))

  echo ""
  echo "==============================================================="
  echo "   Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "   Started: $(date '+%H:%M:%S') | Total elapsed: $(format_duration $ELAPSED_TOTAL)"
  echo "==============================================================="

  # 清空临时文件并执行
  > "$TMP_OUTPUT"
  TIMEOUT_EXIT=0
  run_iteration "$TIMEOUT_SECS" "$TOOL" "$PROMPT_FILE" || TIMEOUT_EXIT=$?

  ITER_END=$(date +%s)
  ITER_DURATION=$(( ITER_END - ITER_START ))

  # 超时检测
  if [ "$TIMEOUT_EXIT" -eq 124 ]; then
    echo ""
    echo "!!! Iteration $i TIMED OUT after $(format_duration $TIMEOUT_SECS)"
    echo "!!! Increase timeout with: --timeout <seconds>"
    FAILED_ITERATIONS=$((FAILED_ITERATIONS + 1))
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Iteration $i TIMEOUT after $(format_duration $TIMEOUT_SECS)" >> "$PROGRESS_FILE"
    continue
  fi

  # 其他错误检测
  if [ "$TIMEOUT_EXIT" -ne 0 ]; then
    echo ""
    echo "!!! Iteration $i FAILED (exit code: $TIMEOUT_EXIT) after $(format_duration $ITER_DURATION)"
    FAILED_ITERATIONS=$((FAILED_ITERATIONS + 1))
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Iteration $i FAILED (exit: $TIMEOUT_EXIT)" >> "$PROGRESS_FILE"
    continue
  fi

  # 检查任务完成标志（从临时文件读取）
  if grep -q "<promise>COMPLETE</promise>" "$TMP_OUTPUT"; then
    TOTAL_END=$(date +%s)
    TOTAL_DURATION=$(( TOTAL_END - LOOP_START ))
    echo ""
    echo "Agent completed all tasks successfully!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    echo "Total time: $(format_duration $TOTAL_DURATION) | Failed iterations: $FAILED_ITERATIONS"
    exit 0
  fi

  echo "Iteration $i complete in $(format_duration $ITER_DURATION). Continuing..."
  sleep 2
done

TOTAL_END=$(date +%s)
TOTAL_DURATION=$(( TOTAL_END - LOOP_START ))
echo ""
echo "Reached max iterations ($MAX_ITERATIONS) without complete signal."
echo "Total time: $(format_duration $TOTAL_DURATION) | Failed iterations: $FAILED_ITERATIONS"
echo "Check $PROGRESS_FILE for current status."
exit 1