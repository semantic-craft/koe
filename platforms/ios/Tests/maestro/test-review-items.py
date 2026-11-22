import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
APP = "com.semanticcraft.koe.ios"


def _load_seed():
    spec = importlib.util.spec_from_file_location("run_mobile_e2e", ROOT / "scripts/run_mobile_e2e.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.seed


def main(udid):
    seed = _load_seed()
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
