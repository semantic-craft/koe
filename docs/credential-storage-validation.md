# 用户模型密钥安全存储（#9）

## 当前安装要求

Mac 后续更新使用 scripts/install-macos.sh，以同一团队的 Developer ID Application 证书签名，不再使用 ad-hoc 安装。临时签名的 Keychain 访问权限绑定具体代码摘要，换构建会触发系统重新授权，不能仅验证同一构建重启。已经由临时签名写入的条目第一次转为稳定签名时，需要用户在系统窗口亲自输入登录密码并“始终允许”；不会导出或重写用户 Key 绕过授权。

## 行为

用户输入的千问、豆包 Key 存在各自 App 的系统 Keychain；app_settings.json 只存非敏感设置和凭据引用。两端不共享 Keychain，不开启 iCloud 凭据同步。开发进程环境仍仅作为运行时 fallback，持久化从 readSaved 的用户 override 取值，不把解析后的环境 Key 写回。

原生实现共用 darwin/KeychainStore.swift，iOS 使用 AfterFirstUnlockThisDeviceOnly；Mac 使用当前 App 的系统登录钥匙串。通过 Flutter 通道读写单个原子凭据项，写后读回确认。清除某个供应商保留空值标记，防止残留旧 JSON 复活已清除的 Key。旧配置兼容嵌套和扁平字段；Keychain 中已有值优先。

旧 Key 写入并验证成功后才原子重写无密钥 JSON。迁移失败保留原文件并阻止偏好写入洗掉唯一旧副本；设置页可“重试读取安全配置”。换 Key/清除在串行队列中等待存储成功，随后更新内存和成功反馈；写入或读回校验失败回滚旧凭据，回滚也无法确认时必须重读，不能宣称仍是旧状态。异常不包含 Key。任务快照不携带凭据。

不支持安全存储的平台不回退为明文。旧版 App 不认识新 Keychain 格式，降级可能需要重新配置；不会为兼容降级重新导出 Key。

## 回退测试

- 新增“settings serialization never includes in-memory credentials”在旧代码明确失败（Key 进入 JSON），修复后通过。
- 临时文件和假 Keychain 覆盖：两种旧格式迁移、失败保留原文件且拦截偏好覆盖、读失败不当作不存在、换 Key/清除后重启、旧值不复活、元数据写失败回滚、native 写成功而读回失败时回滚。
- 界面覆盖保存失败不显示成功、旧配置仍可用、显式重读和清除入口。测试使用独立目录及假原生通道；没有把 MissingPlugin 当作可写明文。
- 全量 283 项通过，静态分析无问题。Mac Release 和 iPhone Release 均构建并安装。

## 真实使用情况（2026-10-16）

- Mac 原普通 JSON 含千问 Key；新版启动后 JSON 不含密钥，仅存 qwen 引用。未注入环境 Key 的已安装 App 显示千问已配置，并用现有 16:25 短录音完成真实千问调用（125 字）及保存；退出重开后仍显示千问使用中。
- Mac 用同一原生 KeychainStore 对唯一临时服务执行合成凭据写入、读回、替换、清除标记，全部通过；随后删除该独立测试项，未触碰用户条目。可重放：swiftc darwin/KeychainStore.swift test/native/keychain_smoke.swift -o /tmp/koe-keychain-smoke && /tmp/koe-keychain-smoke。
- iPhone 更新后已由用户解锁并打开 App；读取配置仅见 qwen/doubao 引用，没有明文 Key。用户划掉重开 App 后，使用同一 16:25 录音重新豆包转写；读取任务持久化结果为 provider=doubao、stage=complete、130 字、error=null。因此验证了 iPhone Keychain 迁移和跨进程读回后的真实调用。
- 本地脱敏证据在 build/device-validation/keychain-ios-metadata.json、keychain-ios-acceptance.json；不提交 Key、任务全文或私人音频。

## 没跑到的项目

USB 自动控制不可用，手机点击由用户完成，Agent 核对持久记录。手机真实 Key 的替换/清除未操作（用假通道回归验证），Mac 合成条目验证不等同所有签名/安装方式的兼容保证。未尝试重置系统钥匙串、吊销证书或操作用户其他凭据。真机锁屏/系统休眠恢复与完整回听继续由 #15/#16 跟踪。没有长录音实测。

## 2026-10-16 更新构建复验发现

#41 首次验证覆盖了同构建重启，继续安装下一构建后发现 ad-hoc 签名的 Keychain ACL 绑定旧 CDHash，读取被系统拒绝。原配置 JSON 保持无明文、Keychain 原项保留，没有自动清空或替换。

已改用本机现有 Developer ID 证书；系统授权必须由用户本人完成，Computer Use 拒绝操作 SecurityAgent。用户完成“始终允许”后，App 重新显示千问使用中。安装脚本明确验证团队与 bundle 身份，找不到唯一证书就退出，不回退为 ad-hoc；安装前要求退出 App，先对临时副本签名并验证再覆盖安装。已用不同 Dart 构建执行两次 Developer ID 覆盖安装：第一次由用户授权，第二次通过新安装脚本覆盖后，未再要求填写 Key 或授权，原千问仍显示使用中。脚本签名前副本及安装后产物都通过严格签名和团队/bundle 要求校验。

## 2026-10-16 开发隔离与稳定签名的验收

上一节只覆盖了“安装脚本不再用 ad-hoc 签名”。本轮继续修掉两个仍然会向用户索取密码的路径：开发/验证构建默认读个人 Keychain，以及签名标识随构建变化导致的重复授权。

### 行为变更

- `darwin/KeychainStore.swift` 增加 `isolated` / `system` 两种模式。macOS Debug、任何带 `KOE_CREDENTIAL_SOURCE` 的进程（含拼错的值）一律隔离；Release 只有通过 `SecCodeCheckValidity` 校验团队 `LQAVR62TK2` 与 bundle `com.anker.ankerRecorder` 后才使用系统存储，否则同样退回隔离。
- 系统读写包裹在 `SecKeychainSetUserInteractionAllowed(false)` 内，旧条目的 ACL 无法满足时立即返回 `errSecAuthFailed`，不弹窗、不阻塞；交互式授权只保留在设置页“重试读取安全配置”这一条显式路径（`CredentialStore.authorize`）。实测 `kSecUseAuthenticationUIFail` 对这类旧条目的登录钥匙串弹窗无效（阻塞 ≥8 秒），这是本轮换用进程级开关的原因。
- 隔离模式下设置在 `Documents/AnkerRecorderDevelopment/`，个人 `Documents/AnkerRecorder/app_settings.json` 不被迁移或改写。
- 新增 `scripts/sign-macos.sh` 作为唯一签名入口（内外层依次签名、校验封条与指定要求、无 ad-hoc 回退、打印 CDHash 与指定要求）；`scripts/install-macos.sh` 复用它并在覆盖前比较升级前后的指定要求；`scripts/build-dmg.sh` 打包前先签名。

### 本轮证据

- `skills/verify-koe/scripts/check.py native`（2026-10-16，build/verify-koe/native-*）：两个内容不同（SHA-256 不同）的 Developer ID 构建共享一条合成条目，写入、读回、互相覆盖都通过；ad-hoc 对照的第二次读取 0.06 秒内以 `-25293` 失败，且 `SecurityAgent` 未被拉起（`security_agent_before/after=false`），说明不再弹密码框。所有 `debug-*` 与 `release-adhoc-*` 隔离用例通过，Security 调用计数为 0。
- `skills/verify-koe/scripts/check.py isolated-app`：真实 App 两次运行均打印 `KOE_CREDENTIAL_ISOLATION_PASS: load/save/readback/authorize; Security calls=0`，运行后临时 App 与 Debug 产物均已删除。
- 真实安装升级：升级前安装 `CDHash 68f30bf6…`，`scripts/install-macos.sh` 重新构建并签名后为 `6179d37c…`，指定要求不变（install-macos.sh 打印“Existing install shares this code requirement”）。启动后设置页显示“通义 Qwen 使用中”，API Key 仍为已保存状态，全程没有系统授权窗口（无 SecurityAgent），即上一轮用户“始终允许”的授权在换构建后继续有效。
- `flutter test` 287 项通过（须在未加载 `DASHSCOPE_API_KEY` 的非 login shell 运行，否则千问会被环境变量判为已配置而导致 4 项失败）。

### 没跑到的项目

同树 Release 重建是逐字节可复现的（带 `--dart-define` 也一样），所以本轮“不同构建”的升级对照用的是上一轮安装的中间构建，而不是另写一份源码；iPhone 端共享同一份 `KeychainStore.swift` 但未重新安装验证。未做：重置系统钥匙串、吊销证书、删除用户条目；也未在用户设备上触发需要重新授权的全新信任边界（那需要用户本人完成一次“始终允许”）。
