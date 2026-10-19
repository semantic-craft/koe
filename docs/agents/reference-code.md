# 参考代码检索（XERJ）

写 BLE、录音、音频编解码、后台播放或「录音 + 记忆 + 待办」类功能前，先用本机 XERJ 检索同类项目和锁定版本依赖的实现，引用 `路径:行号` 后再写代码。检索不到相关内容就说明，然后照常工作。

## 什么时候用

- **用**：录音豆协议与上游改法、flutter_blue_plus / record / just_audio / opus_codec 在**当前锁定版本**里的真实行为（原生 Darwin 侧尤其），以及 omi 怎么处理同类问题（BLE 音频流、断线重连、转写管线、记忆与待办）。
- **不用**：Flutter / Dart 常见 API 和已经能准确写出的写法。对模型记得住的公开代码，检索只增加成本（XERJ 的研究里这一类检索反而更差）。

## 命令

```bash
scripts/ref search "reconnect after disconnect restore state" -k 5   # 参考项目
scripts/ref def "startRecording"                                      # 参考项目里的定义位置
scripts/ref self "transcription job resume"                           # Koe 自身
scripts/ref status                                                    # 节点与索引条数
```

节点没起会自动起（`127.0.0.1:9200`，仅本机、无认证）。默认嵌入是词法（BM25 + 子词重叠），不是语义模型：用代码里会出现的词，不用意译。

## 语料（在 `scripts/ref` 顶部维护）

| 名称 | 内容 | 版本 | 许可 |
| --- | --- | --- | --- |
| `repos/soundcore-upstream` | 上游 tacshi/Soundcore，Koe 的来源 | 固定 commit | 无许可，仅私用参考，不复制进其他项目 |
| `repos/omi` | BasedHardware/omi 的 `app/`（Flutter 硬件录音 App），稀疏检出 | 固定 commit | MIT |
| `deps/<包>-<版本>` | 从 `~/.pub-cache` 复制的锁定依赖：flutter_blue_plus 系、record 系、just_audio / audio_service / audio_session、opus_codec 系 | 跟随 `pubspec.lock` | 各包 LICENSE；flutter_blue_plus 是自有许可，只读不抄 |

默认只借思路自己写。确要照抄 MIT 代码时，在文件头和 [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md) 注明出处。

升级依赖或改固定 commit 后运行 `scripts/ref sync`；main 有较多新提交后运行 `scripts/ref koe` 刷新自身索引（固定索引主工作区，worktree 里的未合并改动不在其中）。新增语料：在 `REPOS` 或 `DEPS` 里加一行；稀疏路径要写，避免把整仓资产拉下来。

## 放在哪里

都在 `~/Projects` 之外，不进 Git 和 Syncthing，删了可以用 `scripts/ref sync` 重建：

- `~/.cache/xerj-ref/koe/`：克隆和依赖副本（2026-10-19 约 117 MB）。
- `~/.local/share/xerj/`：节点数据、索引日志、`node.pid`、`node.log`（约 280 MB；参考语料约 6.5 万条，首次索引约 12 分钟，节点内存约 2 GB）。
- `xerj` 本体：`~/.local/bin/xerj`（安装：`curl -fsSL https://xerj.org/get | sh`，安装脚本会校验 SHA-256）。

节点内存随索引条数增长；不用时 `scripts/ref stop`，重启后索引还在。只停 `scripts/ref` 起的节点，不 `pkill xerj`。

这些文件不会自动清除。要全部删掉，运行 `scripts/ref clean`：它会停掉节点，删除上面两个目录，保留 `xerj` 本体。之后需要时再运行 `scripts/ref sync` 重建。
