# CLI and MCP stdio

CLI and MCP stdio let a user or external agent read, search, query, create notes, and edit transcripts against the same durable Koe workspace that powers the native desktop app.

## Sub-features

- `mcp-tools-list` completes the JSON-RPC 2.0 handshake and exposes all 16 workspace and device MCP tools.
- `mcp-create-note` persists a titled text note through `tools/call` (`create_note`) and returns the new record identifier.
- `cli-status-readback` confirms the saved note from a second read-only CLI invocation (`status` and `doctor`).
- `cli-search-and-ask` returns cited BM25 search hits (`S1`) and local retrieval answers without calling cloud endpoints.
- `cli-edit-segment` updates transcript segment `S1` while retaining `originalText` provenance and confirms the edit via `search`.

## How to get to it (user POV)

- Run `./target/debug/koe --workspace "$TMP_WS" mcp-stdio` from a terminal or MCP client.
- Run `./target/debug/koe --workspace "$TMP_WS" status` and `./target/debug/koe --workspace "$TMP_WS" doctor` from a terminal.
- Run `./target/debug/koe --workspace "$TMP_WS" search "<query>"` and `./target/debug/koe --workspace "$TMP_WS" ask "<question>"` from a terminal.
- Run `./target/debug/koe --workspace "$TMP_WS" edit-segment --record "<id>" S1 "<text>"` from a terminal.

## Driving it with koe CLI

Preconditions:

- `./target/debug/koe` is built and `.agents/skills/verify-koe/scripts/doctor.sh` exits `0`.
- `TMP_WS` is an empty disposable directory shorter than 94 bytes.
- Ambient cloud API keys are unset.

- **MCP initialize, tool list, and create note.** Pipe JSON-RPC 2.0 messages into `mcp-stdio`. Run `printf '%s\n%s\n%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"verify-koe","version":"1.0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"Verify Koe Note","text":"Rust owns workspace persistence and cited search."}}}' | ./target/debug/koe --workspace "$TMP_WS" mcp-stdio | tee "$EVIDENCE_DIR/mcp_stdio.jsonl"`. Exit code `0` produces three JSON-RPC replies with `protocolVersion` `"2025-11-25"`, 16 tools in reply `2`, and `"isError":false` with the created record ID in reply `3`.
- **Readback via status.** Open the same workspace in a fresh process. Run `./target/debug/koe --workspace "$TMP_WS" status | tee "$EVIDENCE_DIR/cli_status.json"`. Exit code `0` prints snapshot `version` `2` containing one record titled `"Verify Koe Note"`.
- **Readback via doctor.** Inspect workspace and provider diagnostics. Run `./target/debug/koe --workspace "$TMP_WS" doctor | tee "$EVIDENCE_DIR/cli_doctor.json"`. Exit code `0` confirms clean workspace state without ambient cloud credentials.
- **Readback via search.** Query the created note text. Run `./target/debug/koe --workspace "$TMP_WS" search "workspace persistence" | tee "$EVIDENCE_DIR/cli_search.json"`. Exit code `0` returns a non-empty `sources` array citing `"segmentId":"S1"` on the created record ID.
- **Local retrieval ask.** Ask a question with no cloud provider configured. Run `./target/debug/koe --workspace "$TMP_WS" ask "workspace persistence" | tee "$EVIDENCE_DIR/cli_ask.json"`. Exit code `0` returns `"phase":"ready"` with the last assistant message in `"mode":"retrieval"` and cited local sources.
- **Edit transcript segment.** Update `S1` on the created record and confirm persistence via a readback search. Run `RECORD_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["records"][0]["id"])' "$EVIDENCE_DIR/cli_status.json")" && ./target/debug/koe --workspace "$TMP_WS" edit-segment --record "$RECORD_ID" S1 "Rust owns durable workspace persistence and cited search." | tee "$EVIDENCE_DIR/cli_edit_segment.json" && ./target/debug/koe --workspace "$TMP_WS" search "durable workspace persistence" | tee "$EVIDENCE_DIR/cli_search_edited.json"`. Exit code `0` sets `"isEdited":true` with the prior text in `"originalText"`, and the second search matches `"segmentId":"S1"` on `"$RECORD_ID"`.

## Gotchas

- Omitting `--workspace "$TMP_WS"` opens the user's real production container at `~/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace`.
- `mcp-stdio` rejects `tools/list` and `tools/call` with JSON-RPC error `-32600` until both `initialize` and `notifications/initialized` have been sent.
- A `TMP_WS` path of 94 bytes or longer disables local bridge socket resolution because `<workspace>/koe.sock` reaches the 103-byte `sun_path` limit.
- Opening the same workspace concurrently from two offline CLI processes fails with an exclusive-lock error rather than creating an empty library.
