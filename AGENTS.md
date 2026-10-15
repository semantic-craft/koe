# Soundcore Manager 开发入口

目录名为 koe，Flutter package 名称与产品身份以 [pubspec.yaml](pubspec.yaml) 和 [README](README.md) 为准。

| 改动 | 入口 |
| --- | --- |
| BLE/Wi-Fi 通信、帧协议与解密 | [PROTOCOL](PROTOCOL.md)、[lib/ble](lib/ble/)、[lib/wifi](lib/wifi/)、[lib/protocol](lib/protocol/)、[lib/crypto](lib/crypto/) |
| 录音、转写与状态 | [lib/audio](lib/audio/)、[lib/ai](lib/ai/)、[lib/state](lib/state/) |
| 界面与平台接入 | [lib/ui](lib/ui/)、[lib/platform](lib/platform/)，再读对应平台目录 |

在根目录运行 `flutter test`，现有用例在 [test](test/)。构建和真机运行按 README；设备连接、音频接收和真实转写需另留证据。安装脚本在 [scripts](scripts/)，运行前核对其目标设备和副作用。
实现、评审或验收前读相关 [lessons](lessons.md)；出现可复用的纠正或漏验时更新原条目。

## Agent skills

### Issue tracker
工单统一使用 semantic-craft/koe 的 GitHub Issues。见 [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md)。

### Triage labels
使用默认五种分流标签。见 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)。

### Domain docs
采用单一领域文档布局。见 [docs/agents/domain.md](docs/agents/domain.md)。
