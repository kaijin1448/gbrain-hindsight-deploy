# GBrain「Hindsight 三件套」部署与适配报告（可分享版）

- **版本**：v1.2 · 2026-09-29（v1.2：重排迁至独立端口 18081；嵌入 18080——两个本地模型服务均与 80xx 段分家）
- **来源环境**：Windows 10 专业版 / 15.4GB 内存 / opencode 桌面版 / GBrain 0.52.1.0 / llama.cpp b11136
- **适用范围**：Windows 10/11 电脑，迁移部署「会话自动抽取 + 语义检索与重排 + takes 学习」三件套
- **安全说明**：本文与配套仓库**不含任何密钥**；网关地址/Key 请向管理员获取或替换为你自己的 OpenAI 兼容服务

---

## 0. 一页速览（TL;DR）

| 件 | 作用 | 部署物 |
|---|---|---|
| ① 会话自动抽取 | opencode 的对话**自动**变成可检索记忆（不用再"记得去记"） | 常驻导出器（bun，180s 循环） |
| ② 语义检索 + 重排 | 提问按"意思"找回记忆，再经本地模型重排提高命中质量 | 本地嵌入服务 + 本地重排服务 |
| ③ takes / 做梦 | 定期把事实蒸馏成"观察/结论"，纠偏不覆盖 | 维护脚本（dream 六相位） |

- **部署耗时**：约 1–2 小时（拷贝模型占大头）+ 一次 ≥5 分钟关窗初始化
- **磁盘占用**：约 1.5GB（两个模型 1.2GB + 大脑数据库数百 MB）
- **内存要求**：建议 ≥16GB（两个 llama 服务 + opencode 合计约 6–8GB；不足时降级策略见 §5.3）
- **全程无需管理员权限**（自启用 Startup 文件夹实现）
- **本仓库用法（一键）**：`git clone` 后运行 `deploy.ps1`（或 `irm .../install.ps1 | iex`）→ 自动完成全部部署；或把仓库交给目标机的 AI 代理，让它读 `docs/agent-deploy-guide.md` 执行

---

## 1. 总览与数据流

```
【写入链 · 自动】
opencode 会话消息
    │  gbrain-capture-export.ts（常驻，每 180s 一趟，限流 12 段/趟）
    ▼
~\.gbrain\transcripts\corpus\oc-*.txt     （≤7600 字符/段，内容寻址、幂等、脱敏）
    │  gbrain sweep（serve 存活时经 IPC 委托，每 ≥5min 一批，300s 预算）
    ▼
facts 库（default_visibility=world）+ 页面 → 跨会话可召回

【读取链 · 检索】
提问 ─▶ gbrain serve ─▶ 查询嵌入（bge-m3 @127.0.0.1:18080）
                          │
                          ▼
             混合检索：向量 + 关键词（RRF 融合）
                          │
                          ▼
             重排：Qwen3-Reranker @127.0.0.1:18081（fail-open）
                          │
                          ▼
                       结果

【学习链 · 维护窗口（须完全退出 opencode ≥5 分钟）】
brain-maintenance.ps1：
  锁探测 ─▶ llama 服务就绪（端点探针）─▶ 配置固化（world / reranker）
  ─▶ 写初始化 marker ─▶ 全量导出铺底 ─▶ dream 六相位：
     extract_facts → consolidate → propose_takes → grade_takes
     → calibration_profile → embed
```

**关键设计（为什么这么做）**：
1. **导出器必须"写门控"**：初始化 marker 写入前不写盘、不 sweep —— 防止初始批次 facts 落成 private 不可见。
2. **sweep 一律经 serve 委托**（IPC）：PGLite 单写者，绝不让独立进程与 serve 抢锁。
3. **本地服务一律 `127.0.0.1`**：绕开 `localhost` 的 IPv6(::1) 解析歧义与同端口野生监听（见 §8 坑表）。
4. **一切健康检查用"端点探针"**，不用 TCP 连通性 —— 同端口 wildcard 应用会制造"假活着"。

---

## 2. 先决条件

| 组件 | 版本 / 规格 | 获取方式 |
|---|---|---|
| opencode 桌面版 | 支持 MCP local server | 公司内分发/官网 |
| bun | ≥1.x（本机实测可用） | bun 官方安装脚本 |
| GBrain CLI | ≥0.52.1（本机 0.52.1.0；0.59.x 已发布，可自行评估升级） | `bun install -g gbrain`（或按官方文档） |
| llama.cpp（Windows） | 本机 b11136（version 0.4.1-dev）整套放入 `~\.llama\bin` | 直接拷贝本机 `~\.llama`（推荐）或 llama.cpp Releases 下载 |
| 嵌入模型 | `bge-m3-Q8_0.gguf`（605MB，1024 维） | 拷贝本机 `~\.llama\models`，或 HuggingFace 下载 |
| 重排模型 | `qwen3-reranker-0.6b-q8_0.gguf`（610MB） | 同上 |
| chat / expansion 端点 | 任意 OpenAI 兼容（本机组用公司内网关 `deepseek-flash`） | 向管理员获取地址与 Key（**绝不写入共享文件**） |
| Python（可选） | 任意 3.x | 仅用于辅助校验脚本 |

---

## 3. 部署步骤（每步含验证）

### S1 安装 bun + gbrain
```powershell
# 安装 bun（官方脚本或拷贝本机），随后：
bun install -g gbrain
gbrain --version        # 期望输出：0.52.x 或更高
```

### S2 初始化大脑（PGLite）
```powershell
gbrain init             # 默认 PGLite，数据落 ~\.gbrain\brain.pglite
gbrain stats            # 期望正常输出（无 "database is already open"）
```

### S3 放置 llama 本地服务（二选一）
- **方案 A（推荐）**：整份拷贝本机 `C:\Users\<用户>\.llama` 文件夹（bin + models + 两个启动脚本）。模型与二进制均为普通文件，拷贝即用。
- **方案 B**：自行下载 llama.cpp 与两个模型，按 §4.3 的参数手动启动。

```powershell
# 启动（幂等，已在跑则无事发生）：
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.llama\start-embed.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.llama\start-rerank.ps1"

# 探针验证（两个都要 200）：
Invoke-WebRequest -Uri 'http://127.0.0.1:18080/v1/embeddings' -Method Post `
  -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"probe","model":"bge-m3"}')) `
  -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
Invoke-WebRequest -Uri 'http://127.0.0.1:18081/v1/rerank' -Method Post `
  -Body ([Text.Encoding]::UTF8.GetBytes('{"query":"q","documents":["a"],"model":"qwen3-reranker-06b"}')) `
  -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10
```

### S4 配置 gbrain（文件面 + DB 面）
- **文件面** `~\.gbrain\config.json`：按 §4.2 模板补齐（引擎/嵌入/建模/端点）。
- **DB 面**（维护脚本会自动执行全部；手动执行须在 opencode 完全退出时）：
```
gbrain config set facts.default_visibility world
gbrain config set search.reranker.enabled true
gbrain config set search.reranker.model llama-server-reranker:qwen3-reranker-06b
gbrain config set search.reranker.timeout_ms 20000    # 高负载期快速放弃（fail-open），避免搜索被拖慢
gbrain config set search.reranker.top_n_in 10         # 缩小重排批次，提高完成率
```
- **验证**（同样须 serve 未运行）：
```
gbrain providers test    # 期望：嵌入探针 ✓ + "All probes green."
gbrain search modes      # 期望：active mode = tokenmax（或你配置的模式）
```

### S5 部署脚本（5 件，放 `~\.config\opencode\memory\scripts\`，见仓库 `scripts\`）
| 文件 | 用途 |
|---|---|
| `gbrain-capture-export.ts` | 常驻导出器（会话→corpus；**内容寻址+幂等+脱敏**） |
| `start-gbrain-capture.ps1` | 导出器启动器（幂等，含写门控检查） |
| `brain-maintenance.ps1` / `.cmd` | 维护窗口全套（锁探测→服务→配置→marker→导出→dream） |
| `brain-onclose.ps1` | 一次性守望（关窗 ≥5min 自动跑一次维护后自退；可选） |

### S6 opencode 接线（`opencode.jsonc`）
按 §4.1 模板添加 `mcp.gbrain` 块（命令 + 4 个环境变量），重启 opencode 生效。
**验证**：新会话里调用 `gbrain` 工具（如 whoami / recall）能通。

### S7 开机自启（Startup 文件夹）
把仓库 `startup-templates\` 里的 3 个 `.vbs` 放入：
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`
- `llama-embed.vbs`、`llama-rerank.vbs`（两个本地服务，静默启动防闪窗）
- `gbrain-capture.vbs`（常驻导出器）
- （可选）`brain-onclose.vbs`（仅首次初始化时用于自动守望，成功后自动退出）

### S8 首次初始化（关键）
1. **完全退出 opencode，保持关闭 ≥5 分钟**（或直接双击 `brain-maintenance.cmd` 手动跑）。
2. 观察 `~\.config\opencode\memory\logs\brain-maintenance-*.log`：
   - `锁探测通过` → `llama-embed/rerank 就绪=True` → `config set … => exit=0`
   - `marker 已写` → `全量导出 => exit=0`
   - `dream[各相位] => exit=0`（propose_takes 较慢，数分钟）
3. 重新打开 opencode。此后自动抽取/摄取在后台自行推进（首次回填数千段需数小时~1 天）。

### S9 验收
按 §6 清单逐项打勾。

---

## 4. 配置模板

### 4.1 opencode.jsonc —— mcp 块模板
```jsonc
"mcp": {
  "gbrain": {
    "type": "local",
    "command": [
      "C:\\Users\\<你的用户名>\\.bun\\bin\\gbrain.exe",
      "serve",
      "--surface",
      "starter"
    ],
    "enabled": true,
    "environment": {
      "GBRAIN_HOME": "C:\\Users\\<你的用户名>",
      "LLAMA_SERVER_BASE_URL": "http://127.0.0.1:18080/v1",
      "LLAMA_SERVER_RERANKER_BASE_URL": "http://127.0.0.1:18081/v1",
      "GBRAIN_QUERY_EMBED_TIMEOUT_MS": "30000"
    }
  }
}
```
> 说明：`starter` 是工具面（约 29 个工具）；`GBRAIN_QUERY_EMBED_TIMEOUT_MS=30000` 用于回填高峰期容忍嵌入排队（默认 6s 会降级为纯关键词；另见 §8）。

### 4.2 gbrain config.json —— 关键键模板（`~\.gbrain\config.json`）
```jsonc
{
  "engine": "pglite",
  "database_path": "C:\\Users\\<你的用户名>\\.gbrain\\brain.pglite",
  "embedding_model": "llama-server:bge-m3",
  "embedding_dimensions": 1024,
  "provider_base_urls": {
    "llama-server": "http://127.0.0.1:18080/v1",
    "llama-server-reranker": "http://127.0.0.1:18081/v1",
    "deepseek": "http://<你的网关地址>:3001/v1"
  },
  "chat_model": "deepseek:deepseek-flash",
  "expansion_model": "deepseek:deepseek-flash",
  "deepseek_api_key": "<你的Key>",
  "memory": { "auto_writeback": "salient", "visibility_posture": "world" }
}
```
> `llama-server` 键名对应本地嵌入配方；`deepseek` 键名只是"OpenAI 兼容端点"的占位名（本机组用公司网关）。修改文件面配置后建议 `gbrain providers test` 验证。

### 4.3 llama 启动参数（两服务）
```
# 嵌入（18080）
llama-server.exe --model "<...>\models\bge-m3-Q8_0.gguf" --embeddings ^
  --host 127.0.0.1 --port 18080 -c 8192 -b 4096 -ub 4096 --log-file "<...>\server.log"

# 重排（18081；--alias 对应 gbrain 模型串 qwen3-reranker-06b）
llama-server.exe --model "<...>\models\qwen3-reranker-0.6b-q8_0.gguf" --alias qwen3-reranker-06b ^
  --reranking --host 127.0.0.1 --port 18081 -c 8192 -b 4096 -ub 4096 --log-file "<...>\server-rerank.log"
```
> `-b/-ub 4096`：长文本（GBrain 长页/长段）嵌入不出 "input is too large"；`--host 127.0.0.1` 见 §8 端口坑。

---

## 5. 环境差异适配（迁移必读）

### 5.1 端口规划与占用检查（最先做）
> 默认规划：**嵌入 18080 / 重排 18081**——嵌入特意避开 8080（本机曾撞"订单系统"的 `0.0.0.0/[::]:8080` 通配监听；v1.1 起彻底分家）。
```powershell
netstat -ano | findstr :18080
netstat -ano | findstr :18081
```
若被其他应用占用（本机曾撞"订单系统"占 `0.0.0.0:8080`）：
- 优先**换端口**（如 18082/18083）：同步改 start 脚本、`config.json` 的 `provider_base_urls`、opencode 环境变量；
- 或先停占用应用；
- **无论何种情况**，客户端地址一律写 `127.0.0.1`，不要写 `localhost`。

### 5.2 企业 DLP（透明加密，如天锐绿盾/IP-guard）
- **若有 DLP**：导出器写 corpus 必须用 **bun/node 进程**（Python/Office 写 .txt 会落地即加密，sweep 读密文静默失败）；对外交付说明用 `.md`（实测明文）。
- **若无 DLP**：以上限制忽略，python/node 写 .txt 均正常。
- **配置防损坏自愈**：本包 `scripts\fix-gbrain-config.py`（信任 python 运行）：`--check` 检查 config.json 是否被 DLP 加密损坏；`--snapshot` 把当前健康配置存为 `config.json.golden` 恢复基线；`--fix` 从 golden/备份恢复。建议部署完成后跑一次 `--snapshot`。

### 5.3 内存不足时的降级策略
- 只跑**嵌入服务**（检索/抽取核心）——**重排不装也能用**（检索 fail-open 不受影响，只是排序质量略降）；
- 关闭不必要的大应用；嵌入式服务常驻约 0.5–2GB，重排约 0.7–4GB（长跑会涨，重启脚本即释放）；
- 回填（数千段）本身就是对嵌入服务的压力测试，允许它慢慢跑（后台自动）。

### 5.4 PowerShell 5.1 三件套（脚本已内置适配）
- 含中文的 .ps1 必须 **UTF-8 BOM** 保存；
- 调用一律 `-ExecutionPolicy Bypass -File`；
- 读文件/捕获原生命令输出必须显式 UTF-8。

### 5.5 路径与权限
- 所有路径以 `%USERPROFILE%` 相对化；用户名不同不影响；
- 无需管理员：自启走 Startup 文件夹。

---

## 6. 验收清单

- [ ] `gbrain --version` ≥ 0.52.1
- [ ] 嵌入探针 200（§3 S3 命令）
- [ ] 重排探针 200
- [ ] `gbrain providers test` → All probes green（serve 未运行时）
- [ ] `~\.gbrain\transcripts\sweep-enabled.md`（marker）存在
- [ ] `gbrain config get facts.default_visibility` → world
- [ ] 导出器日志（`memory\logs\gbrain-capture.log`）持续有 `pass done`
- [ ] `corpus\` 下 `.txt` 增长、`.ingested` 计数增长（首次回填需数小时~1 天）
- [ ] 任意中文词检索 → 有结果且无 `degraded`（高峰期允许 `embed_timeout` 关键词降级）
- [ ] 重排日志（`~\.llama\server-rerank.log`）能看到真实批次任务
- [ ] 维护日志 dream 六相位退出码 0（propose_takes 首次可能报错，重跑一次即可）
- [ ] 新会话对 gbrain 说"回忆一下 X" → 能召回别处会话产生的事实

---

## 7. 日常运维与故障速查

**常态化自动运行**：导出器（常驻）/ sweep（serve 存活时自动）/ llama 双服务（开机自启）。

**"维护窗口"何时用**：需要改 DB 面配置、跑 dream（takes 学习）、全量导出铺底时 —— 完全退出 opencode ≥5 分钟后跑 `brain-maintenance.cmd`（或让守望自动跑）。

**故障速查表**：

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 检索 0 结果 / `degraded: embed_unavailable` | 嵌入服务挂了 | 跑探针确认 → `start-embed.ps1`（幂等自愈） |
| `degraded: embed_timeout`（高峰期） | 回填把嵌入排队打满 | 属正常；等待或加大 `GBRAIN_QUERY_EMBED_TIMEOUT_MS` |
| 命令报 `database is already open through gbrain serve` | serve 在跑（正常保护） | 写类命令需关窗；读走 MCP/`get` |
| sweep 不推进 | serve 不在 / marker 缺失 | 确认 opencode 已开（serve 活）+ marker 存在 |
| facts 召回不到 | visibility 非 world / 刚写异步完成 | 检查 config；重试同一 request_id（本机协议 G-051）|
| 端口探针 404 / `Not Found` | 同端口被其他应用 wildcard 占 & llama 挂了 | netstat 找真凶；重启 llama；核对是否 127.0.0.1 |
| 双实例（同端口两条 LISTENING） | 旧脚本探针误判后双拉起 | 杀掉多余实例；用仓库内新版脚本（端点探针+CIM 判进程） |
| 内存告急 / 服务被"杀" | 长跑内存上涨（重排尤甚） | 重启对应服务（释放）；关大应用；平日留 ≥4GB 空闲 |
| .ps1 中文乱码 | 缺 BOM | 用仓库内脚本（已带 BOM），勿手改编码 |

**日志位置**：`~\.config\opencode\memory\logs\`（capture / maintenance / onclose）；`~\.llama\server*.log`（两个模型服务）。

---

## 8. 已知坑速查（来源环境实测）

| 编号 | 一句话 | 处置（已内置在本仓库中） |
|---|---|---|
| G-058 | DLP 下"信任进程"写 .txt 落地即加密 | corpus 一律 bun 写（导出器已如此） |
| G-060 | gbrain 锁语义：sweep 可 IPC 委托；config/dream 须关服务 | 维护脚本 + 双门控 auto-sweep |
| G-062 | `localhost` 可能解析 IPv6(::1) 撞上其他应用同端口监听 → 404 | 一切本地服务地址钉死 `127.0.0.1`；嵌入/重排改用独立端口 18080/18081（v1.2） |
| G-063 | 回填高峰期查询嵌入默认 6s 超时 → 关键词降级 | 环境变量 `GBRAIN_QUERY_EMBED_TIMEOUT_MS=30000` |
| G-064 | TCP 连得通 ≠ 服务活着（同端口 wildcard 欺骗）；双实例可同绑 | 健康检查=端点探针；启动脚本 PS 5.1 兼容修复 |
| G-013/14 | PS 5.1：中文脚本须 BOM、须 Bypass 调用 | 脚本已含 BOM；调用模板见 §3 |
| G-051 | 写回执"accepted and awaiting"非失败 | 同 request_id 重试 |

---

## 附A 仓库文件清单

```
gbrain-hindsight-deploy\
├─ install.ps1             ← 远程一键引导壳（纯 ASCII 无 BOM；供 irm|iex）
├─ deploy.ps1              ← 一键部署器（幂等、自动备份、-DryRun；由 install.ps1 或 -File 调用）
├─ verify.ps1              ← 验收脚本（对齐 §6 清单）
├─ README.md               ← 快速开始与运维速查
├─ scripts\                → 复制到 ~\.config\opencode\memory\scripts\
│   ├─ gbrain-capture-export.ts               （常驻导出器；含 newestIdx 静默故障修复）
│   ├─ start-gbrain-capture.ps1               （导出器启动器）
│   ├─ brain-maintenance.ps1 / .cmd           （维护窗口）
│   ├─ fix-gbrain-config.py                   （config 被 DLP 加密损坏时的一键自愈）
│   └─ brain-onclose.ps1                      （一次性守望，可选）
├─ llama-scripts\                            → 复制到 ~\.llama\（若未整份拷贝 .llama）
│   ├─ start-embed.ps1
│   └─ start-rerank.ps1
├─ startup-templates\                        → 放入 Startup 文件夹（"%APPDATA%\...\Startup"）
│   ├─ llama-embed.vbs / llama-rerank.vbs     （静默启动，防闪窗）
│   ├─ gbrain-capture.vbs
│   └─ brain-onclose.vbs                      （可选，首装守望）
├─ templates\
│   ├─ opencode-mcp.fragment.jsonc
│   └─ gbrain-config.template.json
├─ tools\
│   └─ merge-mcp.mjs                          （JSONC 安全合并：保留注释/幂等/备份）
└─ docs\
    ├─ deploy-report.md / .html               （本报告）
    ├─ agent-deploy-guide.md                  （给 AI 代理的逐步执行手册）
    └─ stall-postmortem.md / .html            （静默卡死复盘）
```

**不做进仓库的东西（安全）**：`config.json` 真身、opencode.jsonc 真身（含 Key）、`~\.gbrain` 数据库（含个人记忆）、模型权重（1.2GB，走 U 盘/共享盘整份拷贝 `~\.llama` 或由部署器下载）。

## 附B 来源环境实测基线（供对照）

- 机器：Windows 10 专业版 / 15.4GB 内存
- 版本：GBrain 0.52.1.0 · llama.cpp b11136 · 模型 bge-m3-Q8_0(605MB) + qwen3-reranker-0.6b-q8_0(610MB)
- 时延（空载）：嵌入探针 ~0.8s；重排单对 ~1–5s；检索（含嵌入+重排）数秒级
- 回填规模参考：3000+ 段语料，摄取速度每分钟数个文件（受 LLM 提取限速），全程自动
- 内存占用参考：嵌入 ~0.5–4GB、重排 ~0.7–4GB（长跑上涨→重启释放）、serve ~0.4GB

---
*报告完 · 有疑问联系来源环境维护者*
