# GBrain Hindsight 三件套 · 一键部署

把 opencode 的对话**自动变成可检索的长期记忆**：会话自动抽取 + 语义检索与本地重排 + takes 学习（dream）。

- **适用**：Windows 10/11 · PowerShell 5.1+ · 无需管理员权限 · 全程离线可用（模型在本机跑）
- **组成**：① bun 常驻导出器（对话→语料） ② 本地 llama.cpp 双服务（bge-m3 嵌入 + Qwen3 重排） ③ 维护脚本（配置固化 + 全量导出 + dream 六相位）
- **资源**：磁盘约 1.5GB（模型 1.2GB + 数据库）· 内存建议 ≥16GB · 首装 1–2 小时（模型占大头）

> 完整背景/架构/排障见 [docs/deploy-report.md](docs/deploy-report.md)；静默故障复盘见 [docs/stall-postmortem.md](docs/stall-postmortem.md)；给 AI 代理的执行手册见 [docs/agent-deploy-guide.md](docs/agent-deploy-guide.md)。

---

## 一键部署

**方式 A（推荐）：克隆后运行**

```powershell
git clone https://github.com/kaijin1448/gbrain-hindsight-deploy.git
cd gbrain-hindsight-deploy
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
```

**方式 B：远程一行（自动下载仓库并执行）**

```powershell
irm https://raw.githubusercontent.com/kaijin1448/gbrain-hindsight-deploy/main/install.ps1 | iex
```

> 一键脚本必须用 `install.ps1`（纯 ASCII、无 BOM）。`deploy.ps1` 含中文、必须带 UTF-8 BOM，而 PowerShell 5.1 的 `irm | iex` 不会剥离 BOM 首字符会导致解析失败——`install.ps1` 正是为此存在的纯 ASCII 引导壳：它下载仓库后以 `-File` 方式调用 `deploy.ps1`（`-File` 能正确处理 BOM）。

部署器会逐步完成 7 件事，并在需要时向你提问（网关地址/Key、`~\.llama` 来源）：

| 步骤 | 内容 | 需要你做的 |
|---|---|---|
| 1 | 环境体检；缺 bun / gbrain 时帮装 | 网络受限时给离线包 |
| 2 | 放置 `~\.llama`（优先本地拷贝，其次自动下载 1.3GB）并启动双服务 | 有拷贝就给路径（最快） |
| 3 | `gbrain init` + 合并 `~\.gbrain\config.json` | 提供网关 base_url 与 Key（**只写本机**） |
| 4 | 部署脚本到 `~\.config\opencode\memory\scripts` | 无 |
| 5 | 安全合并 `mcp.gbrain` 块进 `opencode.jsonc`（保留注释、自动备份） | 无 |
| 6 | 放置开机自启 + 初始化守望 | 无 |
| 7 | 回执与验收指引 | 完全退出 opencode ≥5 分钟（一次性） |

**部署后（首次初始化）**：完全退出 opencode 保持 ≥5 分钟，守望会自动完成首次初始化；或手动双击 `~\.config\opencode\memory\scripts\brain-maintenance.cmd`。之后重开 opencode 即生效。

**验收**：`powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1`

---

## 常用参数

```powershell
.\deploy.ps1 -DryRun                     # 只看计划，不写任何东西
.\deploy.ps1 -LlamaSource D:\llama-pack.zip   # 从本地压缩包装 .llama（最快）
.\deploy.ps1 -GatewayUrl http://10.0.0.5:3001/v1 -GatewayModel deepseek-flash
.\deploy.ps1 -EmbedPort 18082 -RerankPort 18083  # 默认端口被占时
.\deploy.ps1 -SkipRerank                 # 低内存机器：只装嵌入，检索仍可用（fail-open）
.\deploy.ps1 -SkipAutostart              # 不要开机自启
```

| 参数 | 说明 | 默认 |
|---|---|---|
| `-GatewayUrl` / `-GatewayKey` / `-GatewayModel` | chat/expansion 网关（任意 OpenAI 兼容） | 运行时询问 |
| `-LlamaSource` | `~\.llama` 的文件夹或 zip 路径 | 询问（下载/跳过） |
| `-EmbedPort` / `-RerankPort` | 本地服务端口 | 18080 / 18081 |
| `-SkipLlama` / `-SkipRerank` | 跳过本地服务（不推荐 / 降级） | 否 |
| `-SkipAutostart` / `-SkipTools` | 跳过自启 / 跳过工具安装 | 否 |
| `-DryRun` | 只输出计划 | 否 |

---

## 目录结构

```
gbrain-hindsight-deploy/
├─ install.ps1             远程一键引导壳（纯 ASCII 无 BOM，供 irm|iex 用）
├─ deploy.ps1              一键部署器（含中文/BOM，供 -File 或由 install.ps1 调用）
├─ verify.ps1              验收检查（对齐报告 §6 清单）
├─ scripts/                → %USERPROFILE%\.config\opencode\memory\scripts\
│   ├─ gbrain-capture-export.ts   常驻导出器（对话→语料；内容寻址、幂等、脱敏）
│   ├─ start-gbrain-capture.ps1   导出器启动器（幂等）
│   ├─ brain-maintenance.ps1/.cmd 维护窗口（配置→marker→全量导出→dream 六相位）
│   ├─ brain-onclose.ps1          一次性守望（关窗 ≥5 分钟自动初始化，成功后自退）
│   └─ fix-gbrain-config.py       config.json 被 DLP 加密损坏时的一键自愈
├─ llama-scripts/          → %USERPROFILE%\.llama\
│   ├─ start-embed.ps1            嵌入服务启动器（幂等，端点探针）
│   └─ start-rerank.ps1           重排服务启动器（幂等，端点探针）
├─ startup-templates/      → 启动文件夹（%APPDATA%\...\Startup）
│   ├─ llama-embed.vbs / llama-rerank.vbs     静默启动本地服务（防闪窗）
│   ├─ gbrain-capture.vbs                     静默启动导出器
│   └─ brain-onclose.vbs                      初始化守望（完成后自动退出，仅首次初始化需要）
├─ templates/              配置模板（占位符，deploy.ps1 自动填充）
├─ tools/merge-mcp.mjs     JSONC 安全合并工具（保留注释、幂等、备份）
└─ docs/                   部署报告与复盘（中文）
```

---

## 铁律（脚本已内置，DIY 时注意）

1. **本地服务地址一律 `127.0.0.1`**，绝不用 `localhost`（防 IPv6/同端口监听歧义）。
2. **健康检查一律用端点探针**（HTTP 200），不用 TCP 连通性（同端口 wildcard 应用会制造假活着）。
3. **导出器必须用 bun 跑**：在有 DLP 透明加密的环境（如天锐绿盾），opencode 等信任进程写 `.txt` 会被加密，只有 bun 写的才是明文。
4. **写库/改 DB 配置须在维护窗口**：完全退出 opencode ≥5 分钟（`gbrain serve` 释放 PGlite 锁）。
5. **含中文的 `.ps1` 必须 UTF-8 BOM 保存**（PS 5.1 才不乱码）；调用一律 `-ExecutionPolicy Bypass -File`。
6. **Key 不落任何文档**：只写入本机配置文件，部署器绝不回显。

---

## 日常运维速查

| 症状 | 处理 |
|---|---|
| 检索 0 结果 / `embed_unavailable` | 运行探针 → `~\.llama\start-embed.ps1`（幂等自愈） |
| 命令报 `database is already open through gbrain serve` | 正常保护：写类命令需关窗；读走 MCP |
| `touched=0` 连续出现在捕获日志 | 检查导出器进程：运行 `start-gbrain-capture.ps1` |
| 检索没有重排效果 | `~\.llama\start-rerank.ps1`；或忽略（fail-open 仅排序略降） |
| config.json 损坏（DLP 加密，`%TSD` 头） | `python fix-gbrain-config.py --fix`（用信任的 python） |
| 需要改 DB 配置 / 跑 dream | 完全退出 opencode ≥5 分钟后跑 `brain-maintenance.cmd` |

日志位置：`~\.config\opencode\memory\logs\`（capture / maintenance / onclose）；`~\.llama\server*.log`。

---

## 安全说明

- 仓库**不含任何密钥**、不含个人数据、不含模型权重（模型走本机拷贝或官方源下载）。
- 部署器对任何既有配置文件（`config.json`、`opencode.jsonc`）**修改前自动备份**（`.bak-时间戳`）。
- 仓库经 DLP 环境实测：所有文本以明文 UTF-8 入库、克隆即用。

## License

MIT（脚本与文档可自由分发；模型权重遵循各自许可：bge-m3 = MIT，Qwen3-Reranker = Apache-2.0，llama.cpp = MIT）。
