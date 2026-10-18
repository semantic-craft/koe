# Project dispatch: Dot 编码派发

Dot（ChatGPT agent dot）已认领的编码工单，由主会话经 zcode-dispatch 的 Dot 路由（Helios receiver `:7791`，HMAC 签名复用既有网关密钥，维持既有来源 IP 白名单）派发到该 job 的隔离检出里执行。这是**编码**路径：执行者可改文件、在分支上提交。它与「[Perplexity × Helios ZCode 本机验证契约](zcode-verification.md)」（只读，ZCode 不改文件、不提交）是两条路径，互不替代。参数合同以 semantic-craft/agent-interop-private 已合并 PR #62 为准；本文与合同不一致时以合同为准、先修文档。

## 派发前核对

- 认领与所有权：工单带 `agent:dots` 且有未过期的 CLAIM（agent、lease）；`task_url` 本身不是认领证明，提交前即时核对 owner 与依赖（票面基线 sha、开放 PR 无同文件冲突），不符即停，不抢他人工单。
- 精确头：`head_sha` 必须是已推送的完整 40 位十六进制 sha，指向派发所基于的精确提交。
- 边界：不读、不写、不打印任何凭据、token、`.env`；不新增账号、provider、凭据或权限；不改 receiver 与宿主配置。

## project_run（POST /v1/dot/jobs）

必需五项，缺一被拒；除可选 `model` 外多给任何字段也被拒：

- `job_id`：16 位十六进制，派发方生成。
- `repo`：本仓为 `semantic-craft/koe`（合同枚举另含 responsay-macos）。
- `head_sha`：40 位十六进制精确头。
- `task_url`：`https://github.com/semantic-craft/koe/(issues|pull)/N`，原始 Issue 或 PR。
- `prompt`：1–18000 字符。

可选 `model`（1–200 字符）：必须是 receiver 配置里已批准的模型 ID，并过既有模型目录与禁用检查；未知、未批准或不可用一律拒绝、无回退。省略时用 receiver 运维配置的默认（现 GLM-5.3）。客户端工具定义可能未刷新到含 `model` 的版本：默认不传；字段被拒先核对合同版本，不得变通绕过。解析出的最终 model 计入请求摘要与 job 回执。

## 结果：project_status 与冲突语义

- 只用 `project_status` 按**原 job_id** 查询；只返回本 Dot 身份自己的原始进度与结果，绝不重派。
- 进度语义 `running` → `completed`/`failed`；POST 返回 202/accepted/queued/running 都不等于完成。
- 结果未知（超时、断连、无回执）时**不盲重派**：先用原 job_id 查终态，不得换新 ID 重发同一任务。
- 同一 job_id 的请求内容变化（含 model 变化）会冲突，不会建第二个 job；改 receiver 默认模型也可能与旧的省略-model 重试冲突——同样回到原 job_id 查询。

## 执行边界

- 模式固定 YOLO/full access：以宿主用户运行；独立检出与身份隔离是协作层隔离，**不是硬沙箱**，不得据此放宽任何核对。
- 不自动合并：执行者普通 push、开 PR（分支 `dots/<issue号>-<短名>`，正文首行 `Closes #N`，trailer `Agent: dots`）；独立评审另起全新会话；合并按 AGENTS.md 交付硬规则由亚里士多德 squash 执行。
- job ID 与结论回帖到原始工单，不建第二套任务账本。
- 链路验收以真实 project_run 的原 job_id 终态、diff、提交与 PR 为准；文档完成不等于真实执行通过。
