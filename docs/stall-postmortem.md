# 自动捕获「静默卡死」复盘 — 同配置机器防坑指南

> 故障窗口 2026-09-29 21:42 ～ 2026-09-30 01:41（本地时间，约 4 小时）· 状态：已修复并全链路验证 · 适用：Windows + GBrain-Hindsight（bun 导出器）同配置部署
> 修复已包含在本仓库的 `scripts\gbrain-capture-export.ts`（含 `newestIdx` 补丁）。

## 01 · 30 秒速读（TL;DR）

- **现象**：捕获日志一切"正常"（每 3 分钟输出一行），但 `touched=0` 持续、新对话不再进入语料——完全无报错的"静默停摆"。
- **根因**：导出器把一条"被中断的悬空消息"（`completed` 永远为 NULL）误判为"仍在流式输出"，每轮 pass 都在它身上 `break`，整个会话被跳过。
- **影响**：被堵会话约 4 小时未捕获（294 条后续消息积压）；旧逻辑要等 24 小时才自愈。
- **修复**：判定条件改为——"仅当未完成消息是批次最新一条时才等待；若其后还有消息（说明流已中断）则照常导出"。补录 19 段，语料 143/143 全消化。
- **防坑**：另一台机器先查脚本是否含 `newestIdx`；修复后必须重启捕获驻留进程（改文件不会热加载）。

## 02 · 一分钟了解这条管线

opencode.db → 导出器（bun 常驻循环 180s）→ 语料 .txt → gbrain sweep → 事实入库（可检索）

- 导出器每 180 秒扫一次 opencode.db，只导出水位线之后的新消息（每个会话分别记录 lastTs/lastId）。
- 写文件前查重：同名文件或已有 `.ingested` 印章 → 跳过；天然幂等，随时可安全重跑。
- **关键认知："循环活着" ≠ "捕获在工作"。** 这次故障里循环、日志、进程全都正常。

| 名称 | 路径 | 作用 |
|---|---|---|
| 导出器脚本 | `%USERPROFILE%\.config\opencode\memory\scripts\gbrain-capture-export.ts` | 唯一需要打补丁的文件 |
| 捕获日志 | `%USERPROFILE%\.config\opencode\memory\logs\gbrain-capture.log` | 每轮 pass 一行记录 |
| 水位线状态 | `%USERPROFILE%\.gbrain\transcripts\oc-export-state.json` | 各会话的 lastTs/lastId |
| 语料目录 | `%USERPROFILE%\.gbrain\transcripts\corpus\` | .txt 语料 + .ingested 印章 |
| 启动器 | `%USERPROFILE%\.config\opencode\memory\scripts\start-gbrain-capture.ps1` | 幂等启动（已在跑则跳过） |

## 03 · 症状与识别

- 日志里连续多轮 `pass done: sessions=33 touched=0 msgs=0 segments: +0 written`，而你正在活跃对话；
- `oc-export-state.json` 的最新水位线时间停滞（超过 10 分钟不动就该起疑）；
- 语料目录没有新的 .txt 文件；
- **矛盾点（一锤定音）**：opencode.db 的修改时间是"刚刚"（消息在正常写库），但导出就是不发生 → 问题在导出端，不在数据源。

快速自检：

```powershell
# ① 最近日志里 touched= 是否连续为 0？
Get-Content "$env:USERPROFILE\.config\opencode\memory\logs\gbrain-capture.log" -Tail 20 |
  Select-String 'pass done'

# ② 水位线最新时间（与当前时间对比；停滞即异常）
$st = Get-Content "$env:USERPROFILE\.gbrain\transcripts\oc-export-state.json" -Raw | ConvertFrom-Json
$maxTs = ($st.sessions.PSObject.Properties | ForEach-Object { $_.Value.lastTs } | Measure-Object -Maximum).Maximum
[DateTimeOffset]::FromUnixTimeMilliseconds($maxTs).ToLocalTime()

# ③ opencode.db 是否在实时写入（对照组）
(Get-Item "$env:USERPROFILE\.local\share\opencode\opencode.db").LastWriteTime
```

## 04 · 根因机制

- **触发条件**：任意一次 assistant 消息输出中途被中断（手动停止 / 客户端异常退出 / 进程被杀）→ 该消息的 `completed` 永远为 NULL（"悬空消息"）。
- **旧逻辑（问题代码）**：

```typescript
if (role === 'assistant' && r.completed == null) {
  if (Date.now() - r.time_created < 86_400_000) break; // 误判：视为仍在流式输出，等下一轮
  // 超 24h 才兜底导出
}
```

消息批次按时间升序处理；悬空消息后面还排着 294 条新消息，但循环在遇到悬空消息时直接 `break`，跳过整个会话——水位线不推进，下一轮 pass 从同一位置重读、再次 `break`，直到那条消息"年龄"超过 24 小时才被兜底导出。

**语义洞察**：真正流式中的消息必然是批次里最新的一条——它后面不可能再排着更晚的消息。若未完成消息后面还有消息 → 流已被中断，`completed` 永远不会补上 → 继续等待毫无意义。

## 05 · 修复对照

补丁只改一处：`runPass()` 中未完成消息的判定逻辑。

**修复后（已包含在本仓库脚本中）**：

```typescript
// A null-completed assistant msg is only "live" when it is the newest
// exportable row; if any row follows it, the stream was aborted mid-way
// and we must export its text instead of jamming this session forever.
let newestIdx = -1;
for (let i = rows.length - 1; i >= 0; i--) {
  const ro = rows[i].role;
  if (ro === 'user' || ro === 'assistant') { newestIdx = i; break; }
}
for (let i = 0; i < rows.length; i++) {
  const r = rows[i];
  if (outOfBudget()) break;
  const role = r.role;
  if (role !== 'user' && role !== 'assistant') continue;
  if (role === 'assistant' && r.completed == null) {
    if (i === newestIdx && Date.now() - r.time_created < 86_400_000) break; // live stream: wait for a later pass
    // aborted mid-stream (rows follow) or stale >24h: stream is dead - export whatever text exists
    log(`note: exporting incomplete msg ${r.id} (${i === newestIdx ? 'stale>24h' : 'aborted mid-stream'})`, false);
  }
  // ...原有导出逻辑...
}
```

| 情形 | 修复前 | 修复后 |
|---|---|---|
| 未完成消息是批次最新一条（真流式中） | 等待下一轮 | 等待下一轮（不变） |
| 未完成消息后面还有新消息（已中断） | 整个会话堵死（24h 兜底才恢复） | 立即按其现有文本导出，水位线正常推进 |
| 未完成消息超过 24h（陈旧） | 兜底导出 | 兜底导出（不变） |

## 06 · 同配置机器处置手册

**第 0 步 · 判断是否需要处理**

```powershell
Select-String -Path "$env:USERPROFILE\.config\opencode\memory\scripts\gbrain-capture-export.ts" -Pattern "newestIdx"
```

有输出 = 已含修复；无输出 = 需要修复：直接使用本仓库的 `scripts\gbrain-capture-export.ts` 整文件覆盖（脚本用 `$USERPROFILE` 相对寻址，跨机器直接可用）。

**第 2 步 · 重启捕获驻留进程（必须——改文件不会热加载）**

```powershell
# 先停旧进程
Get-CimInstance Win32_Process -Filter "Name='bun.exe'" |
  Where-Object { $_.CommandLine -like '*gbrain-capture-export*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
# 再启动（幂等脚本）
& "$env:USERPROFILE\.config\opencode\memory\scripts\start-gbrain-capture.ps1"
```

**第 3 步 · 验证**

```powershell
# 正常情形：几分钟后日志出现 +N written 即工作正常；深度预览（只读不落盘）：
& "$env:USERPROFILE\.bun\bin\bun.exe" run "$env:USERPROFILE\.config\opencode\memory\scripts\gbrain-capture-export.ts" --once --dry-run --max-segments 0 --no-sweep
```

**已中招恢复流程（会话已被堵时，6 步）**

```powershell
$bun = "$env:USERPROFILE\.bun\bin\bun.exe"
$script = "$env:USERPROFILE\.config\opencode\memory\scripts\gbrain-capture-export.ts"
# 1) 确认补丁已在（应输出含 newestIdx 的行）
Select-String -Path $script -Pattern "newestIdx"
# 2) 停旧驻留进程
Get-CimInstance Win32_Process -Filter "Name='bun.exe'" |
  Where-Object { $_.CommandLine -like '*gbrain-capture-export*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
# 3) 补录导出（不加 --dry-run 即真实补录）
& $bun run $script --once --max-segments 0 --no-sweep
# 4) 手动 sweep 消化积压（积压 >20 段时重复执行）
& "$env:USERPROFILE\.bun\bin\gbrain.exe" sweep --once --budget-ms 300000 --batch-limit 20 --json
# 5) 重启驻留进程
& "$env:USERPROFILE\.config\opencode\memory\scripts\start-gbrain-capture.ps1"
# 6) 核验：日志 tail + 语料待消化数（期望 pending=0）
Get-Content "$env:USERPROFILE\.config\opencode\memory\logs\gbrain-capture.log" -Tail 8
$c = "$env:USERPROFILE\.gbrain\transcripts\corpus"
$txt = @(Get-ChildItem $c -Filter *.txt); $side = @(Get-ChildItem $c -Filter *.ingested)
$pending = @($txt | Where-Object { -not (Test-Path ($_.FullName + '.ingested')) })
"txt=$($txt.Count) sidecar=$($side.Count) pending=$($pending.Count)"
```

**红线提醒**：全程不需要关闭 opencode、不碰数据库文件（sweep 会经 serve 内部委托执行）；停进程用普通 `Stop-Process` 即可（无需 `-Force`）；不要删除语料目录；唯一必须记住的一步是"重启驻留进程"。

## 07 · 实战数据（2026-09-30）

| 时刻（本地） | 事件 |
|---|---|
| 21:42:44 | 悬空消息产生（会话被堵起点） |
| 00:08:28 | 最后一次全局捕获写入（此后 85+ 分钟 touched=0） |
| ~01:33 | 诊断确认：水位线停滞 + 复刻查询命中"首行未完成" |
| 01:40:54 | dry-run 验证修复：234 条消息待处理、19 段待写 |
| 01:41:17 | 实弹补录完成：+19 段；日志出现 aborted mid-stream 标记 |
| 01:42–01:45 | sweep 消化：187s，pending 归零 |
| 01:44:53 | 驻留进程重启（新 PID）；首轮 +1 段、自动 sweep rc=0 |
| 01:47 / 01:50 | 后续两轮 tick 验证：每轮正常捕获（+1 段）、自动 sweep rc=0 |

**4 小时被堵时长（21:42 → 01:41） · 294 积压消息数 · 19 补录语料段 · 143/143 语料 .txt / 已消化（pending=0）**

关键日志行：

```
[2026-09-29T17:41:17Z] note: exporting incomplete msg msg_0ed6... (aborted mid-stream)
[2026-09-29T17:41:17Z] pass done: sessions=33 touched=1 msgs=235 segments: +19 written, 0 skip | 63ms
[2026-09-29T17:50:55Z] pass done: sessions=33 touched=1 msgs=1 segments: +1 written, 0 skip | 8ms
```

## 08 · 防坑速查卡

- **「每天看一眼」**：日志 `touched=` 连续为 0 且你在活跃对话 → 立即按 §03 三连命令排查。
- **「中招四连」**：打补丁（或整文件复制）→ 重启驻留进程 → dry-run / 日志验证 → 补录+sweep（若已积压）。
- **「别做」**：别删语料；别跳过"重启驻留进程"；别把"等 24h 自愈"当可接受方案。
- **一句话**：捕获沉默 ≠ 正常；循环活着 ≠ 在干活；补丁落了 ≠ 生效（要重启）。
