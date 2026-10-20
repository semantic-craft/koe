#!/usr/bin/env python3
"""Local Android plan: render, serve, and append evidence from other sessions."""
import argparse
import copy
import fcntl
import html
import json
import os
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATUSES = {"queued": "待开始", "active": "进行中", "blocked": "阻塞", "done": "代码已交付"}
DEVICES = {"pending": "待验收", "passed": "本批设备项通过", "failed": "发现问题", "skipped": "跳过 / 设备离线"}


def load():
    return json.loads((ROOT / "plan.json").read_text())


def options(values, selected):
    return "".join(f'<option value="{key}"{" selected" if key == selected else ""}>{value}</option>' for key, value in values.items())


def render(plan=None):
    if plan is None:
        with (ROOT / ".plan.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return render(load())
    esc = lambda value: html.escape(str(value), quote=True)
    cards = []
    for task in plan["tasks"]:
        checks = "".join(f'<label class="check"><input type="checkbox" name="{step["id"]}"{" checked" if step["done"] else ""}><span>{esc(step["text"])}</span></label>' for step in task["steps"])
        notes = "".join(f'<li><div class="note-meta">{esc(n["author"])} · {esc(n["at"])}</div><p>{esc(n["text"])}</p></li>' for n in task["notes"])
        files = " · ".join(esc(f) for f in task["files"])
        deps = " → ".join(task["depends"]) or "可先开始"
        cards.append(f'''<article class="task" id="{task['id']}" data-task="{task['id']}" data-revision="{task['revision']}">
<div class="task-heading"><span class="task-id">{task['id']}</span><div><h3>{esc(task['title'])}</h3><p>{esc(task['outcome'])}</p></div><span class="badge">{STATUSES[task['status']]}</span></div>
<p class="dependency">前序：{esc(deps)} · 对应规格第 {', '.join(map(str, task['stories']))} 条</p>
<p class="next"><strong>下一步</strong> {esc(task['next'])}</p>
<details><summary>实施清单与完成标准</summary><div class="checklist">{checks}</div><div class="criteria"><strong>完成标准</strong><p>{esc(task['acceptance'])}</p><strong>真机检查</strong><p>{esc(task['deviceChecks'])}</p><strong>文件归属</strong><p class="files">{files}</p></div></details>
<form class="task-form"><div class="fields"><label>执行对话 / 负责人<input name="owner" value="{esc(task['owner'])}" placeholder="对话名称或链接"></label><label>开发状态<select name="status">{options(STATUSES, task['status'])}</select></label><label>设备验收<select name="device">{options(DEVICES, task['device'])}</select></label></div>
<label>交付证据<textarea name="evidence" rows="2" placeholder="PR 链接、提交、检查结果；代码已交付需填写">{esc(task['evidence'])}</textarea></label>
<label>真机证据 / 跳过原因<textarea name="deviceEvidence" rows="2" placeholder="设备、构建、实际结果；未跑不填通过">{esc(task['deviceEvidence'])}</textarea></label>
<details class="discussion"><summary>留言 <span class="note-count">{len(task['notes'])}</span></summary><ol class="notes">{notes or '<li class="empty-note">尚无留言。可记录阻塞、交接或下一步。</li>'}</ol><label>添加留言<textarea name="comment" rows="3" placeholder="这次完成了什么、证据在哪里、下一对话从哪继续"></textarea></label></details>
<div class="task-footer"><label class="delivered"><input type="checkbox" name="delivered"{" checked" if task['status'] == 'done' else ""}>本批代码已交付</label><button type="submit">保存本批更新</button><span class="save-status" role="status"></span></div></form></article>''')
    sources = "".join(f'<button type="button" class="source-link" data-url="{esc(s["url"])}">{esc(s["label"])}</button>' for s in plan["sources"])
    decisions = "".join(f'<li>{esc(d)}</li>' for d in plan["decisions"])
    template = (ROOT / "template.txt").read_text()
    for key, value in {"CARDS": "\n".join(cards), "SOURCES": sources, "DECISIONS": decisions, "SNAPSHOT": esc(plan["snapshot"]), "BASE": esc(plan["base"])}.items():
        template = template.replace("{{" + key + "}}", value)
    # A safe embedded snapshot makes a downloaded page readable without a server.
    template = template.replace("{{DATA}}", json.dumps(plan, ensure_ascii=False).replace("<", "\\u003c"))
    template = template.replace('<link rel="stylesheet" href="ds/koe/tokens.css">', '<style>' + (ROOT / "ds/koe/tokens.css").read_text() + '</style>')
    with tempfile.NamedTemporaryFile("w", dir=ROOT, prefix=".plan-html-", delete=False) as tmp:
        tmp.write(template)
    os.replace(tmp.name, ROOT / "Main.html")
    return template


def update(task_id, patch, revision=None):
    with (ROOT / ".plan.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        plan = load()
        original = next((t for t in plan["tasks"] if t["id"] == task_id), None)
        if original is None:
            raise ValueError("未知任务")
        if revision is not None and revision != original["revision"]:
            raise ValueError("其他对话已更新本批；请先复制尚未保存的输入，再刷新并合并。")
        task = copy.deepcopy(original)
        for key in ("owner", "status", "device", "evidence", "deviceEvidence"):
            if key in patch:
                if not isinstance(patch[key], str) or len(patch[key]) > 16000:
                    raise ValueError("字段无效或过长")
                task[key] = patch[key].strip()
        if task["status"] not in STATUSES or task["device"] not in DEVICES:
            raise ValueError("未知状态")
        if "steps" in patch:
            steps = patch["steps"]
            if not isinstance(steps, dict) or any(k not in {s["id"] for s in task["steps"]} or type(v) is not bool for k, v in steps.items()):
                raise ValueError("无效清单项")
            for step in task["steps"]:
                if step["id"] in steps:
                    step["done"] = steps[step["id"]]
        if task["status"] == "done" and not task["evidence"]:
            raise ValueError("标记代码已交付前，请填写 PR / 提交与检查证据。")
        if task["device"] != "pending" and not task["deviceEvidence"]:
            raise ValueError("请填写本次真机证据，或跳过 / 失败原因。")
        author = patch.get("author", task["owner"] or "未署名对话")
        comment = patch.get("comment", "")
        if not isinstance(author, str) or not isinstance(comment, str) or len(author) > 1000 or len(comment) > 16000:
            raise ValueError("留言无效或过长")
        changed = [k for k in ("owner", "status", "device", "evidence", "deviceEvidence", "steps") if task[k] != original[k]]
        if changed or comment.strip():
            stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
            if changed:
                task["notes"].append({"at": stamp, "author": author, "text": "更新：" + "、".join(changed), "kind": "change"})
            if comment.strip():
                task["notes"].append({"at": stamp, "author": author, "text": comment.strip(), "kind": "comment"})
            task["revision"] += 1
            plan["tasks"][plan["tasks"].index(original)] = task
            with tempfile.NamedTemporaryFile("w", dir=ROOT, prefix=".plan-", delete=False) as tmp:
                json.dump(plan, tmp, ensure_ascii=False, indent=2)
                tmp.write("\n")
                tmp.flush()
                os.fsync(tmp.fileno())
            os.replace(tmp.name, ROOT / "plan.json")
        render(plan)
        return task


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, status, content, mime="application/json"):
        data = content.encode()
        self.send_response(status)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def valid_host(self):
        return self.headers.get("Host") in {f"localhost:{self.server.server_port}", f"127.0.0.1:{self.server.server_port}"}

    def do_GET(self):
        if not self.valid_host():
            return self.respond(403, '{"error":"Invalid host"}')
        self.server.last_activity = time.monotonic()
        path = self.path.split("?", 1)[0]
        if path in ("/", "/Main.html"):
            self.respond(200, render(), "text/html")
        elif path == "/api/plan":
            self.respond(200, json.dumps(load(), ensure_ascii=False))
        elif path == "/ds/koe/tokens.css":
            self.respond(200, (ROOT / "ds/koe/tokens.css").read_text(), "text/css")
        else:
            self.respond(404, '{"error":"Not found"}')

    def do_POST(self):
        origin = self.headers.get("Origin")
        valid_origin = origin in {f"http://localhost:{self.server.server_port}", f"http://127.0.0.1:{self.server.server_port}"}
        if not self.valid_host() or not valid_origin or self.headers.get("X-Koe-Plan") != "1":
            return self.respond(403, '{"error":"Only same-origin edits are accepted"}')
        if self.path != "/api/task" or self.headers.get("Content-Type") != "application/json":
            return self.respond(400, '{"error":"Invalid request"}')
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 131072:
                raise ValueError("请求过长或为空")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body.get("revision"), int):
                raise ValueError("缺少版本号")
            result = update(body["id"], body["patch"], body["revision"])
            self.server.last_activity = time.monotonic()
            self.respond(200, json.dumps(result, ensure_ascii=False))
        except (ValueError, KeyError, TypeError) as err:
            self.respond(409, json.dumps({"error": str(err)}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("render")
    serve = commands.add_parser("serve")
    serve.add_argument("--port", type=int, default=8767)
    serve.add_argument("--idle-minutes", type=int, default=60)
    edit = commands.add_parser("update")
    edit.add_argument("id")
    edit.add_argument("--owner")
    edit.add_argument("--author")
    edit.add_argument("--status", choices=STATUSES)
    edit.add_argument("--device", choices=DEVICES)
    edit.add_argument("--evidence")
    edit.add_argument("--device-evidence", dest="deviceEvidence")
    edit.add_argument("--comment")
    edit.add_argument("--check", action="append", default=[])
    edit.add_argument("--uncheck", action="append", default=[])
    args = parser.parse_args()
    if args.command == "render":
        render()
        print(ROOT / "Main.html")
    elif args.command == "update":
        patch = {k: v for k, v in vars(args).items() if k in ("owner", "author", "status", "device", "evidence", "deviceEvidence", "comment") and v is not None}
        patch["steps"] = dict([(k, True) for k in args.check] + [(k, False) for k in args.uncheck])
        result = update(args.id, patch)
        print(json.dumps({"id": result["id"], "revision": result["revision"], "status": result["status"]}, ensure_ascii=False))
    else:
        if args.idle_minutes < 1:
            parser.error("idle-minutes must be positive")
        render()
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        server.last_activity = time.monotonic()
        def expire():
            while True:
                time.sleep(30)
                if time.monotonic() - server.last_activity > args.idle_minutes * 60:
                    server.shutdown()
                    return
        threading.Thread(target=expire, daemon=True).start()
        print(f"Android plan: http://localhost:{args.port} (idle timeout {args.idle_minutes}m)", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
