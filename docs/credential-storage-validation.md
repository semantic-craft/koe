# 用户模型密钥安全存储（#9）

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
