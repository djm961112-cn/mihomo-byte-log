# Mihomo Byte Log

macOS 上的本地流量账本。记录 Mihomo 连接的上行和下行字节数，按时间、域名、进程、出口节点和规则回查。可以直接在 App 中查看明细，也可以导出 CSV，用 Excel 或 WPS 打开。

## 安装

1. 打开 [GitHub Releases](https://github.com/djm961112-cn/mihomo-byte-log/releases/latest)，下载 `Mihomo-Byte-Log-macOS.zip`。
2. 解压，将 **Mihomo Byte Log.app** 拖到「应用程序」，然后双击打开。
3. 启动兼容的 Clash 客户端，确认它已启动 Mihomo 内核。回到 Mihomo Byte Log，点「开始采集」，状态变为「采集中」后开始记录。

安装包同时包含 Apple 芯片和 Intel 版本，需要 macOS 13 或更高版本。直接运行 App 无需安装 Python、Homebrew 或 Xcode。

发布包使用临时签名，尚未经过 Apple 公证。若 macOS 首次阻止打开，请先确认文件来自本仓库的 Release，再到「系统设置 → 隐私与安全性 → 仍要打开」为这个 App 确认。受管理的 Mac 可能由单位策略限制此操作。[Apple 的首次打开说明](https://support.apple.com/zh-cn/102445)

Release 同时提供 `SHA256SUMS.txt`。下载两份文件后，可以在同一目录执行 `shasum -a 256 -c SHA256SUMS.txt` 校验 ZIP。

## 查询和导出

1. 在菜单栏点 Mihomo Byte Log 图标，选择「查看记录」。关闭明细窗口后，App 可以继续采集。
2. 选择「从」「到」的日期和时间。时间按本机时区显示，结束时间为排除边界。日期范围只影响查询和导出。
3. 输入域名、进程名、出口节点名或规则关键词筛选。勾选「只看代理」可以隐藏出口为 `DIRECT` 的记录。点「刷新」读取最新一页，使用「上一页」「下一页」浏览。
4. 点「导出 CSV…」保存当前筛选范围内的全部明细。CSV 包含采集分钟、连接开始时间、连接 ID、进程、域名、出口节点、协议、规则、上行字节、下行字节、总字节和合计 MB。1 MB = 1,000,000 B。
5. 点「停止采集」停止新增记录，历史仍可查询和导出。退出 App 也会停止采集，下次打开后可以手动开始。

同一条连接跨多个分钟时会有多行，每行只记该分钟采到的字节增量。首次开始采集会以当前计数为基线，历史流量不会计入。CSV 使用 UTF-8 编码，带 BOM 供表格软件识别中文。

## 兼容性

| 环境 | 支持范围与验证情况 |
| --- | --- |
| macOS | 最低部署版本 13.0。Release 包含 `arm64` 和 `x86_64`。App 的实机采集和导出在 Apple 芯片 Mac 上验证，Intel 构建已通过，尚未实机验证。 |
| Clash Verge for v2free | 在 [v2.5.25](https://github.com/fqfqgo/clash-verge-rev/releases/tag/v2.5.25) 搭配 Mihomo **v1.19.32** 的 macOS 服务模式上实测。 |
| Clash Verge Rev | 适配 macOS 上提供兼容 Unix socket 和 `GET /connections` 接口的版本。标准 Rev 尚未做独立实机验证。 |
| 其他客户端 | ClashX、Clash Party 等尚未验证。首版通过下列已知 Unix socket 路径发现内核。 |

按顺序尝试的 Unix socket 路径：

- `/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`
- 当前用户临时目录下的 `verge-mihomo.sock`
- `/tmp/verge/verge-mihomo.sock`

如果一直显示「等待 Clash 内核」，先确认 Clash 本身在运行，再检查所用版本是否提供上述 socket。工具仅通过 Unix socket 访问本机接口，无需开启 TCP 控制端口。

## 数据只在本机

- 记录写入当前 macOS 用户的 SQLite 数据库，位置为 `~/Library/Application Support/Clash Traffic Monitor/traffic-v2.sqlite3`。该目录沿用试用版的数据位置。
- App 启动后会清理超过 **7 天** 的记录，运行期间继续定期清理。手动导出的 CSV 由用户自行保管。
- App 不上传记录、不发送遥测，也不发起外网测速。分享 CSV 前可自行检查其中的域名、IP 和进程信息。
- 采集器每秒读取一次本机 Mihomo 的连接快照。它不修改 Clash 配置、系统代理或路由。读取或写入失败时，采集器会显示状态并重试，应用请求仍由 Clash 自己处理。

## 统计范围和精度

默认记录 Clash 内核快照中可见的直连和代理连接。绕过内核的请求无法采集。采集基于活跃连接快照，两次采样之间完成的短连接可能漏记，连接关闭前的末尾字节也可能少计。拦截和拨号失败等普通日志事件不属于当前的字节明细。显示的字节数来自 Mihomo 连接计数，服务商账单还可能按自身规则统计和结算。[Mihomo 连接接口](https://wiki.metacubex.one/en/api/#connections)

## 从源码构建

在 Mac 上安装 Xcode 或 Command Line Tools 后，在仓库根目录运行：

```sh
bash build.sh
```

产物在 `dist/`，包含 `Mihomo Byte Log.app` 和 `Mihomo-Byte-Log-macOS.zip`。构建使用系统 SDK、Swift、libcurl 和 SQLite，无需安装第三方包。仓库的发布工作流会在推送版本标签后构建并上传相同格式的 ZIP 和校验文件。

## 许可证

[MIT](LICENSE)
