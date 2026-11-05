#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import struct
import wave

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
root = args.directory.resolve()
root.mkdir(parents=True, exist_ok=False)
audio = root / "phone_1793836800000000.wav"
with wave.open(str(audio), "wb") as out:
    out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    out.writeframes(
        b"".join(
            struct.pack("<h", int(2500 * math.sin(2 * math.pi * 440 * n / 16000)))
            for n in range(16000 * 4)
        )
    )
(root / "recording_library.json").write_text(
    json.dumps(
        {
            "version": 1,
            "assets": [
                {
                    "path": str(audio),
                    "displayName": "兼容验证录音",
                    "source": "phone",
                    "importedAt": "2026-11-05T08:00:00.000Z",
                    "originalComplete": True,
                }
            ],
        },
        ensure_ascii=False,
    ),
    encoding="utf-8",
)
(root / "transcripts.json").write_text(
    json.dumps(
        {
            "byPath": {str(audio): "这是合成资料，音频是四秒提示音。"},
            "manualByKey": {
                "path:" + str(audio): "这是人工校订后的合成资料。\n只验证资料读取和原声播放，不代表语音识别验收。"
            },
        },
        ensure_ascii=False,
    ),
    encoding="utf-8",
)
print(root)
