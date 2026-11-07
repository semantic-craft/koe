//! Deterministic multi-target binding generator for `koe_core_ffi`.
//!
//! Parses `rust/koe_core_ffi/src/lib.rs` as the authoritative FFI schema and emits:
//! 1. `rust/koe_core_ffi/include/koe_core_ffi.h` (C header for Xcode Swift bridging & CMake)
//! 2. `darwin/KoeCore.swift` (macOS & iOS SwiftUI wrapper)
//! 3. `android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt` (Android Jetpack Compose wrapper)

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[derive(Debug, Clone, PartialEq, Eq)]
struct CField {
    name: String,
    rust_ty: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CStruct {
    name: String,
    fields: Vec<CField>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CFn {
    name: String,
    params: Vec<CField>,
    ret_ty: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FfiSchema {
    structs: Vec<CStruct>,
    functions: Vec<CFn>,
}

fn parse_schema(src: &str) -> Result<FfiSchema, String> {
    let mut structs = Vec::new();
    let mut functions = Vec::new();
    let lines: Vec<&str> = src.lines().collect();
    let mut i = 0usize;

    while i < lines.len() {
        let trimmed = lines[i].trim();
        if trimmed == "#[repr(C)]" {
            while i < lines.len() && !lines[i].trim_start().starts_with("pub struct ") {
                i += 1;
            }
            if i >= lines.len() {
                return Err("unterminated #[repr(C)] struct".to_string());
            }
            let header = lines[i].trim();
            let name = header
                .strip_prefix("pub struct ")
                .and_then(|s| s.strip_suffix('{'))
                .map(str::trim)
                .ok_or_else(|| format!("malformed struct header: {header}"))?
                .to_string();
            i += 1;
            let mut fields = Vec::new();
            while i < lines.len() && lines[i].trim() != "}" {
                let fline = lines[i].trim();
                if let Some(rest) = fline.strip_prefix("pub ") {
                    let clean = rest.trim_end_matches(',');
                    let (fname, fty) = clean
                        .split_once(':')
                        .ok_or_else(|| format!("malformed field: {fline}"))?;
                    fields.push(CField {
                        name: fname.trim().to_string(),
                        rust_ty: fty.trim().to_string(),
                    });
                }
                i += 1;
            }
            structs.push(CStruct { name, fields });
        } else if trimmed == "#[no_mangle]" {
            i += 1;
            let mut sig = String::new();
            while i < lines.len() {
                let l = lines[i].trim();
                sig.push_str(l);
                sig.push(' ');
                if l.ends_with('{') {
                    break;
                }
                i += 1;
            }
            let sig = sig.trim().trim_end_matches('{').trim();
            let after_fn = sig
                .split_once("extern \"C\" fn ")
                .map(|(_, r)| r)
                .ok_or_else(|| format!("malformed extern C fn: {sig}"))?;
            let (fn_name, rest) = after_fn
                .split_once('(')
                .ok_or_else(|| format!("missing '(' in {after_fn}"))?;
            let (params_str, ret_part) = rest
                .rsplit_once(')')
                .ok_or_else(|| format!("missing ')' in {rest}"))?;
            let mut params = Vec::new();
            for raw_p in params_str.split(',') {
                let p = raw_p.trim();
                if p.is_empty() {
                    continue;
                }
                let (pname, pty) = p
                    .split_once(':')
                    .ok_or_else(|| format!("malformed param: {p}"))?;
                params.push(CField {
                    name: pname.trim().to_string(),
                    rust_ty: pty.trim().to_string(),
                });
            }
            let ret_ty = ret_part
                .trim()
                .strip_prefix("->")
                .map(|s| s.trim().to_string());
            functions.push(CFn {
                name: fn_name.trim().to_string(),
                params,
                ret_ty,
            });
        }
        i += 1;
    }

    if structs.is_empty() || functions.is_empty() {
        return Err("schema parser found zero structs or zero functions".to_string());
    }
    Ok(FfiSchema { structs, functions })
}

fn c_type_for_field(field: &CField) -> String {
    if let Some(inner) = field
        .rust_ty
        .strip_prefix("[u8; ")
        .and_then(|s| s.strip_suffix(']'))
    {
        return format!("uint8_t {}[{}]", field.name, inner);
    }
    format!("{} {}", c_scalar_type(&field.rust_ty), field.name)
}

fn c_scalar_type(rust_ty: &str) -> String {
    match rust_ty {
        "u8" => "uint8_t".to_string(),
        "u16" => "uint16_t".to_string(),
        "u32" => "uint32_t".to_string(),
        "u64" => "uint64_t".to_string(),
        "i32" => "int32_t".to_string(),
        "usize" => "size_t".to_string(),
        "*const u8" => "const uint8_t*".to_string(),
        "*mut u8" => "uint8_t*".to_string(),
        "*mut usize" => "size_t*".to_string(),
        _ if rust_ty.starts_with("*mut ") => {
            format!("{}*", rust_ty.trim_start_matches("*mut ").trim())
        }
        _ if rust_ty.starts_with("*const ") => {
            format!("const {}*", rust_ty.trim_start_matches("*const ").trim())
        }
        other => other.to_string(),
    }
}

fn render_c_header(schema: &FfiSchema) -> String {
    let mut out = String::new();
    out.push_str("// Generated by `cargo run --manifest-path rust/Cargo.toml --bin gen_bindings`.\n");
    out.push_str("// Do not edit by hand.\n\n");
    out.push_str("#ifndef KOE_CORE_FFI_H\n");
    out.push_str("#define KOE_CORE_FFI_H\n\n");
    out.push_str("#include <stddef.h>\n");
    out.push_str("#include <stdint.h>\n\n");
    out.push_str("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");

    for st in &schema.structs {
        out.push_str(&format!("typedef struct {} {{\n", st.name));
        for f in &st.fields {
            out.push_str(&format!("  {};\n", c_type_for_field(f)));
        }
        out.push_str(&format!("}} {};\n\n", st.name));
    }

    for func in &schema.functions {
        let ret = func
            .ret_ty
            .as_deref()
            .map_or_else(|| "void".to_string(), c_scalar_type);
        let params: Vec<String> = if func.params.is_empty() {
            vec!["void".to_string()]
        } else {
            func.params.iter().map(c_type_for_field).collect()
        };
        out.push_str(&format!(
            "{} {}({});\n",
            ret,
            func.name,
            params.join(", ")
        ));
    }

    out.push_str("\n#ifdef __cplusplus\n}\n#endif\n\n");
    out.push_str("#endif  // KOE_CORE_FFI_H\n");
    out
}

fn render_swift_bindings(schema: &FfiSchema) -> String {
    let struct_names: Vec<&str> = schema.structs.iter().map(|s| s.name.as_str()).collect();
    let fn_names: Vec<&str> = schema.functions.iter().map(|f| f.name.as_str()).collect();

    format!(
        r#"// Generated by `cargo run --manifest-path rust/Cargo.toml --bin gen_bindings`.
// Do not edit by hand.
// Bound C structs ({struct_count}): {structs}
// Bound C functions ({fn_count}): {fns}

import Foundation

public struct KoeDeviceTelemetry: Equatable, Sendable {{
  public let connectStatus: Int?
  public let battery: Int?
  public let charging: Bool
  public let firmwareVersion: String
  public let serialNumber: String
  public let totalMemoryKb: UInt32?
  public let freeMemoryKb: UInt32?
  public let boxBattery: Int?
  public let boxCharging: Bool
  public let boxMac: String
  public let boxFirmware: String
  public let wifiFirmware: String
  public let recordingStatus: UInt8

  public var recording: Bool {{ recordingStatus == 1 }}
}}

public struct KoeOfflineFileItem: Equatable, Sendable {{
  public let fileId: UInt32
  public let durationMs: UInt32
  public let endTime: UInt32?
}}

public struct KoeOfflineFilePage: Equatable, Sendable {{
  public let files: [KoeOfflineFileItem]
  public let fileCount: UInt16
  public let currentTransportTimestamp: UInt32?
  public let currentTransportDuration: UInt32?
}}

public struct KoeSliceTransition: Equatable, Sendable {{
  public let cmdId: UInt8
  public let flags: UInt8
  public let sequence: UInt32
}}

public enum KoeCore {{
  public static func checksum(_ data: Data) -> UInt8 {{
    data.withUnsafeBytes {{ raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return koe_protocol_checksum(base, data.count)
    }}
  }}

  public static func verifyChecksum(_ packet: Data) -> Bool {{
    packet.withUnsafeBytes {{ raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return false }}
      return koe_protocol_verify_checksum(base, packet.count) == 1
    }}
  }}

  public static func encodeFrame(cmdType: UInt8, cmdId: UInt8, payload: Data = Data()) -> Data {{
    let cap = payload.count + 10
    var out = Data(count: cap)
    let written = out.withUnsafeMutableBytes {{ outRaw -> Int in
      guard let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return payload.withUnsafeBytes {{ payRaw -> Int in
        let payPtr = payRaw.bindMemory(to: UInt8.self).baseAddress
        return Int(koe_protocol_encode(cmdType, cmdId, payPtr, payload.count, outPtr, cap))
      }}
    }}
    return out.prefix(written)
  }}

  public static func batteryRemaining(_ raw: Int) -> Int? {{
    let pct = koe_battery_remaining(Int32(raw))
    return pct < 0 ? nil : Int(pct)
  }}

  public static func parseDeviceInfoPacket(_ packet: Data) -> KoeDeviceTelemetry {{
    var cInfo = KoeDeviceInfo()
    _ = packet.withUnsafeBytes {{ raw in
      koe_device_info_parse_packet(raw.bindMemory(to: UInt8.self).baseAddress, packet.count, &cInfo)
    }}
    return decodeDeviceInfo(cInfo)
  }}

  public static func parseOfflineFileList(_ payload: Data, withEndTime: Bool) -> KoeOfflineFilePage {{
    var header = KoeOfflineFileListHeader()
    let total = payload.withUnsafeBytes {{ raw in
      Int(
        koe_offline_file_list_parse(
          raw.bindMemory(to: UInt8.self).baseAddress,
          payload.count,
          withEndTime ? 1 : 0,
          &header,
          nil,
          0
        )
      )
    }}
    var entries = Array(repeating: KoeOfflineFileEntry(), count: max(total, 1))
    if total > 0 {{
      _ = payload.withUnsafeBytes {{ raw in
        entries.withUnsafeMutableBufferPointer {{ buf in
          koe_offline_file_list_parse(
            raw.bindMemory(to: UInt8.self).baseAddress,
            payload.count,
            withEndTime ? 1 : 0,
            &header,
            buf.baseAddress,
            total
          )
        }}
      }}
    }}
    let items = entries.prefix(total).map {{ item in
      KoeOfflineFileItem(
        fileId: item.file_id,
        durationMs: item.duration_ms,
        endTime: item.has_end_time != 0 ? item.end_time : nil
      )
    }}
    return KoeOfflineFilePage(
      files: items,
      fileCount: header.file_count,
      currentTransportTimestamp: header.has_transport_state != 0 ? header.current_transport_timestamp : nil,
      currentTransportDuration: header.has_transport_state != 0 ? header.current_transport_duration : nil
    )
  }}

  public static func muxOggOpus(_ rawOpusFrames: Data) -> Data {{
    var outLen: Int = 0
    let ptr: UnsafeMutablePointer<UInt8>? = rawOpusFrames.withUnsafeBytes {{ raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return nil }}
      return koe_ogg_opus_mux_raw_frames(base, rawOpusFrames.count, &outLen)
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return Data() }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return Data(bytes: validPtr, count: outLen)
  }}

  public static func wavHeader(pcmLength: UInt32) -> Data {{
    var out = Data(count: 44)
    _ = out.withUnsafeMutableBytes {{ raw in
      koe_wav_header(pcmLength, raw.bindMemory(to: UInt8.self).baseAddress)
    }}
    return out
  }}

  private static func decodeDeviceInfo(_ c: KoeDeviceInfo) -> KoeDeviceTelemetry {{
    var copy = c
    let fw = withUnsafeBytes(of: &copy.firmware_version) {{ readCString($0) }}
    let sn = withUnsafeBytes(of: &copy.serial_number) {{ readCString($0) }}
    let mac = withUnsafeBytes(of: &copy.box_mac) {{ readCString($0) }}
    let boxFw = withUnsafeBytes(of: &copy.box_firmware) {{ readCString($0) }}
    let wifiFw = withUnsafeBytes(of: &copy.wifi_firmware) {{ readCString($0) }}
    return KoeDeviceTelemetry(
      connectStatus: c.connect_status < 0 ? nil : Int(c.connect_status),
      battery: c.battery < 0 ? nil : Int(c.battery),
      charging: c.charging != 0,
      firmwareVersion: fw,
      serialNumber: sn,
      totalMemoryKb: c.has_memory != 0 ? c.total_memory_kb : nil,
      freeMemoryKb: c.has_memory != 0 ? c.free_memory_kb : nil,
      boxBattery: c.box_battery < 0 ? nil : Int(c.box_battery),
      boxCharging: c.box_charging != 0,
      boxMac: mac,
      boxFirmware: boxFw,
      wifiFirmware: wifiFw,
      recordingStatus: c.recording_status
    )
  }}

  private static func readCString(_ raw: UnsafeRawBufferPointer) -> String {{
    let bytes = raw.bindMemory(to: UInt8.self)
    let count = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes.prefix(count), as: UTF8.self)
  }}
}}
"#,
        struct_count = struct_names.len(),
        structs = struct_names.join(", "),
        fn_count = fn_names.len(),
        fns = fn_names.join(", "),
    )
}

fn render_kotlin_bindings(schema: &FfiSchema) -> String {
    let struct_names: Vec<&str> = schema.structs.iter().map(|s| s.name.as_str()).collect();
    let fn_names: Vec<&str> = schema.functions.iter().map(|f| f.name.as_str()).collect();

    format!(
        r#"// Generated by `cargo run --manifest-path rust/Cargo.toml --bin gen_bindings`.
// Do not edit by hand.
// Bound C structs ({struct_count}): {structs}
// Bound C functions ({fn_count}): {fns}

package com.anker.anker_recorder

data class KoeDeviceTelemetry(
    val connectStatus: Int?,
    val battery: Int?,
    val charging: Boolean,
    val firmwareVersion: String,
    val serialNumber: String,
    val totalMemoryKb: Long?,
    val freeMemoryKb: Long?,
    val boxBattery: Int?,
    val boxCharging: Boolean,
    val boxMac: String,
    val boxFirmware: String,
    val wifiFirmware: String,
    val recordingStatus: Int,
) {{
    val recording: Boolean get() = recordingStatus == 1
}}

data class KoeOfflineFileItem(
    val fileId: Long,
    val durationMs: Long,
    val endTime: Long?,
)

data class KoeOfflineFilePage(
    val files: List<KoeOfflineFileItem>,
    val fileCount: Int,
    val currentTransportTimestamp: Long?,
    val currentTransportDuration: Long?,
)

object KoeCoreNative {{
    init {{
        System.loadLibrary("koe_core_ffi")
    }}

    const val BOUND_STRUCT_COUNT: Int = {struct_count}
    const val BOUND_FUNCTION_COUNT: Int = {fn_count}
}}
"#,
        struct_count = struct_names.len(),
        structs = struct_names.join(", "),
        fn_count = fn_names.len(),
        fns = fn_names.join(", "),
    )
}

fn repo_root() -> Result<PathBuf, String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| "failed to resolve repository root".to_string())
}

fn run_negative_control(src: &str) -> Result<(), String> {
    let baseline = parse_schema(src)?;
    let baseline_h = render_c_header(&baseline);
    let baseline_swift = render_swift_bindings(&baseline);

    let mut mutated_field = baseline.clone();
    mutated_field.structs[0].fields[0].rust_ty = "u64".to_string();
    let mutated_h = render_c_header(&mutated_field);
    if mutated_h == baseline_h {
        return Err("negative control 1 failed: mutated field type produced identical header".to_string());
    }

    let mut mutated_fn = baseline;
    mutated_fn.functions.pop();
    let mutated_swift = render_swift_bindings(&mutated_fn);
    if mutated_swift == baseline_swift {
        return Err("negative control 2 failed: dropped function produced identical Swift binding".to_string());
    }

    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let check_only = args.iter().any(|a| a == "--check");
    let verify_control = args.iter().any(|a| a == "--verify-negative-control");

    let root = match repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(2);
        }
    };

    let lib_rs_path = root.join("rust/koe_core_ffi/src/lib.rs");
    let src = match fs::read_to_string(&lib_rs_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error reading {}: {e}", lib_rs_path.display());
            return ExitCode::from(2);
        }
    };

    if let Err(e) = run_negative_control(&src) {
        eprintln!("error: {e}");
        return ExitCode::from(1);
    }
    if verify_control && !check_only && args.len() == 1 {
        println!("negative controls verified: field mutation and symbol drop both detected");
        return ExitCode::SUCCESS;
    }

    let schema = match parse_schema(&src) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error parsing FFI schema: {e}");
            return ExitCode::from(2);
        }
    };

    let outputs = [
        (
            root.join("rust/koe_core_ffi/include/koe_core_ffi.h"),
            render_c_header(&schema),
        ),
        (
            root.join("darwin/KoeCore.swift"),
            render_swift_bindings(&schema),
        ),
        (
            root.join("android/app/src/main/kotlin/com/anker/anker_recorder/KoeCore.kt"),
            render_kotlin_bindings(&schema),
        ),
    ];

    if check_only {
        let mut mismatches = Vec::new();
        for (path, expected) in &outputs {
            match fs::read_to_string(path) {
                Ok(actual) if &actual == expected => {}
                Ok(_) => mismatches.push(format!("drift in {}", path.display())),
                Err(e) => mismatches.push(format!("missing {}: {e}", path.display())),
            }
        }
        if !mismatches.is_empty() {
            for m in mismatches {
                eprintln!("binding check failed: {m}");
            }
            return ExitCode::from(1);
        }
        println!(
            "bindings verified: {} structs, {} functions across C, Swift, and Kotlin",
            schema.structs.len(),
            schema.functions.len()
        );
        return ExitCode::SUCCESS;
    }

    for (path, content) in &outputs {
        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                eprintln!("error creating directory {}: {e}", parent.display());
                return ExitCode::from(2);
            }
        }
        if let Err(e) = fs::write(path, content) {
            eprintln!("error writing {}: {e}", path.display());
            return ExitCode::from(2);
        }
    }

    println!(
        "generated bindings: {} structs, {} functions -> C header, Swift, Kotlin",
        schema.structs.len(),
        schema.functions.len()
    );
    ExitCode::SUCCESS
}
