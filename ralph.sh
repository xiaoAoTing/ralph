#!/bin/bash
# Qoder/Ralph Long-running AI Agent Loop
# Usage: ./qoder-loop.sh [--tool qoder|claude|amp|custom] [--cmd "custom command"] [max_iterations]

set -eo pipefail

# 默认配置
TOOL="qoder"          # 默认使用 qodercli
MAX_ITERATIONS=10
CUSTOM_CMD=""

# 帮助信息
show_help() {
  echo "Usage: $0 [OPTIONS] [max_iterations]"
  echo ""
  echo "Options:"
  echo "  --tool TOOL         指定 AI 工具 (qoder|claude|amp|custom)，默认: qoder"
  echo "  --cmd COMMAND       当 --tool=custom 时使用的自定义命令"
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
      # qodercli 模式：自动接受执行并批处理运行
      cat "$prompt_path" | qodercli --yolo 2>&1
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

echo "Starting Agent Loop - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "   Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # 执行映射函数并实时捕获输出
  OUTPUT=$(run_ai_tool "$TOOL" "$PROMPT_FILE" | tee /dev/stderr) || true
  
  # 检查任务完成标志
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "🎉 Agent completed all tasks successfully!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "⚠️ Reached max iterations ($MAX_ITERATIONS) without complete signal."
echo "Check $PROGRESS_FILE for current status."
exit 1