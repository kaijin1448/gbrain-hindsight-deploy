# AI 代理部署手册（给 opencode 等 AI 执行）

> **读者 = 目标机上的 AI 代理。** 本仓库可一键部署；你作为代理，优先运行 `deploy.ps1`，遇到人工交互时停下来问用户，再按本手册处理异常。
> 最终目标：本机（Windows）跑通 ①会话自动抽取 ②语义检索+本地重排 ③takes 学习。

---

## 首选路径：直接跑部署器

```powershell
# 在仓库目录内：
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
# 或远程：
irm https://raw.githubusercontent.com/kaijin1448/gbrain-hindsight-deploy/main/install.ps1 | iex
```

非交互参数（先向用户问清再执行）：

```powershell
.\deploy.ps1 -GatewayUrl <base_url> -GatewayModel <模型名> [-LlamaSource <文件夹或zip>] [-EmbedPort 18080] [-RerankPort 18081]
# Key 让用户在弹出的安全提示里输入（不落命令行历史）；或程序内 SecureString 输入
```

跑完后用 `verify.ps1` 验收；失败项按下面「故障速查」处理。

## 开始前：先向用户确认 3 件事（一次问清）

1. **chat/expansion 端点（网关）**：OpenAI 兼容 base_url（含 `/v1`）与 Key；模型名（默认 `deepseek-flash`，按实际网关填）。
2. **`~\.llama` 来源**：是否有从源机器拷来的 `C:\Users\<用户名>\.llama` 文件夹（约 1.3GB，含 `bin\` 与 `models\`）？在哪个路径？（没有则由部署器下载）
3. 本机是否已装 **bun** 与 **opencode**（opencode 就是"你所在的程序"）。

## 铁律（违反 = 返工）

- 本机为 **PowerShell 5.1**：调用脚本一律 `powershell -NoProfile -ExecutionPolicy Bypass -File "xxx.ps1"`；读取文本文件用显式 UTF-8；**不要**用 bash coreutils（无）。
- 改任何已有配置文件（`opencode.jsonc`、`config.json`）前**先备份**（同样逻辑已内置在 deploy.ps1 与 merge-mcp.mjs 中）。
- 本地服务地址一律 `127.0.0.1`（**绝不用 localhost**，防 IPv6/同端口监听歧义）。
- 部署前查端口占用：`netstat -ano | findstr :18080`、`findstr :18081`；若被占 → 停下问用户是否换端口（若换：`-EmbedPort/-RerankPort` 会同步改启动脚本、config.json、opencode env 三处）。
- Key 只写入配置文件，**不要**在对话里回显、不要写进其它文档。
- 见到 `database is already open through gbrain serve` = opencode 的 serve 正在运行（**正常保护**）；需要写库或改配置时，提示用户"完全退出 opencode 后我再操作"，**不要**强杀任何进程。
- 不改 gbrain 源码；一切基于 CLI、配置文件与脚本（都在本仓库里）。

## 手工路径（deploy.ps1 不可用时）

### Step 0 · 环境体检（全只读，产出一份结论）

```powershell
[System.Environment]::OSVersion.VersionString          # Windows 版本
$PSVersionTable.PSVersion                               # 应为 5.1
bun --version                                           # 没有则报错，记 "缺 bun"
gbrain --version                                        # 没有则记 "缺 gbrain"
netstat -ano | findstr :18080                           # 期望无输出（未被占）
netstat -ano | findstr :18081                           # 期望无输出
Test-Path "$env:USERPROFILE\.llama"                     # 是否已有 llama 目录
Test-Path "$env:USERPROFILE\.gbrain"                    # 是否已有大脑数据（有=沿用还是新建要问用户）
```

### Step 1 · 安装 bun + gbrain（缺什么装什么）

- bun：`irm bun.sh/install.ps1 | iex`（或 `winget install Oven-sh.Bun`；网络受限问用户要离线包）。
- `bun install -g gbrain`；验证 `gbrain --version` ≥ 0.52.1。

### Step 2 · 初始化大脑

- `~\.gbrain` 不存在 → `gbrain init`（默认 PGLite）。
- 已存在 → 问用户"沿用 / 备份后重建"（备份 = 复制 `~\.gbrain` 到 `~\.gbrain.bak-日期`）。
- 验证：`gbrain stats` 正常输出。

### Step 3 · 部署本地 llama 服务（嵌入 + 重排）

- **情形 A（有 `.llama` 拷贝）**：整份复制到 `%USERPROFILE%\.llama`；再把本仓 `llama-scripts\start-embed.ps1`、`start-rerank.ps1` 覆盖进去。
- **情形 B（没有拷贝）**：
  - llama.cpp（b11136）：`https://github.com/ggml-org/llama.cpp/releases/download/b11136/llama-b11136-bin-win-cpu-x64.zip` → 解压到 `~\.llama\bin`；
  - `bge-m3-Q8_0.gguf`：`https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf` → `~\.llama\models\`
  - `qwen3-reranker-0.6b-q8_0.gguf`：`https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/main/qwen3-reranker-0.6b-q8_0.gguf` → `~\.llama\models\`
  - 把本仓 `llama-scripts\` 两个脚本复制到 `~\.llama\`。

**启动（幂等）**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.llama\start-embed.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.llama\start-rerank.ps1"
```

**探针（两个都必须 200；首次加载模型可能 30–60s，失败可重试）**：

```powershell
Invoke-WebRequest -Uri 'http://127.0.0.1:18080/v1/embeddings' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"probe","model":"bge-m3"}')) -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15
Invoke-WebRequest -Uri 'http://127.0.0.1:18081/v1/rerank' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"q","documents":["a"],"model":"qwen3-reranker-06b"}')) -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15
```

> 404 多半是端口被别的程序占了（探针打到了别的应用）→ 回到"铁律"的端口处理。

### Step 4 · 配置 gbrain

1. 备份 `~\.gbrain\config.json`（如存在）。
2. 按 `templates\gbrain-config.template.json` 合并进 `config.json`：替换用户名、网关 base_url 与 Key、端口；**已存在的键不要覆盖**。
3. 验证（serve 未运行）：`gbrain providers test` → 期望 "All probes green."；若报 locked → 记为"退出 opencode 后验证"。

### Step 5 · 部署脚本

把本仓 `scripts\` 全部文件复制到 `%USERPROFILE%\.config\opencode\memory\scripts\`（目录不存在则创建）。
**不要**改编码（.ps1 带 UTF-8 BOM、.cmd 纯 ASCII）。

### Step 6 · 接线 opencode

1. 定位 `~\.config\opencode\opencode.jsonc`（不存在则新建 `{}` 骨架）。先备份。
2. 首选：`tools\merge-mcp.mjs` 自动合并（保留注释、幂等）：

```powershell
# 先把模板里的 <你的用户名>/端口替换好，存为临时片段，然后：
node "$repo\tools\merge-mcp.mjs" --file "$env:USERPROFILE\.config\opencode\opencode.jsonc" --fragment <临时片段文件>
```

3. 或手工：把 `templates\opencode-mcp.fragment.jsonc` 的 `"gbrain"` 块合并进顶层 `"mcp"` 对象。
4. 强调：**重启 opencode 后生效**（完全关闭再打开）。

### Step 7 · 开机自启

复制 `startup-templates\` 的 `.vbs`（`llama-embed.vbs`、`llama-rerank.vbs`、`gbrain-capture.vbs`；可选 `brain-onclose.vbs`）到：
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`
不要自启则跳过，但告知"每次开机需手动跑两个 start 脚本 + `start-gbrain-capture.ps1`"。

### Step 8 · 首次初始化（关键，需要用户配合）

1. 让用户**完全退出 opencode**（先跟他说好后面要干什么）。
2. 任选其一：① 双击 `brain-maintenance.cmd`（有进度窗口）；② 关着 ≥5 分钟让 `brain-onclose` 守望自动跑（静默）。
3. 检查最新 `~\.config\opencode\memory\logs\brain-maintenance-*.log`，期望依次出现：
   `锁探测通过` → `llama-embed/rerank 就绪=True` → `config set … => exit=0` → `marker 已写` → `全量导出 => exit=0` → `dream[六相位]`。
   （`propose_takes` 首次 `exit=1` 可容忍，后续维护窗口会重跑。）
4. 用户重开 opencode。
5. 告知：首次回填（数千段语料）需**数小时~1 天**，完全自动。

### Step 9 · 验收

运行 `verify.ps1`（逐项对齐报告 §6 清单），把结果清单发用户：

- [ ] `gbrain --version` ≥ 0.52.1
- [ ] 两个探针 200
- [ ] `providers test` → All probes green（serve 未运行时）
- [ ] `~\.gbrain\transcripts\sweep-enabled.md` 存在
- [ ] `gbrain config get facts.default_visibility` → world
- [ ] `memory\logs\gbrain-capture.log` 持续出现 `pass done`
- [ ] `corpus\` 下 `.txt` 与 `.ingested` 计数在增长
- [ ] 对 gbrain 说"回忆一下 <主题>"能召回；搜中文词有结果
- [ ] `~\.llama\server-rerank.log` 出现真实批次任务
- [ ] dream 六相位日志（见 Step 8）

## 故障速查（优先查报告 §7/§8）

| 症状 | 处置 |
|---|---|
| 探针 404 | 同端口被占或 llama 挂了：netstat 找真凶；重启 llama；核对 127.0.0.1 |
| `database is already open` | serve 在跑（正常）；写库需关窗 |
| sweep 不推进 | 确认 opencode 已开（serve 活）+ marker 存在 |
| `touched=0` 连续 | 检查导出器进程是否在跑；必要时重启 `start-gbrain-capture.ps1` |
| 双实例同端口 LISTENING | 杀多余实例；确认用仓库内新脚本（端点探针+CIM 判进程） |
| config.json 被 DLP 加密损坏（`%TSD` 头） | `python scripts\fix-gbrain-config.py --fix`（信任 python） |

**任何未覆盖的报错**：保留原始报错，先读 `docs/deploy-report.md` §7 故障速查表与 §8 已知坑表；仍未覆盖的，把原始报错原样询问用户。
