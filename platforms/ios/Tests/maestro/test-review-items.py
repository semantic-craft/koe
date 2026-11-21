"""Run after cargo build -p koe-host-api and the iOS self-check, passing its simulator UDID."""
import ctypes
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
APP = "com.semanticcraft.koe.ios"


def seed(directory, *, title="行动页测试", speakers=()):
    library = "libkoe_host_api.dylib" if sys.platform == "darwin" else "libkoe_host_api.so"
    api = ctypes.CDLL(str(ROOT / "target/debug" / library))
    api.koe_host_session_create.argtypes = [ctypes.c_char_p]
    api.koe_host_session_create.restype = ctypes.c_uint64
    api.koe_host_session_dispatch_json.argtypes = [ctypes.c_uint64, ctypes.c_char_p, ctypes.c_uint64]
    api.koe_host_session_dispatch_json.restype = ctypes.c_void_p
    api.koe_host_string_free.argtypes = [ctypes.c_void_p]
    api.koe_host_string_free.restype = None
    api.koe_host_session_destroy.argtypes = [ctypes.c_uint64]
    api.koe_host_session_destroy.restype = ctypes.c_bool
    handle = api.koe_host_session_create(str(directory).encode())
    if not handle:
        raise RuntimeError("Failed to open test workspace")

    def send(command, **fields):
        raw = api.koe_host_session_dispatch_json(handle, json.dumps(dict(type=command, **fields)).encode(), 1)
        if not raw:
            raise RuntimeError(command)
        try:
            snapshot = json.loads(ctypes.string_at(raw))
        finally:
            api.koe_host_string_free(raw)
        if snapshot.get("error"):
            raise RuntimeError(snapshot["error"])
        return snapshot

    try:
        detail = send("create_note", title=title, text="核对会议纪要\n整理项目文档")["detail"]
        for index, segment in enumerate(detail["segments"]):
            if speakers:
                send("set_segment_speaker", recordId=detail["id"], segmentId=segment["id"], speaker=speakers[index])
            for command, collection in [("create_task", "tasks"), ("save_memory", "memories")]:
                snapshot = send(command, recordId=detail["id"], segmentId=segment["id"])
                item = next(item for item in snapshot[collection] if item["text"] == segment["text"])
                send("review_item", itemId=item["id"], decision="reset")
        return detail["id"]
    finally:
        api.koe_host_session_destroy(handle)


def main(udid):
    simctl = ["xcrun", "simctl"]
    container = subprocess.check_output(simctl + ["get_app_container", udid, APP, "data"], text=True).strip()
    with tempfile.TemporaryDirectory(dir=Path(container) / "Documents") as workspace:
        seed(workspace)
        trace = Path(workspace) / "review-trace.json"
        subprocess.run(simctl + [
            "launch", "--terminate-running-process", udid, APP,
            "-koe-workspace", workspace, "-koe-trace-output", str(trace),
        ], check=True)
        try:
            maestro = shutil.which("maestro") or Path.home() / ".maestro/bin/maestro"
            subprocess.run([maestro, "test", "--udid", udid, Path(__file__).with_name("review-items.yaml")],
                           check=True, timeout=180)
            reviews = [entry for entry in json.loads(trace.read_text()) if entry["name"] == "review_item"]
            if len(reviews) != 4 or any(entry["hasError"] for entry in reviews):
                raise AssertionError(f"Expected four successful review commands, got {reviews}")
        finally:
            subprocess.run(simctl + ["terminate", udid, APP], check=True)


if __name__ == "__main__":
    main(sys.argv[1])
