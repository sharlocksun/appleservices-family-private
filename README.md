# appleservices — iCloud 登录与 Windows 验证码

这个版本提供设备身份认证、Apple ID 登录、双重验证和 iCloud 登录令牌获取。
普通登录成功获取 `mmeAuthToken` 后结束，不恢复钥匙串，不读取密码、照片或联系人。
可选的 Windows 验证码入口会登记设备、查询设备状态和监听 AuthKit 登录请求。

`cmd/login` 不执行账号设备注册或 Apple 验证码推送接收。登录成功指 Apple 接受认证并返回 iCloud 令牌，
不保证本程序出现在 Apple 账号设备列表，也不表示它成为能接收后续 2FA 的受信任设备。
`state/device.json` 保存稳定认证身份。普通登录的验证码需手动输入；
Windows 本机验证码入口见下文。

## Windows 运行

需要 Go 1.26 或更新版本（已有 `bin/login.exe` 时可直接运行）。

```powershell
.\run-login.ps1
```

脚本会提示输入 Apple ID 和密码，密码输入不回显。首次登录可能需要验证码。
等待验证码时可输入 `resend` 重发当前方式，输入 `sms` 改为短信，输入 `device` 改为受信任设备验证码。
默认向受信任设备请求验证码，也可以选短信：

```powershell
.\run-login.ps1 -TwoFactor sms
```

使用自己的 anisette 服务：

```powershell
.\run-login.ps1 -Anisette 'https://your-anisette-server.example'
```

程序默认使用公共 anisette 服务池。设备标识及 provisioning 数据会发送给选用的 anisette 服务；
账号密码和验证码由本程序直接提交 Apple 的登录接口。

## 命令行

```powershell
go build -o .\bin\login.exe ./cmd/login
.\bin\login.exe -help
```

可用参数：

| 参数 | 用途 |
| --- | --- |
| `-appleid` | Apple ID，也可用 `APPLESERVICES_APPLEID` |
| `-password` | 账号密码，推荐通过脚本隐藏输入或 `APPLESERVICES_PASSWORD` 提供 |
| `-dir` | 状态目录，默认 `./state`，也可用 `APPLESERVICES_DIR` |
| `-twofactor` | `trusted-device`、`sms` 或 `circle` |
| `-anisette` | 自定义 anisette 服务地址 |
| `-logout` | 删除本地会话，不会撤销 Apple 服务器上的会话 |

成功时只输出：

```text
iCloud authentication successful. Session cookies saved.
This command does not register a trusted device or receive verification codes.
```

失败返回非零退出码。程序不打印密码、令牌、Cookie 或账号内部编号。

## 库调用

```go
login, err := appleservices.BeginLogin(
    appleservices.Credentials{AppleID: appleID, Password: password},
    store, // 实现 appleservices.Store；文件实现见 cmd/login/filestore.go
)
if err != nil {
    return err
}
if login.NeedsTwoFactor() {
    if err := login.RequestCode(appleservices.TrustedDevice); err != nil {
        return err
    }
    if err := login.SubmitCode(appleservices.TrustedDevice, code); err != nil {
        return err
    }
}
client, err := login.Client() // 完成 iCloud 认证，保存会话 Cookie
if err != nil {
    return err
}
// client.DSID、client.ADSID、client.MMEAuthToken、client.CloudKitToken
// 是敏感的登录结果，按需在内存使用，不要打印到日志。
_ = client
```

`BeginLogin` 每次都会向 Apple 验证账号密码，缓存会话仅用于复用可信 Cookie、减少验证码提示。
必须成功调用 `Client()` 才算完成 iCloud 登录。
账号不匹配或缺少账号绑定信息的旧会话会被忽略；失效会话可能重新触发双重验证。

## 保存的状态

- `state/device.json`：稳定设备标识和 anisette provisioning 数据。
- `state/session.json`：账号绑定信息和可信 Cookie，不保存账号密码、验证码、设备锁屏密码或 iCloud 令牌。

状态目录含敏感认证数据，请保存在当前用户可访问的目录，不要上传到 Git。
默认的 `state/` 已加入 `.gitignore`；使用自定义目录时自行排除。

## 登录流程与修复

1. 获取 anisette 设备认证头。
2. GrandSlam / SRP 账号认证。
3. 如果需要，提交受信任设备或短信验证码，然后重新认证。
4. 从认证结果提取 PET，调用 iCloud `loginDelegates` 获取登录令牌。
5. 保存可信 Cookie 并结束。

已移除 `cloudkit`、`ckks`、`escrow`、`octagon`、`keychain` 以及原密码导出命令。
修复缓存存在时提前跳过认证、无需验证码时不保存会话的问题；会话现在绑定账号。
同时保留 anisette 服务提供的 User-Agent，并在刷新认证头失败时返回错误，避免使用过期数据。

2026-10-05 又对照上游进行了协议核查：补上 9 月旧 Xcode 客户端标识的兼容处理，
区分 HTTP 拒绝与 Apple 认证错误，兼容短信 JSON/HTML 返回格式，校验验证码响应中的 plist 错误。
`s2k`、`s2k_fo` 的计算已通过独立 Python SRP 实现生成的参考向量验证。
来源、无凭据探测结果及验证边界见 [协议核查记录](docs/protocol-audit.md)。

Apple 请求的证书验证传输现在遵循 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 配置。
原来的传输会绕过环境代理，可能在设备初始化之前就出现连接被拒绝。

GSA 认证请求现在各用一条独立 HTTP/1 连接，避免复用连接导致 `init` 成功、
`complete` 返回 429。Cookie、设备身份、代理和证书验证保持连续。
实际验证已通过原账号的密码认证和服务端证明校验，进入双重验证码阶段；
随后完成短信验证、iCloud 登录令牌交换及会话保存。完整记录见协议核查记录。

短信验证码使用 GSA `/auth/verify/phone` 接口；支持自动发送短信的 201 返回。
验证码校验响应中的 PET 和服务令牌会保留在内存中，直接用于完成登录，避免丢弃令牌后再次触发双重验证。

## 验证与限制

```powershell
go test ./...
go vet ./...
```

测试使用本地模拟认证和本地 HTTP 服务，不访问真实 Apple 账号。
本次已使用用户授权账号完成真实短信验证和 iCloud 登录，并使用保存的会话再次通过密码认证及 iCloud 令牌交换，未再次要求验证码。
未验证其他账号。随后已通过本机 Apple 推送服务取得真实令牌，设备登记请求被接受，
并实际收到新登录的 AuthKit 请求。随后接入 Windows 本机 ADI 模块，
本机生成码被另一个需要双重验证的新会话接受，该会话也完成了 iCloud 令牌交换。
验收没有使用测试期间发到 iPhone 的验证码。
这是非官方私有协议实现。

## Windows 本机验证码

### 可视化控制台

```powershell
.\run-ui.ps1
```

启动本机网页面板并打开浏览器，地址为 `http://127.0.0.1:18741`。
Windows 下也可以直接双击 `一键启动.cmd`；结束时双击 `一键停止.cmd`，脚本会先停止各账号后台，再关闭面板并保留设备身份与登录状态。
界面支持登录、首次短信验证、在线与推送状态、设备列表刷新、手动续登录、
显示/复制六位码和允许/拒绝当前登录请求。关闭浏览器不会停止后台，
点击“停止后台”才清理连接；设备身份与 Cookie 会保留。

面板沿用 `state/`。已支持控制接口的后台会直接接入；旧版后台需要用同一账号重新连接一次。
密码只在当前进程内用于认证和续登录，不保存到文件。
验证码仅通过本机响应显示，60 秒后隐藏；隐藏时间不代表 Apple 的验证码有效期。
面板及后台控制仅监听回环地址，校验主机、来源和随机控制凭据，页面不加载外部脚本或字体。

首次运行脚本会编译面板与后台，需要 Go 和前述 Windows 本机依赖。
可使用 `-NoOpen` 不自动打开浏览器，或使用 `-Port` 更改端口。

本机已验证的入口：

```powershell
.\setup-native-adi.ps1
.\run-trusted-device.ps1 -Check
.\run-trusted-device.ps1
```

需要已安装的 iCloud for Windows、Go、64 位 Python 3.10+、gcc/MinGW，以及经过签名和哈希校验的
OpenBubbles 1.18.800.0 Windows 模块。此机器已有对应 Store 包缓存，脚本不自动下载或安装软件。
沿用已有 `state/device.json`；其他机器先用普通登录入口建立状态。
账号密码由脚本提示输入；首次验证默认向绑定手机号发短信。

登录后输入 `code` 可主动显示本机生成的六位码；收到登录请求时可输入 `allow` 或 `deny`。
发送一次测试登录请求可能也会通知账号原有的 iPhone。这个通知与首次短信验证是两个不同的步骤。

本机生成码的真实登录验收已通过。用户随后提供的 Apple 官网截图明确显示
`appleservices` 为可接收验证码的受信任设备。Circle 配对流程已接入面板和后台协议；真实 Apple 端到端配对仍需另一个已授权设备实际返回消息。此前使用手动 `code` 完成的验证不能替代这项验收。依赖和精确验证边界见 [实现记录](docs/trusted-device.md)。

保持登录及推送在线：

```powershell
.\run-trusted-device.ps1 -Background
.\run-trusted-device.ps1 -Status
# 主动停止时：
.\run-trusted-device.ps1 -Stop
```

后台每 10 分钟重新认证、续报设备并拉取设备列表，保存刷新的 Cookie。
首次短信验证需在前台完成。后台无自动退出时长，关闭终端输入仍继续运行，
不会自动批准请求或把生成码写入日志。Windows 注销/重启后需重新启动。
在线状态记录在 `state/runtime.json`，不包含账号、密码、Cookie 或令牌。
前台输入 `devices` 可重新查询设备数量与当前安装是否可见。

本项目使用自己的登录状态文件；Windows 官方 iCloud 客户端使用它自己的认证状态。
保持本项目在线不等于完成官方客户端的“验证你的 Apple 账户”。

### iCloud+ 储存页面报错

如果官方 iCloud for Windows 的储存空间页面显示 HTTP 400，先运行：

```powershell
.\tools\diagnose-icloudplus.ps1
```

该命令仅输出官方日志的时间、错误类别和返回码，不输出原始日志、账号、URL 参数或认证头。默认查看最近 24 小时；使用 `-Json` 可取得结构化结果。

`terms_update_required` 表示 Apple 要求更新服务条款，需要先完成官方客户端的条款流程。HTTP 401、账户验证提示和购买页面脚本错误分别记录；这些历史日志不能单独证明购买页面 HTTP 400 的原因，也不能证明账户目前已验证。排查记录见 [官方客户端验证记录](docs/official-icloud-verification.md)。

如果需要测试已安装的新 WebView2 运行时，可运行 `.\tools\start-icloud-modern.ps1 -Restart`。该入口只重启官方 iCloud 主界面，使用 Microsoft 签名校验通过的已安装运行时与单独页面缓存；环境变量仅作用于本次启动。正常重启官方客户端即可恢复原运行时与原页面缓存。这是兼容性测试入口，不代表账户验证或订阅错误已经修复。

原始源码保存在 Git 的初始提交 `d6fb108`，也有 `backups/original-source.zip` 备份。

MIT License；与 Apple 无关联。
## Multiple accounts

Each account must run with its own state directory. This keeps the Apple
session, device identity, push state, and refresh status isolated. Copy
`accounts.example.json` to `accounts.json`, replace the placeholders locally,
and run:

```powershell
.\run-multi.ps1 -AccountsFile .\accounts.json
```

The script starts one unified hub at `18741` and one isolated dashboard and
worker per account on `18742`, `18743`, and so on. Credentials are passed
through the child process environment and are not placed on the command line.
Each account may require its own first SMS verification in its dashboard.
