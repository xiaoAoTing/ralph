# Ralph

Ralph 是一个自主 AI 编程代理循环工具。它读取 `prd.json` 中的用户故事，通过 AI 编码工具（QoderCLI、Claude Code、Amp 等）逐个实现，自动运行质量检查、提交代码、更新进度，直到所有故事完成或达到最大迭代次数。

启发自 [snarktank/ralph](https://github.com/snarktank/ralph)。

## 前置要求

- **jq** — 用于解析 `prd.json`（`brew install jq`）
- **AI 工具**（任选其一）：
  - [QoderCLI](https://docs.qoder.com)（默认）
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  - [Amp](https://amp.dev)
  - 或其他支持 stdin 输入的自定义命令行工具

## 安装

将 Ralph 放入你项目的 `scripts/` 目录下：

```bash
cd your-project
mkdir -p scripts && cd scripts
git clone https://github.com/mccullough/ralph.git .
rm -rf .git
chmod +x ralph.sh
```

> 删除 `.git` 是为了避免嵌套 Git 仓库，Ralph 会在你项目的主仓库中工作。

## 使用

### 基本用法

```bash
./ralph.sh                  # 使用 QoderCLI，默认 10 次迭代
./ralph.sh 20               # 指定最大迭代次数
```

### 指定 AI 工具

```bash
./ralph.sh --tool qoder     # QoderCLI（默认）
./ralph.sh --tool claude    # Claude Code
./ralph.sh --tool amp       # Amp
./ralph.sh --tool custom --cmd "aider --yes-always" 5   # 自定义工具
```

### 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--tool TOOL` | AI 工具：`qoder`、`claude`、`amp`、`custom` | `qoder` |
| `--cmd COMMAND` | `--tool=custom` 时使用的自定义命令 | — |
| `max_iterations` | 最大循环次数 | `10` |

## 项目结构

Ralph 运行时依赖以下文件（均位于 `scripts/` 目录下）：

```
scripts/
├── ralph.sh        # 主脚本
├── prompt.md       # Agent 指令（每轮迭代的 prompt）
├── prd.json        # 产品需求文档（用户故事列表）
├── progress.txt    # 进度日志（自动生成，追加写入）
├── .last-branch    # 分支追踪文件（自动生成）
└── archive/        # 历史归档目录（自动生成）
```

### prd.json 格式

`prd.json` 是 Ralph 的任务来源，包含一个分支名和一组用户故事：

```json
{
  "branchName": "ralph/my-feature",
  "userStories": [
    {
      "id": "US-001",
      "title": "用户登录功能",
      "priority": 1,
      "passes": false
    },
    {
      "id": "US-002",
      "title": "用户注册功能",
      "priority": 2,
      "passes": false
    }
  ]
}
```

- `branchName` — Agent 工作的 Git 分支，不存在时会自动从 main 创建
- `userStories` — 用户故事数组，按 `priority` 升序执行
- `passes` — `false` 表示未完成，Agent 完成并验证后会设为 `true`

> 你可以使用 QoderCLI 的 `/prd` 技能生成 PRD，再用 `/ralph` 技能转换为 `prd.json` 格式。

### prompt.md

`prompt.md` 定义了 Agent 在每轮迭代中的行为指令，包括：读取 PRD → 选取最高优先级未完成故事 → 实现 → 质量检查 → 提交 → 更新进度。

如果不存在 `prompt.md`，脚本会回退使用 `CLAUDE.md`。

## 工作流程

每轮迭代的执行流程：

1. Agent 读取 `prd.json` 和 `progress.txt`
2. 切换到 PRD 指定的 Git 分支
3. 选取 `passes: false` 中优先级最高的用户故事
4. 实现该故事并运行质量检查（typecheck / lint / test）
5. 提交代码，commit message 格式：`feat: [Story ID] - [Story Title]`
6. 将 `prd.json` 中该故事的 `passes` 更新为 `true`
7. 追加进度记录到 `progress.txt`（含学习总结和可复用模式）
8. 如果所有故事完成，输出 `<promise>COMPLETE</promise>` 终止循环

### 归档机制

当 `prd.json` 中的 `branchName` 发生变化时（意味着切换到新任务），上一轮的 `prd.json` 和 `progress.txt` 会自动归档到 `archive/<日期>-<分支名>/` 目录下，并重置进度日志。

## 许可证

MIT