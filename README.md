# StellaSora 本地服 · 客户端更新修复脚本

> 症状：客户端自动更新后，**能登录、但一进主界面就弹 `Network Error` → `Network connection error.`（Quit / Retry）**，点 Retry 也没用。
>
> 一句话结论：**是你的本地服务端（Nebula）落后于客户端了**，不是网络、不是防火墙、不是杀软。

本仓库只提供**脚本和文档**，不含任何游戏程序、资源或数据。脚本运行时从下面两个公开仓库取东西：

- 服务端程序：[Melledy/Nebula](https://github.com/Melledy/Nebula) 的官方 nightly（GitHub Actions 产物）
- 服务端数据：[Hiro420/StellaSoraData](https://github.com/Hiro420/StellaSoraData)（各区服的 `bin` / `language`）

---

## 0. 三步搞定（小白版）

前提：**你已经有一个能正常进游戏的本地服**。本脚本不提供游戏本体，也不提供服务端整合包。

1. **完全退出游戏和启动器** —— 光关游戏窗口不够，托盘里的启动器图标也要右键退出（否则文件被占用，脚本会提示你）。
2. **双击 `一键更新.cmd`** → 把本地服目录粘进去（例如 `D:\Stella Sora`）→ 回车。
3. 等它跑完（下载约 70 MB，网速好 1~3 分钟），看到 `[完成] 全部完成`，再双击启动器进游戏。

想先看它要干什么、又不想动文件，就跑一次干跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-client-update.ps1 -ServerDir "D:\Stella Sora" -DryRun
```

### 会卡在哪（先看这里）

| 现象 | 原因 | 处理 |
|---|---|---|
| 提示"检测到这些进程还在运行" | 游戏/启动器/服务端没退干净 | 托盘退出启动器后按回车；连续 3 次仍占用会直接中止，不会动任何文件 |
| 提示"没有写入权限" | 整合包放在 `C:\Program Files` 这类受保护目录 | 右键以管理员身份运行，或把包挪到 D 盘 |
| 提示"没找到 `*\lib\Nebula.jar`" | 目录选错（要选包根目录，不是 `Server` 子目录） | 重新输入；也兼容 `服务端`/`Nebula` 这类改名的子目录 |
| 下载失败 | 网络/代理问题 | 确认能访问 github.com；脚本已自动用 gh-proxy 镜像兜底 |
| 跑完还是进不去 | 客户端又更新了（数据版本变了） | 直接重跑脚本；还不行看第 7 节症状对照 |
| 提示 Java < 21 | 整合包自带的运行时太旧 | 换一个带 Java 21 的整合包 |

> 脚本**不会**杀你的进程（只提示你退出）、**不会**动存档（只做备份）、也**不会**改客户端文件。

---

## 1. 先确认是不是这个毛病

| 检查项 | 该看到什么 |
|---|---|
| 游戏内 | 能登录，进主界面立刻弹 `Network connection error.` |
| 服务端日志 `Server\logs\latest.log` | 反复出现 `[WARN] Unhandled request: 8419`（数字每次更新会变） |
| 客户端日志 `%LOCALAPPDATA%Low\YOSTAR (HONG KONG) LIMITED\StellaSora\Player.log` | `Curl error 6: Could not resolve host: bak-nova.stellasora.global` |

**判据一句话：出现 `Unhandled request: <数字>`，就是服务端协议落后于客户端。**

原理链条：

```
客户端升级(新协议)  →  旧服务端不认识新报文  →  客户端等不到应答
                   →  回落官方备用域名 bak-nova.stellasora.global
                   →  本地环境 DNS 解析不到  →  弹 Network Error
```

---

## 2. 要换的三样东西（缺一样都可能出问题）

| 东西 | 作用 | 不换的后果 |
|---|---|---|
| `Server\lib\Nebula.jar` | 服务端程序本体（协议实现） | 新报文没人应答 → `Unhandled request` → 断线 |
| `Server\Resources\bin`、`language` | 服务端数据（卡池/角色/道具/活动…） | 客户端看得见的新内容服务端不认识 → 抽卡失败、新功能报错 |
| 两份 `config.json` 的 `customDataVersion` | 服务端对外声明的数据版本 | 与客户端数据版本不一致，部分内容校验/展示异常 |

**数据版本号怎么取**（脚本会自己读，这里说清原理）：

客户端目录 `Persistent_Store\prefs.dat` 里有一行

```
LOCAL_SERVER_RESOURCE_VERSION:143
```

这个数字就是数据版本，等于登录界面左上角版本号的最后一段：`2.0.0.143 → 143`。
（历史参考：1.16.1 时代是 `140`，2.0.0 时代是 `143`。）

**区服对应**：`GLOBAL→EN`、`CN→CN`、`JP→JP`、`KR→KR`、`TW→TW`（脚本读服务端 `Server\config.json` 的 `region`）。

### ⚠️ 注意：143 版和 144 版不是一回事（2026-10-21 实测）

客户端更新很密，同一天里就能从 143 热更到 144。两个版本要配的服务端也不一样，混用就会重新出现"网络异常"。

| 项 | 143 版 | 144 版 |
|---|---|---|
| 客户端 `prefs.dat` 的 `LOCAL_SERVER_RESOURCE_VERSION` | `143` | `144` |
| 客户端 `LOCAL_BIN_DIFF_PATCH_RESOURCE_VERSION` | `2` | `3`（这次热更下载了约 29 MB） |
| 两份 config 的 `customDataVersion` | `143` | `144` |
| 合适的服务端 jar | 10-21 **06:14** 的 nightly | 10-21 **13:00 之后**的 nightly（实测 `9271c34` 在 144 上 `Unhandled request` 计数为 0） |
| 数据仓库 EN 版本 | 141 | **144**（10-21 12:44 `Auto-Update EN [144]`） |
| `$GAME_VER`（`ss_win.mani` 头） | `2.0.0` | `2.0.0`（只有最后一段数据版本在变） |

三条要点：

1. **`customDataVersion` 必须精确等于客户端 `prefs.dat` 里的 `LOCAL_SERVER_RESOURCE_VERSION`**。差一个数字就会出现 `100109 / 100111 / 100112`（版本不符）或 `101404 网络异常`。脚本会自动读这个值，不用手填。
2. **143 时代配的 jar 不要直接用在 144 客户端上** —— 会重新刷 `Unhandled request`。客户端更新后直接重跑脚本，它会拉当天最新的 nightly。
3. **数据仓库现在跟得很快**（10-21 一天内 EN 从 141 跳到 144），所以"数据落后"基本不是问题了，重跑一次就能对齐。

---

## 3. 用法

### 方式 A：双击（最省事）

把 `一键更新.cmd` 和 `fix-client-update.ps1` 放同一个文件夹，**双击 `一键更新.cmd`**，按提示输入本地服包根目录（例如 `D:\Stella Sora`）。

### 方式 B：命令行（参数更清楚）

```powershell
# 先干跑：只检测，不写任何文件
powershell -ExecutionPolicy Bypass -File .\fix-client-update.ps1 -ServerDir "D:\Stella Sora" -DryRun

# 确认无误后正式执行
powershell -ExecutionPolicy Bypass -File .\fix-client-update.ps1 -ServerDir "D:\Stella Sora"
```

| 参数 | 说明 |
|---|---|
| `-ServerDir` | 本地服包根目录（里面有 `Server\lib\Nebula.jar`）。不填会尝试自动探测/提示输入 |
| `-ClientDir` | 游戏客户端目录。不填会自动读包根目录 `config.json` 里的 `game_path` |
| `-Region` | `GLOBAL` / `CN` / `JP` / `KR` / `TW`。不填读服务端 config |
| `-SkipJar` / `-SkipData` | 只换其中一样 |
| `-SkipDatabaseBackup` | 不备份存档（存档较大时用，但**建议备份**） |
| `-DryRun` | 只检测并打印计划，不写文件 |

### 脚本会做什么（按顺序）

1. 读客户端数据版本（`prefs.dat`）
2. 下载对应区服的 `bin` / `language`（有 `bubble` / `dirty_words` 也一起换）
3. 解析 `nightly.link` 的签名直链 → 下载 Nebula 最新 nightly → 解出 `Nebula.jar`
4. 备份到 `_update_bak_<时间戳>\`：旧 jar、两份 config、`Resources_bin.zip`、`Resources_language.zip`、可选 `Database.zip`
5. 替换 jar、替换资源、改两份 config 的 `customDataVersion`
6. 打印验证要点

---

## 4. 验证

启动游戏后看 `Server\logs\latest.log`，应该出现：

```
Game version: 2.0.0.143 (GLOBAL)
Loaded 70 GachaDefs.
Http Server started on 5210
```

并且**不再反复出现** `[WARN] Unhandled request: xxx`。卡池能正常抽就说明数据也对了。

---

## 5. 回滚

备份目录 `_update_bak_<时间戳>\` 里有原样备份：

- `Nebula.jar` → 覆盖回 `Server\lib\Nebula.jar`
- `Server_config.json` → 改名为 `config.json` 放回 `Server\`
- `Server_data_config.json` → 改名为 `config.json` 放回 `Server\data\`
- `Resources_bin.zip` / `Resources_language.zip` → 解压覆盖 `Server\Resources\bin`、`Server\Resources\language`
- `Database.zip` → 存档备份（`存档\Database`）

另外脚本替换资源时会把旧目录改名成 `Resources\bin_old_<时间戳>`、`language_old_<时间戳>`，**改回原名也能回滚**。

---

## 6. 常见问题

**Q：上游数据比客户端旧 1~2 个版本怎么办？**
A：正常。数据仓库是靠"抓当前客户端"自动更新的，有时会滞后。一般不影响进游戏和抽卡；等仓库更新后重跑一次脚本即可。

**Q：为什么用 nightly 而不是 release？**
A：这个大版本的支持通常先出现在 nightly（GitHub Actions 构建）里。想固定版本可以自己把 jar 换成 release 里的。

**Q：需要重下游戏本体或那几十 G 资源吗？**
A：不需要。脚本只动本地服务端目录。

**Q：会不会被杀软/防火墙拦？**
A：脚本只做"下载 / 解压 / 复制 / 改 config 文本"，不注入、不改游戏进程。如果 PowerShell 被执行策略拦住，用 `-ExecutionPolicy Bypass`；如果下载被拦，检查代理/网络。

**Q：能给国际服客户端做汉化补丁吗？**
A：不建议、本仓库也不提供。这个客户端带 ACE 反作弊，会拦非白名单模块（实测注入的 DLL 根本不会被加载），删改它自己的文件还会直接拒绝启动。想要中文请用官方 CN/TW 客户端，或在游戏外用 OCR 翻译工具（例如 TranslatorX 这类）做实时翻译。

**Q：换 jar 会不会丢存档？**
A：不会。存档在 `存档\Database`（MongoDB），脚本不碰它；而且会额外备份一份。

---

## 7. 换完还是进不去？症状对照

先记住一条铁律：**客户端每次自动大更新后，都要重跑一次本脚本**。客户端更新很勤（实测一天内从 143 跳到 144），旧 jar 立刻就会重新出现 `Unhandled request`。脚本会自动读取客户端当下的数据版本，所以"重跑"就是正确答案。

| 症状 | 含义 | 怎么办 |
|---|---|---|
| 弹 `Network Error` / `Network connection error.`，服务端日志刷 `[WARN] Unhandled request: 8419` | 服务端 jar 落后于客户端协议 | 重跑脚本（重点是换 jar） |
| 弹 `101404` + 网络异常 / `Network error (101404)` | 版本没对上，或请求打到了不存在的接口（客户端/资源层拿到的 404）。本质仍是**客户端 / 服务端 jar / 数据版本三者不同步** | ①看客户端 `Persistent_Store\prefs.dat` 的 `LOCAL_SERVER_RESOURCE_VERSION`；②看 `Server\config.json` 的 `customDataVersion` 是否等于它；③看服务端日志有没有 `Unhandled request`；④任一不对就重跑脚本 |
| 弹 `100109` / `100111` / `100112`（Version mismatch / 请更新） | `customDataVersion` 与客户端数据版本不一致 | 重跑脚本，或手动把两份 config 的 `customDataVersion` 改成客户端数据版本 |
| 能登录，但卡池列表空 / 新功能报错 | 数据仓库还没跟上客户端版本 | 等半天到一天（仓库自动更新），然后重跑脚本 |
| 服务端启动即退出 / 日志有 `Exception` | jar 与 Java 版本不匹配，或下载不完整 | 确认 `java -version` 是 21+，删掉临时文件重跑脚本 |

**上游还没跟上时**（客户端刚更新、nightly 还没构建）：

- Nebula 有没有新产物：<https://nightly.link/Melledy/Nebula/workflows/gradle/main/Nebula-Nightly.zip>（能下就说明有）
- 数据仓库对应区服有没有更新：<https://github.com/Hiro420/StellaSoraData/commits/main>
- 两边都齐了再重跑脚本。一般客户端更新后几小时到一天内会跟上。

**收集日志求助**：`Server\logs\latest.log` 尾部 + 客户端 `%LOCALAPPDATA%Low\YOSTAR (HONG KONG) LIMITED\StellaSora\Player.log` 里含 `Curl error` / `Unhandled` / `LoginURL` 的行 + 弹窗截图。有这三样就能判断是"jar 落后"还是"版本号没对上"。

---

## 8. 免责声明

- 本仓库**只包含脚本与文档**，不包含任何游戏程序、游戏资源或游戏数据；所有内容在运行时从上述公开仓库获取。
- 仅供学习、研究与自建环境维护使用。请自行确保你拥有相应游戏与数据的合法使用权，并遵守当地法律与游戏服务条款。
- 使用风险自负：脚本会修改你的本地服目录（已有备份，可回滚）。作者不对任何数据丢失、账号风险或其它后果负责。
- 致谢：[Melledy/Nebula](https://github.com/Melledy/Nebula)（服务端模拟器）、[Hiro420/StellaSoraData](https://github.com/Hiro420/StellaSoraData)（数据解包）。

---

## 9. 更新日志

- `2026-10-22`：新增**工具二** [`activity-task-fix/`](activity-task-fix/)——活动任务进度补丁（把 `TaskActivity` 的 `curProgress` 补满 + 用 GM 邮件补发奖励）。起因：活动关卡通关后任务永远显示未完成（模拟器只建任务条目不写进度、也没有 `ActivityTaskRewardReceive` 处理器），灾变防线的赛季排行同理未实现。已在本机实测（60 个任务补满、13 种奖励邮件到账）。
- `2026-10-21`（第二次实测，144 版）：客户端自动热更到 `2.0.0.144`（`LOCAL_SERVER_RESOURCE_VERSION` 143→144、`LOCAL_BIN_DIFF_PATCH_RESOURCE_VERSION` 2→3，下载约 29 MB）。先把服务端还原成"刚更新完"的坏状态（10-07 旧 jar + 140 数据 + `customDataVersion 140`）复现了 `Network Error` 与 `Unhandled request: 8419`；再跑本脚本 → 自动读到 144、拉取当晚 nightly（git `9271c34`，产物 13:00）与数据仓库当日 `Auto-Update EN [144]` → 启动日志 `Game version: 2.0.0.144 (GLOBAL)`、`Loaded 70 GachaDefs`、`Unhandled request` 计数 **0**，完美登录。结论：**客户端每次更新后重跑脚本即可**；另见第 2 节的「143 版 / 144 版对照」。
- `2026-10-21`：首个版本。适配客户端 `2.0.0`（数据版本 143）→ 服务端 jar 2026-10-21 nightly + 数据仓库 `EN [141]`；实测修复"进游戏 Network Error"与卡池不可抽。
- 更早的手工排障记录（1.16.1 / 数据 140 时代）见 README 的历史说明或 issue。
