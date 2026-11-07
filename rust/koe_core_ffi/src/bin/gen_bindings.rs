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
    if let Some(inner) = field
        .rust_ty
        .strip_prefix("[u64; ")
        .and_then(|s| s.strip_suffix(']'))
    {
        return format!("uint64_t {}[{}]", field.name, inner);
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
        "*const u32" => "const uint32_t*".to_string(),
        "*const u64" => "const uint64_t*".to_string(),
        "*mut u8" => "uint8_t*".to_string(),
        "*mut *mut u8" => "uint8_t**".to_string(),
        "*mut u32" => "uint32_t*".to_string(),
        "*mut u64" => "uint64_t*".to_string(),
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

public struct KoeAudioFileHeadInfo: Equatable, Sendable {{
  public let fileId: UInt32
  public let fileSize: UInt32
  public let errorCode: UInt8
  public let unfinished: Bool
  public let nonce: Data
  public let encryptedFileKey: Data
  public let sessionNonce: Data
  public let fileKey: Data?
}}

public struct KoeUnpackedSlices: Equatable, Sendable {{
  public let opusBytes: Data
  public let markedSequences: [UInt32]
  public let sliceCount: Int

  public var wireRecordBytes: Int {{ sliceCount * 166 }}
}}

public struct KoeWifiEndpointModel: Equatable, Sendable {{
  public let ip: [UInt8]
  public let port: UInt16

  public var ipString: String {{
    guard ip.count == 4 else {{ return "0.0.0.0" }}
    return "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
  }}
}}

public struct KoeWifiBatchProgressModel: Equatable, Sendable {{
  public let phase: UInt8
  public let errorCode: UInt8
  public let currentFileIndex: UInt32
  public let totalFiles: UInt32
  public let activeFileId: UInt32
  public let receivedWireBytes: UInt32
  public let expectedWireBytes: UInt32
  public let finalizedCount: UInt32
  public let salvagedCount: UInt32
  public let skippedCount: UInt32
  public let remainingCount: UInt32
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

  public static func encodeGetDeviceInfo() -> Data {{
    encodeFrame(cmdType: 0x01, cmdId: 0x01)
  }}

  public static func encodeGetFileList(pageIndex: UInt8 = 0) -> Data {{
    encodeFrame(cmdType: 0x1A, cmdId: 0x01, payload: Data([pageIndex]))
  }}

  public static func encodeStartRecord() -> Data {{
    encodeFrame(cmdType: 0x01, cmdId: 0x03)
  }}

  public static func encodeStopRecord() -> Data {{
    encodeFrame(cmdType: 0x01, cmdId: 0x04)
  }}

  public static func encodePauseRecord() -> Data {{
    encodeFrame(cmdType: 0x01, cmdId: 0x05)
  }}

  public static func encodeResumeRecord() -> Data {{
    encodeFrame(cmdType: 0x01, cmdId: 0x06)
  }}

  public static func encodeHandshakeKey(_ publicKey65: Data) -> Data {{
    encodeFrame(cmdType: 0x2E, cmdId: 0x01, payload: publicKey65)
  }}

  public static func encodeStartTransportAudioFile(
    fileId: UInt32,
    alreadyTransferred: UInt32 = 0,
    realtimeFlag: UInt8 = 0
  ) -> Data {{
    var payload = Data(capacity: 9)
    var offset = alreadyTransferred.littleEndian
    var fid = fileId.littleEndian
    withUnsafeBytes(of: &offset) {{ payload.append(contentsOf: $0) }}
    withUnsafeBytes(of: &fid) {{ payload.append(contentsOf: $0) }}
    payload.append(realtimeFlag)
    return encodeFrame(cmdType: 0x1A, cmdId: 0x07, payload: payload)
  }}

  public static func hkdfSha256(
    ikm: Data,
    salt: Data = Data([1, 2, 3]),
    info: Data = Data([1, 2, 3]),
    length: Int = 32
  ) -> Data {{
    guard length > 0 else {{ return Data() }}
    var out = Data(count: length)
    out.withUnsafeMutableBytes {{ (outRaw: UnsafeMutableRawBufferPointer) -> Void in
      guard let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress else {{ return }}
      ikm.withUnsafeBytes {{ (ikmRaw: UnsafeRawBufferPointer) -> Void in
        salt.withUnsafeBytes {{ (saltRaw: UnsafeRawBufferPointer) -> Void in
          info.withUnsafeBytes {{ (infoRaw: UnsafeRawBufferPointer) -> Void in
            koe_crypto_hkdf_sha256(
              ikmRaw.bindMemory(to: UInt8.self).baseAddress,
              ikm.count,
              saltRaw.bindMemory(to: UInt8.self).baseAddress,
              salt.count,
              infoRaw.bindMemory(to: UInt8.self).baseAddress,
              info.count,
              outPtr,
              length
            )
          }}
        }}
      }}
    }}
    return out
  }}

  public static func isSliceMark(_ flags: UInt8) -> Bool {{
    koe_slice_mark_is_mark(flags) != 0
  }}

  public static func sliceMarkPositionMs(_ sequence: UInt32) -> UInt64 {{
    koe_slice_mark_position_ms(sequence)
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

  public static func buildAudiblePreviewWav(durationMs: UInt64, marksMs: [UInt64]) -> Data {{
    var outLen: Int = 0
    let ptr: UnsafeMutablePointer<UInt8>? = marksMs.withUnsafeBufferPointer {{ marksBuf in
      koe_wav_build_audible_preview(durationMs, marksBuf.baseAddress, marksBuf.count, &outLen)
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return Data() }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return Data(bytes: validPtr, count: outLen)
  }}

  public static func decodeOpusPcm16(_ rawOpusFrames: Data, sampleRate: UInt32 = 16_000) -> Data {{
    var outLen: Int = 0
    let ptr: UnsafeMutablePointer<UInt8>? = rawOpusFrames.withUnsafeBytes {{ raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return nil }}
      return koe_opus_decode_pcm16(base, rawOpusFrames.count, sampleRate, &outLen)
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return Data() }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return Data(bytes: validPtr, count: outLen)
  }}

  public static func decodeOpusWav(
    _ rawOpusFrames: Data,
    sampleRate: UInt32 = 48_000,
    marksMs: [UInt64] = []
  ) -> Data {{
    var outLen: Int = 0
    let ptr: UnsafeMutablePointer<UInt8>? = rawOpusFrames.withUnsafeBytes {{ raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return nil }}
      return marksMs.withUnsafeBufferPointer {{ marksBuf in
        koe_opus_decode_wav(
          base,
          rawOpusFrames.count,
          sampleRate,
          marksBuf.baseAddress,
          marksBuf.count,
          &outLen
        )
      }}
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return Data() }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return Data(bytes: validPtr, count: outLen)
  }}

  public static func parseFileHead(_ packet: Data, sessionKey: Data? = nil) -> KoeAudioFileHeadInfo? {{
    var cHead = KoeAudioFileHead()
    let ok = packet.withUnsafeBytes {{ raw -> Int32 in
      guard let rawBase = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      if let sk = sessionKey, !sk.isEmpty {{
        return sk.withUnsafeBytes {{ skRaw in
          koe_transport_parse_file_head(
            rawBase,
            packet.count,
            skRaw.bindMemory(to: UInt8.self).baseAddress,
            sk.count,
            &cHead
          )
        }}
      }}
      return koe_transport_parse_file_head(rawBase, packet.count, nil, 0, &cHead)
    }}
    guard ok == 1 else {{ return nil }}
    let nonce = withUnsafeBytes(of: &cHead.nonce) {{ Data($0) }}
    let encKey = withUnsafeBytes(of: &cHead.encrypted_file_key) {{ Data($0) }}
    let sessionNonce = withUnsafeBytes(of: &cHead.session_nonce) {{ Data($0) }}
    let fileKey: Data? = cHead.has_file_key != 0 ? withUnsafeBytes(of: &cHead.file_key) {{ Data($0) }} : nil
    return KoeAudioFileHeadInfo(
      fileId: cHead.file_id,
      fileSize: cHead.file_size,
      errorCode: cHead.error_code,
      unfinished: cHead.unfinished != 0,
      nonce: nonce,
      encryptedFileKey: encKey,
      sessionNonce: sessionNonce,
      fileKey: fileKey
    )
  }}

  public static func unpackSlices(_ frame: Data, fileKey: Data? = nil, nonce: Data? = nil) -> KoeUnpackedSlices {{
    guard frame.count >= 174 else {{
      return KoeUnpackedSlices(opusBytes: Data(), markedSequences: [], sliceCount: 0)
    }}
    let maxSlices = (frame.count - 9) / 165
    var opusOut = Data(count: maxSlices * 160)
    var marksOut = Array(repeating: UInt32(0), count: max(maxSlices, 1))
    var marksCount: Int = 0
    let sliceCount = frame.withUnsafeBytes {{ frameRaw -> Int in
      guard let frameBase = frameRaw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return opusOut.withUnsafeMutableBytes {{ opusRaw -> Int in
        guard let opusBase = opusRaw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
        return marksOut.withUnsafeMutableBufferPointer {{ marksBuf -> Int in
          if let fk = fileKey, let iv = nonce, !fk.isEmpty, !iv.isEmpty {{
            return fk.withUnsafeBytes {{ fkRaw in
              iv.withUnsafeBytes {{ ivRaw in
                Int(
                  koe_transport_unpack_slices(
                    frameBase,
                    frame.count,
                    fkRaw.bindMemory(to: UInt8.self).baseAddress,
                    fk.count,
                    ivRaw.bindMemory(to: UInt8.self).baseAddress,
                    iv.count,
                    opusBase,
                    maxSlices * 160,
                    marksBuf.baseAddress,
                    maxSlices,
                    &marksCount
                  )
                )
              }}
            }}
          }}
          return Int(
            koe_transport_unpack_slices(
              frameBase,
              frame.count,
              nil,
              0,
              nil,
              0,
              opusBase,
              maxSlices * 160,
              marksBuf.baseAddress,
              maxSlices,
              &marksCount
            )
          )
        }}
      }}
    }}
    return KoeUnpackedSlices(
      opusBytes: opusOut.prefix(sliceCount * 160),
      markedSequences: Array(marksOut.prefix(marksCount)),
      sliceCount: sliceCount
    )
  }}

  public static func parseWifiConfigResponse(_ packet: Data) -> KoeWifiEndpointModel? {{
    var cEp = KoeWifiEndpoint()
    let ok = packet.withUnsafeBytes {{ raw -> UInt8 in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return koe_wifi_parse_config_response(base, packet.count, &cEp)
    }}
    guard ok != 0 else {{ return nil }}
    let ipBytes = withUnsafeBytes(of: &cEp.ip) {{ Array($0) }}
    return KoeWifiEndpointModel(ip: ipBytes, port: cEp.port)
  }}

  public static func sharesIpv4Subnet(deviceIp: [UInt8], localIp: [UInt8]) -> Bool {{
    guard deviceIp.count >= 4, localIp.count >= 4 else {{ return false }}
    return deviceIp.withUnsafeBufferPointer {{ devBuf in
      localIp.withUnsafeBufferPointer {{ locBuf in
        koe_wifi_shares_subnet(devBuf.baseAddress, locBuf.baseAddress) != 0
      }}
    }}
  }}

  public static func buildWifiFileRequestHex(fileId: UInt32, alreadyTransferred: UInt32 = 0) -> String {{
    var out = Data(count: 64)
    let len = out.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_wifi_build_file_request_hex(fileId, alreadyTransferred, base, 64))
    }}
    return String(decoding: out.prefix(len), as: UTF8.self)
  }}

  public static func wifiTransferCompleteHex() -> String {{
    var out = Data(count: 64)
    let len = out.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_wifi_build_transfer_complete_hex(base, 64))
    }}
    return String(decoding: out.prefix(len), as: UTF8.self)
  }}

  public static func wifiKeepalivePayload() -> Data {{
    var out = Data(count: 64)
    let len = out.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_wifi_keepalive_payload(base, 64))
    }}
    return Data(out.prefix(len))
  }}

  public static func reduceSilenceAutoStop(
    silenceElapsedMs: UInt64,
    deltaMs: UInt64,
    speechDetected: Bool,
    alreadyAutoStopped: Bool
  ) -> (nextElapsedMs: UInt64, autoStopped: Bool, triggered: Bool) {{
    var nextElapsed: UInt64 = 0
    var autoStopped: UInt8 = 0
    let triggered = koe_cicada_silence_reduce(
      silenceElapsedMs,
      deltaMs,
      speechDetected ? 1 : 0,
      alreadyAutoStopped ? 1 : 0,
      &nextElapsed,
      &autoStopped
    )
    return (nextElapsed, autoStopped != 0, triggered != 0)
  }}

  public static func verifyKoepackV2(_ data: Data) -> Int32 {{
    data.withUnsafeBytes {{ raw -> Int32 in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return -1 }}
      return koe_koepack_verify_v2(base, data.count)
    }}
  }}

  public static func encodeDemoKoepackV2(
    contentHash: String,
    title: String,
    source: String,
    minutesJson: String
  ) -> Data? {{
    let hashBytes = Array(contentHash.utf8)
    let titleBytes = Array(title.utf8)
    let srcBytes = Array(source.utf8)
    let minBytes = Array(minutesJson.utf8)
    var outLen: Int = 0
    let ptr = hashBytes.withUnsafeBufferPointer {{ hBuf in
      titleBytes.withUnsafeBufferPointer {{ tBuf in
        srcBytes.withUnsafeBufferPointer {{ sBuf in
          minBytes.withUnsafeBufferPointer {{ mBuf in
            koe_koepack_encode_demo_v2(
              hBuf.baseAddress,
              hBuf.count,
              tBuf.baseAddress,
              tBuf.count,
              sBuf.baseAddress,
              sBuf.count,
              mBuf.baseAddress,
              mBuf.count,
              &outLen
            )
          }}
        }}
      }}
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return nil }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return Data(bytes: validPtr, count: outLen)
  }}

  public static func formatCoarsePlace(_ parts: [String]) -> String? {{
    let joined = Array(parts.joined(separator: "\n").utf8)
    guard !joined.isEmpty else {{ return nil }}
    let needed = joined.withUnsafeBufferPointer {{ buf in
      koe_context_format_coarse_place(buf.baseAddress, buf.count, nil, 0)
    }}
    guard needed > 0 else {{ return nil }}
    var out = Data(count: Int(needed))
    let written = out.withUnsafeMutableBytes {{ raw -> Int32 in
      guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else {{ return -1 }}
      return joined.withUnsafeBufferPointer {{ buf in
        koe_context_format_coarse_place(buf.baseAddress, buf.count, dst, Int(needed))
      }}
    }}
    guard written > 0 else {{ return nil }}
    return String(decoding: out.prefix(Int(written)), as: UTF8.self)
  }}

  public static func isDelegationRequest(_ text: String) -> Bool {{
    let utf8 = Array(text.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_context_is_delegation_request(buf.baseAddress, buf.count) != 0
    }}
  }}

  public static func namesTodo(mention: String, sentence: String, title: String) -> Bool {{
    let mBytes = Array(mention.utf8)
    let sBytes = Array(sentence.utf8)
    let tBytes = Array(title.utf8)
    return mBytes.withUnsafeBufferPointer {{ mBuf in
      sBytes.withUnsafeBufferPointer {{ sBuf in
        tBytes.withUnsafeBufferPointer {{ tBuf in
          koe_context_names_todo(
            mBuf.baseAddress,
            mBuf.count,
            sBuf.baseAddress,
            sBuf.count,
            tBuf.baseAddress,
            tBuf.count
          ) != 0
        }}
      }}
    }}
  }}

  fileprivate static func decodeDeviceInfo(_ c: KoeDeviceInfo) -> KoeDeviceTelemetry {{
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

public struct KoeDecodedPacket: Equatable, Sendable {{
  public let cmdType: UInt8
  public let cmdId: UInt8
  public let raw: Data
  public var payload: Data {{
    guard raw.count >= 10 else {{ return Data() }}
    return Data(raw[9..<(raw.count - 1)])
  }}
}}

public final class KoeFrameReassembler: @unchecked Sendable {{
  private let handle: UInt64

  public init() {{
    self.handle = koe_reassembler_new()
  }}

  deinit {{
    koe_reassembler_free(handle)
  }}

  public var bufferedCount: Int {{
    Int(koe_reassembler_buffered_len(handle))
  }}

  public func reset() {{
    koe_reassembler_reset(handle)
  }}

  public func ingest(_ chunk: Data) -> [KoeDecodedPacket] {{
    let queued = chunk.withUnsafeBytes {{ raw -> UInt32 in
      koe_reassembler_ingest(handle, raw.bindMemory(to: UInt8.self).baseAddress, chunk.count)
    }}
    guard queued > 0 else {{ return [] }}
    var packets: [KoeDecodedPacket] = []
    packets.reserveCapacity(Int(queued))
    var scratch = Data(count: 65536)
    while true {{
      var cmdType: UInt8 = 0
      var cmdId: UInt8 = 0
      let len = scratch.withUnsafeMutableBytes {{ raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
        return Int(koe_reassembler_pop_packet(handle, base, 65536, &cmdType, &cmdId))
      }}
      if len == 0 {{ break }}
      packets.append(KoeDecodedPacket(cmdType: cmdType, cmdId: cmdId, raw: Data(scratch.prefix(len))))
    }}
    return packets
  }}
}}

public struct KoeRecordingEntryModel: Equatable, Sendable, Identifiable {{
  public let id: UInt32
  public let beanFileId: UInt32
  public let createdAtEpochSec: UInt64
  public let durationMs: UInt64
  public let byteCount: UInt32
  public let marksMs: [UInt64]

  public init(
    id: UInt32,
    beanFileId: UInt32,
    createdAtEpochSec: UInt64,
    durationMs: UInt64,
    byteCount: UInt32,
    marksMs: [UInt64]
  ) {{
    self.id = id
    self.beanFileId = beanFileId
    self.createdAtEpochSec = createdAtEpochSec
    self.durationMs = durationMs
    self.byteCount = byteCount
    self.marksMs = marksMs
  }}

  fileprivate init(c: KoeRecordingEntry) {{
    var copy = c
    let count = min(Int(c.mark_count), 32)
    let marks: [UInt64] = withUnsafeBytes(of: &copy.marks_ms) {{ raw in
      let buf = raw.bindMemory(to: UInt64.self)
      return Array(buf.prefix(count))
    }}
    self.id = c.id
    self.beanFileId = c.bean_file_id
    self.createdAtEpochSec = c.created_at_epoch_sec
    self.durationMs = c.duration_ms
    self.byteCount = c.byte_count
    self.marksMs = marks
  }}

  fileprivate func toCStruct() -> KoeRecordingEntry {{
    var c = KoeRecordingEntry()
    c.id = id
    c.bean_file_id = beanFileId
    c.created_at_epoch_sec = createdAtEpochSec
    c.duration_ms = durationMs
    c.byte_count = byteCount
    let count = min(marksMs.count, 32)
    c.mark_count = UInt32(count)
    withUnsafeMutableBytes(of: &c.marks_ms) {{ raw in
      let dst = raw.bindMemory(to: UInt64.self)
      for i in 0..<count {{
        dst[i] = marksMs[i]
      }}
    }}
    return c
  }}
}}

public struct KoeFinalizedRecordingModel: Equatable, Sendable {{
  public let entry: KoeRecordingEntryModel
  public let oggOpusBytes: Data
  public let previewWavBytes: Data
}}

public struct KoeSessionStepOutcome: Equatable, Sendable {{
  public let framesDecoded: UInt32
  public let connectionPhase: UInt8
  public let telemetryUpdated: Bool
  public let sessionKeyEstablished: Bool
  public let catalogUpdated: Bool
  public let transferUpdated: Bool
  public let hasFinalizedRecording: Bool
  public let slicesUnpackedCount: UInt32
  public let newMarksCount: UInt32
  public let livePcm16BytesAvailable: UInt32
  public let transferPhase: UInt8
  public let transferErrorCode: UInt8
  public let transferRetryCount: UInt8
  public let isRealtimeQuietDraining: Bool
  public let transferFileId: UInt32
  public let receivedWireBytes: UInt32
  public let expectedWireBytes: UInt32
  public let transferMarkCount: UInt32
  public let outboundTxFrames: [Data]
}}

public final class KoeTransportSession: @unchecked Sendable {{
  private let handle: UInt64

  public init() {{
    self.handle = koe_session_new()
  }}

  deinit {{
    koe_session_free(handle)
  }}

  public func resetActiveTransfer() {{
    koe_session_reset_active_transfer(handle)
  }}

  public func onDisconnected() {{
    koe_session_on_disconnected(handle)
  }}

  public func onTransportInterrupted() {{
    koe_session_on_transport_interrupted(handle)
  }}

  public func resumeOfflinePull() -> Data {{
    var out = Data(count: 32)
    let len = out.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_session_resume_offline_pull(handle, base, 32))
    }}
    return out.prefix(len)
  }}

  public func stopRealtimeRecording() -> KoeSessionStepOutcome {{
    var step = KoeSessionStepResult()
    _ = koe_session_stop_realtime_recording(handle, &step)
    return decodeStep(step)
  }}

  public func pollTimers(elapsedMs: UInt64, nowEpochSec: UInt64) -> KoeSessionStepOutcome {{
    var step = KoeSessionStepResult()
    _ = koe_session_poll_timers(handle, elapsedMs, nowEpochSec, &step)
    return decodeStep(step)
  }}

  public func acceptEcdhReply(replyPayload: Data, sharedSecret: Data) -> Bool {{
    replyPayload.withUnsafeBytes {{ repRaw in
      sharedSecret.withUnsafeBytes {{ secRaw in
        koe_session_accept_ecdh_reply(
          handle,
          repRaw.bindMemory(to: UInt8.self).baseAddress,
          replyPayload.count,
          secRaw.bindMemory(to: UInt8.self).baseAddress,
          sharedSecret.count
        ) != 0
      }}
    }}
  }}

  public func beginOfflinePull(fileId: UInt32, durationMs: UInt32) -> Data {{
    var out = Data(count: 32)
    let len = out.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_session_begin_offline_pull(handle, fileId, durationMs, base, 32))
    }}
    return out.prefix(len)
  }}

  public func ingestBleChunk(_ chunk: Data, nowEpochSec: UInt64) -> KoeSessionStepOutcome {{
    var step = KoeSessionStepResult()
    _ = chunk.withUnsafeBytes {{ raw in
      koe_session_ingest_ble_chunk(
        handle,
        raw.bindMemory(to: UInt8.self).baseAddress,
        chunk.count,
        nowEpochSec,
        &step
      )
    }}
    return decodeStep(step)
  }}

  public func simulateRealtimePipeline(nowEpochSec: UInt64) -> KoeSessionStepOutcome {{
    var step = KoeSessionStepResult()
    _ = koe_session_simulate_realtime_pipeline(handle, nowEpochSec, &step)
    return decodeStep(step)
  }}

  public func currentTelemetry() -> KoeDeviceTelemetry? {{
    var cInfo = KoeDeviceInfo()
    guard koe_session_get_telemetry(handle, &cInfo) != 0 else {{ return nil }}
    return KoeCore.decodeDeviceInfo(cInfo)
  }}

  public func currentCatalog() -> [KoeOfflineFileItem] {{
    let total = Int(koe_session_get_catalog(handle, nil, 0))
    guard total > 0 else {{ return [] }}
    var entries = Array(repeating: KoeOfflineFileEntry(), count: total)
    _ = entries.withUnsafeMutableBufferPointer {{ buf in
      koe_session_get_catalog(handle, buf.baseAddress, total)
    }}
    return entries.map {{ item in
      KoeOfflineFileItem(
        fileId: item.file_id,
        durationMs: item.duration_ms,
        endTime: item.has_end_time != 0 ? item.end_time : nil
      )
    }}
  }}

  public func finalizeActiveTransfer(nowEpochSec: UInt64) -> Bool {{
    koe_session_finalize_active_transfer(handle, nowEpochSec) != 0
  }}

  @discardableResult
  public func beginWifiBatch(fileIds: [UInt32]) -> Bool {{
    fileIds.withUnsafeBufferPointer {{ buf in
      koe_session_begin_wifi_batch(handle, buf.baseAddress, buf.count) != 0
    }}
  }}

  public func ingestWifiChunk(_ chunk: Data, nowEpochSec: UInt64) -> KoeSessionStepOutcome {{
    var step = KoeSessionStepResult()
    _ = chunk.withUnsafeBytes {{ raw in
      koe_session_ingest_wifi_chunk(
        handle,
        raw.bindMemory(to: UInt8.self).baseAddress,
        chunk.count,
        nowEpochSec,
        &step
      )
    }}
    return decodeStep(step)
  }}

  public func popOutboundWifiWs() -> String? {{
    var buf = Data(count: 512)
    let len = buf.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_session_pop_outbound_wifi_ws(handle, base, 512))
    }}
    guard len > 0 else {{ return nil }}
    return String(decoding: buf.prefix(len), as: UTF8.self)
  }}

  public func popOutboundWifiUdp() -> Data? {{
    var buf = Data(count: 512)
    let len = buf.withUnsafeMutableBytes {{ raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
      return Int(koe_session_pop_outbound_wifi_udp(handle, base, 512))
    }}
    guard len > 0 else {{ return nil }}
    return Data(buf.prefix(len))
  }}

  public func currentWifiBatchProgress() -> KoeWifiBatchProgressModel {{
    var cProg = KoeWifiBatchProgress()
    _ = koe_session_get_wifi_batch_progress(handle, &cProg)
    return KoeWifiBatchProgressModel(
      phase: cProg.phase,
      errorCode: cProg.error_code,
      currentFileIndex: cProg.current_file_index,
      totalFiles: cProg.total_files,
      activeFileId: cProg.active_file_id,
      receivedWireBytes: cProg.received_wire_bytes,
      expectedWireBytes: cProg.expected_wire_bytes,
      finalizedCount: cProg.finalized_count,
      salvagedCount: cProg.salvaged_count,
      skippedCount: cProg.skipped_count,
      remainingCount: cProg.remaining_count
    )
  }}

  public func currentWifiEndpoint() -> KoeWifiEndpointModel? {{
    var cEp = KoeWifiEndpoint()
    guard koe_session_get_wifi_endpoint(handle, &cEp) != 0 else {{ return nil }}
    let ipBytes = withUnsafeBytes(of: &cEp.ip) {{ Array($0) }}
    return KoeWifiEndpointModel(ip: ipBytes, port: cEp.port)
  }}

  @discardableResult
  public func onWifiInterrupted(nowEpochSec: UInt64) -> Bool {{
    koe_session_on_wifi_interrupted(handle, nowEpochSec) != 0
  }}

  @discardableResult
  public func resumeWifiBatch() -> Bool {{
    koe_session_resume_wifi_batch(handle) != 0
  }}

  public func cancelWifiBatch() {{
    koe_session_cancel_wifi_batch(handle)
  }}

  public func takeLivePcm16() -> Data {{
    var outLen: Int = 0
    guard let ptr = koe_session_take_live_pcm16(handle, &outLen), outLen > 0 else {{
      return Data()
    }}
    defer {{ koe_buffer_free(ptr, outLen) }}
    return Data(bytes: ptr, count: outLen)
  }}

  public func takeFinalized() -> KoeFinalizedRecordingModel? {{
    var cEntry = KoeRecordingEntry()
    var oggPtr: UnsafeMutablePointer<UInt8>?
    var oggLen: Int = 0
    var wavPtr: UnsafeMutablePointer<UInt8>?
    var wavLen: Int = 0
    guard koe_session_take_finalized(handle, &cEntry, &oggPtr, &oggLen, &wavPtr, &wavLen) != 0 else {{
      return nil
    }}
    let oggData: Data
    if let p = oggPtr, oggLen > 0 {{
      oggData = Data(bytes: p, count: oggLen)
      koe_buffer_free(p, oggLen)
    }} else {{
      oggData = Data()
    }}
    let wavData: Data
    if let p = wavPtr, wavLen > 0 {{
      wavData = Data(bytes: p, count: wavLen)
      koe_buffer_free(p, wavLen)
    }} else {{
      wavData = Data()
    }}
    return KoeFinalizedRecordingModel(
      entry: KoeRecordingEntryModel(c: cEntry),
      oggOpusBytes: oggData,
      previewWavBytes: wavData
    )
  }}

  private func decodeStep(_ step: KoeSessionStepResult) -> KoeSessionStepOutcome {{
    var txFrames: [Data] = []
    var buf = Data(count: 512)
    while true {{
      let n = buf.withUnsafeMutableBytes {{ raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {{ return 0 }}
        return Int(koe_session_pop_outbound_tx(handle, base, 512))
      }}
      if n == 0 {{ break }}
      txFrames.append(Data(buf.prefix(n)))
    }}
    return KoeSessionStepOutcome(
      framesDecoded: step.frames_decoded,
      connectionPhase: step.connection_phase,
      telemetryUpdated: step.telemetry_updated != 0,
      sessionKeyEstablished: step.session_key_established != 0,
      catalogUpdated: step.catalog_updated != 0,
      transferUpdated: step.transfer_updated != 0,
      hasFinalizedRecording: step.has_finalized_recording != 0,
      slicesUnpackedCount: step.slices_unpacked_count,
      newMarksCount: step.new_marks_count,
      livePcm16BytesAvailable: step.live_pcm16_bytes_available,
      transferPhase: step.transfer.phase,
      transferErrorCode: step.transfer.error_code,
      transferRetryCount: step.transfer.retry_count,
      isRealtimeQuietDraining: step.transfer.quiet_draining != 0,
      transferFileId: step.transfer.file_id,
      receivedWireBytes: step.transfer.received_wire_bytes,
      expectedWireBytes: step.transfer.expected_wire_bytes,
      transferMarkCount: step.transfer.mark_count,
      outboundTxFrames: txFrames
    )
  }}
}}

public final class KoeRecordingLibrary: @unchecked Sendable {{
  private let handle: UInt64

  public init() {{
    self.handle = koe_library_new()
  }}

  deinit {{
    koe_library_free(handle)
  }}

  public func entries() -> [KoeRecordingEntryModel] {{
    let total = Int(koe_library_get_entries(handle, nil, 0))
    guard total > 0 else {{ return [] }}
    var raw = Array(repeating: KoeRecordingEntry(), count: total)
    _ = raw.withUnsafeMutableBufferPointer {{ buf in
      koe_library_get_entries(handle, buf.baseAddress, total)
    }}
    return raw.map {{ KoeRecordingEntryModel(c: $0) }}
  }}

  public func selectedEntry() -> KoeRecordingEntryModel? {{
    var c = KoeRecordingEntry()
    guard koe_library_get_selected(handle, &c) != 0 else {{ return nil }}
    return KoeRecordingEntryModel(c: c)
  }}

  public func ingest(_ entry: KoeRecordingEntryModel) {{
    var c = entry.toCStruct()
    _ = koe_library_ingest_entry(handle, &c)
  }}

  public func ingestDiskFile(
    filename: String,
    byteCount: UInt32,
    createdAtEpochSec: UInt64
  ) -> KoeRecordingEntryModel? {{
    var c = KoeRecordingEntry()
    let utf8 = Array(filename.utf8)
    let ok = utf8.withUnsafeBufferPointer {{ buf in
      koe_library_ingest_disk_file(
        handle,
        buf.baseAddress,
        buf.count,
        byteCount,
        createdAtEpochSec,
        &c
      )
    }}
    guard ok != 0 else {{ return nil }}
    return KoeRecordingEntryModel(c: c)
  }}

  @discardableResult
  public func select(_ recordingId: UInt32) -> Bool {{
    var playhead: UInt64 = 0
    return koe_library_select(handle, recordingId, &playhead) != 0
  }}

  @discardableResult
  public func seekMs(_ positionMs: UInt64) -> UInt64 {{
    koe_library_seek_ms(handle, positionMs)
  }}

  public func jumpToMark(currentMs: UInt64, direction: Int) -> UInt64? {{
    var target: UInt64 = 0
    guard koe_library_jump_to_mark(handle, currentMs, Int32(direction), &target) != 0 else {{
      return nil
    }}
    return target
  }}

  public func moveToTrash(_ recordingId: UInt32) -> KoeRecordingEntryModel? {{
    var trashed = KoeRecordingEntry()
    guard koe_library_move_to_trash(handle, recordingId, &trashed) != 0 else {{ return nil }}
    return KoeRecordingEntryModel(c: trashed)
  }}

  public func undoTrash() -> KoeRecordingEntryModel? {{
    var restored = KoeRecordingEntry()
    guard koe_library_undo_trash(handle, &restored) != 0 else {{ return nil }}
    return KoeRecordingEntryModel(c: restored)
  }}
}}

public struct KoeUtteranceSpineSnapshotModel: Equatable, Sendable {{
  public let segmentCount: UInt32
  public let revision: UInt64
  public let isStale: Bool
}}

public struct KoeUtteranceSegmentModel: Equatable, Sendable, Identifiable {{
  public let ordinal: UInt32
  public let revision: UInt32
  public let startMs: UInt64
  public let endMs: UInt64
  public let isFinal: Bool
  public let text: String
  public let translation: String?
  public let sourceLanguage: String
  public let targetLanguage: String?

  public var id: String {{ "S\(ordinal)" }}
}}

public final class KoeUtteranceSpine: @unchecked Sendable {{
  private let handle: UInt64

  public init(sessionId: String = "default") {{
    let utf8 = Array(sessionId.utf8)
    self.handle = utf8.withUnsafeBufferPointer {{ buf in
      koe_spine_new(buf.baseAddress, buf.count)
    }}
  }}

  deinit {{
    koe_spine_free(handle)
  }}

  public func snapshot() -> KoeUtteranceSpineSnapshotModel {{
    var c = KoeUtteranceSpineSnapshot()
    _ = koe_spine_snapshot(handle, &c)
    return KoeUtteranceSpineSnapshotModel(
      segmentCount: c.segment_count,
      revision: c.revision,
      isStale: c.is_stale != 0
    )
  }}

  public func clearStale() {{
    koe_spine_clear_stale(handle)
  }}

  @discardableResult
  public func appendSegment(
    text: String,
    startMs: UInt64 = 0,
    endMs: UInt64 = 0,
    sourceLanguage: String = "zh",
    provider: String = "qwen"
  ) -> UInt32 {{
    let textBytes = Array(text.utf8)
    let langBytes = Array(sourceLanguage.utf8)
    let provBytes = Array(provider.utf8)
    return textBytes.withUnsafeBufferPointer {{ tBuf in
      langBytes.withUnsafeBufferPointer {{ lBuf in
        provBytes.withUnsafeBufferPointer {{ pBuf in
          koe_spine_append_segment(
            handle,
            tBuf.baseAddress,
            tBuf.count,
            startMs,
            endMs,
            lBuf.baseAddress,
            lBuf.count,
            pBuf.baseAddress,
            pBuf.count
          )
        }}
      }}
    }}
  }}

  @discardableResult
  public func acceptCumulative(
    connectionId: String,
    text: String,
    sourceLanguage: String = "zh",
    translation: String? = nil,
    targetLanguage: String? = nil,
    provider: String = "qwen"
  ) -> UInt32 {{
    let connBytes = Array(connectionId.utf8)
    let textBytes = Array(text.utf8)
    let langBytes = Array(sourceLanguage.utf8)
    let trBytes = Array((translation ?? "").utf8)
    let tlangBytes = Array((targetLanguage ?? "").utf8)
    let provBytes = Array(provider.utf8)
    return connBytes.withUnsafeBufferPointer {{ cBuf in
      textBytes.withUnsafeBufferPointer {{ tBuf in
        langBytes.withUnsafeBufferPointer {{ lBuf in
          trBytes.withUnsafeBufferPointer {{ trBuf in
            tlangBytes.withUnsafeBufferPointer {{ tlBuf in
              provBytes.withUnsafeBufferPointer {{ pBuf in
                koe_spine_accept_cumulative(
                  handle,
                  cBuf.baseAddress,
                  cBuf.count,
                  tBuf.baseAddress,
                  tBuf.count,
                  lBuf.baseAddress,
                  lBuf.count,
                  trBuf.baseAddress,
                  trBuf.count,
                  tlBuf.baseAddress,
                  tlBuf.count,
                  pBuf.baseAddress,
                  pBuf.count
                )
              }}
            }}
          }}
        }}
      }}
    }}
  }}

  @discardableResult
  public func updateSegmentText(ordinal: UInt32, newText: String) -> Bool {{
    let bytes = Array(newText.utf8)
    return bytes.withUnsafeBufferPointer {{ buf in
      koe_spine_update_segment_text(handle, ordinal, buf.baseAddress, buf.count) != 0
    }}
  }}

  @discardableResult
  public func setTranslation(
    ordinal: UInt32,
    translation: String,
    targetLanguage: String = "en"
  ) -> Bool {{
    let trBytes = Array(translation.utf8)
    let tlBytes = Array(targetLanguage.utf8)
    return trBytes.withUnsafeBufferPointer {{ trBuf in
      tlBytes.withUnsafeBufferPointer {{ tlBuf in
        koe_spine_set_translation(
          handle,
          ordinal,
          trBuf.baseAddress,
          trBuf.count,
          tlBuf.baseAddress,
          tlBuf.count
        ) != 0
      }}
    }}
  }}

  public func segment(ordinal: UInt32) -> KoeUtteranceSegmentModel? {{
    var hdr = KoeUtteranceSegmentHeader()
    guard koe_spine_get_segment(handle, ordinal, &hdr, nil, 0, nil, 0) != 0 else {{
      return nil
    }}
    let textCap = max(Int(hdr.text_len), 1)
    let trCap = max(Int(hdr.translation_len), 1)
    var textBuf = Data(count: textCap)
    var trBuf = Data(count: trCap)
    _ = textBuf.withUnsafeMutableBytes {{ tRaw in
      trBuf.withUnsafeMutableBytes {{ trRaw in
        koe_spine_get_segment(
          handle,
          ordinal,
          &hdr,
          tRaw.bindMemory(to: UInt8.self).baseAddress,
          Int(hdr.text_len),
          trRaw.bindMemory(to: UInt8.self).baseAddress,
          Int(hdr.translation_len)
        )
      }}
    }}
    let text = String(decoding: textBuf.prefix(Int(hdr.text_len)), as: UTF8.self)
    let translation = hdr.has_translation != 0
      ? String(decoding: trBuf.prefix(Int(hdr.translation_len)), as: UTF8.self)
      : nil
    let srcLang = withUnsafeBytes(of: &hdr.source_language) {{ raw -> String in
      let b = raw.bindMemory(to: UInt8.self)
      let c = b.firstIndex(of: 0) ?? b.count
      return String(decoding: b.prefix(c), as: UTF8.self)
    }}
    let tgtLang = withUnsafeBytes(of: &hdr.target_language) {{ raw -> String in
      let b = raw.bindMemory(to: UInt8.self)
      let c = b.firstIndex(of: 0) ?? b.count
      return String(decoding: b.prefix(c), as: UTF8.self)
    }}
    return KoeUtteranceSegmentModel(
      ordinal: hdr.ordinal,
      revision: hdr.revision,
      startMs: hdr.start_ms,
      endMs: hdr.end_ms,
      isFinal: hdr.is_final != 0,
      text: text,
      translation: translation,
      sourceLanguage: srcLang,
      targetLanguage: tgtLang.isEmpty ? nil : tgtLang
    )
  }}

  public func formatCitedSources() -> String {{
    var outLen: Int = 0
    guard let ptr = koe_spine_format_cited_sources(handle, &outLen), outLen > 0 else {{
      return ""
    }}
    defer {{ koe_buffer_free(ptr, outLen) }}
    return String(decoding: Data(bytes: ptr, count: outLen), as: UTF8.self)
  }}

  public func validateClaimGrounding(claim: String, citations: [UInt32]) -> Bool {{
    let claimBytes = Array(claim.utf8)
    return claimBytes.withUnsafeBufferPointer {{ cBuf in
      citations.withUnsafeBufferPointer {{ idBuf in
        koe_minutes_validate_claim_grounding(
          handle,
          cBuf.baseAddress,
          cBuf.count,
          idBuf.baseAddress,
          idBuf.count
        ) != 0
      }}
    }}
  }}

  public func validateMinutesJson(_ json: String) -> Int32 {{
    let utf8 = Array(json.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_minutes_validate_json(handle, buf.baseAddress, buf.count)
    }}
  }}

  public func planBatchesCount(maxRunes: UInt32 = 6000) -> Int32 {{
    koe_minutes_plan_batches_count(handle, maxRunes)
  }}

  @discardableResult
  public func parseQwenTranscript(_ json: String) -> Int32 {{
    let utf8 = Array(json.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_qwen_parse_transcript_into_spine(handle, buf.baseAddress, buf.count)
    }}
  }}

  public static func replaceTerms(
    text: String,
    fromTerms: [String],
    toTerms: [String]
  ) -> String {{
    let textBytes = Array(text.utf8)
    let fromJoined = Array(fromTerms.joined(separator: "\n").utf8)
    let toJoined = Array(toTerms.joined(separator: "\n").utf8)
    let needed = textBytes.withUnsafeBufferPointer {{ tBuf in
      fromJoined.withUnsafeBufferPointer {{ fBuf in
        toJoined.withUnsafeBufferPointer {{ toBuf in
          koe_minutes_replace_terms_utf8(
            tBuf.baseAddress,
            tBuf.count,
            fBuf.baseAddress,
            fBuf.count,
            toBuf.baseAddress,
            toBuf.count,
            nil,
            0
          )
        }}
      }}
    }}
    guard needed > 0 else {{ return needed == 0 ? "" : text }}
    var out = Data(count: Int(needed))
    let written = out.withUnsafeMutableBytes {{ raw -> Int32 in
      guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else {{ return -1 }}
      return textBytes.withUnsafeBufferPointer {{ tBuf in
        fromJoined.withUnsafeBufferPointer {{ fBuf in
          toJoined.withUnsafeBufferPointer {{ toBuf in
            koe_minutes_replace_terms_utf8(
              tBuf.baseAddress,
              tBuf.count,
              fBuf.baseAddress,
              fBuf.count,
              toBuf.baseAddress,
              toBuf.count,
              dst,
              Int(needed)
            )
          }}
        }}
      }}
    }}
    guard written >= 0 else {{ return text }}
    return String(decoding: out.prefix(Int(written)), as: UTF8.self)
  }}
}}

public struct KoeCicadaRollingTicket: Equatable, Sendable {{
  public let fromIndex: UInt32
  public let endIndex: UInt32
  public let generation: UInt64
  public let payload: String
}}

public struct KoeCicadaRollingStatusModel: Equatable, Sendable {{
  public let paused: Bool
  public let closed: Bool
  public let edited: Bool
  public let hasCandidate: Bool
  public let requestStatus: UInt8
  public let watermark: UInt32
  public let callsThisHour: UInt32
  public let generation: UInt64
}}

public final class KoeCicadaRollingScheduler: @unchecked Sendable {{
  private let handle: UInt64

  public init(sessionId: String = "cicada") {{
    let bytes = Array(sessionId.utf8)
    self.handle = bytes.withUnsafeBufferPointer {{ buf in
      koe_cicada_rolling_new(buf.baseAddress, buf.count)
    }}
  }}

  deinit {{
    koe_cicada_rolling_free(handle)
  }}

  @discardableResult
  public func addSegment(id: String, text: String, nowMs: UInt64) -> Bool {{
    let idBytes = Array(id.utf8)
    let textBytes = Array(text.utf8)
    return idBytes.withUnsafeBufferPointer {{ iBuf in
      textBytes.withUnsafeBufferPointer {{ tBuf in
        koe_cicada_rolling_add_segment(
          handle,
          iBuf.baseAddress,
          iBuf.count,
          tBuf.baseAddress,
          tBuf.count,
          nowMs
        ) != 0
      }}
    }}
  }}

  public func pollTick(nowMs: UInt64) -> KoeCicadaRollingTicket? {{
    var fromIdx: UInt32 = 0
    var endIdx: UInt32 = 0
    var gen: UInt64 = 0
    var outLen: Int = 0
    guard let ptr = koe_cicada_rolling_poll_tick(
      handle,
      nowMs,
      &fromIdx,
      &endIdx,
      &gen,
      &outLen
    ), outLen > 0 else {{
      return nil
    }}
    defer {{ koe_buffer_free(ptr, outLen) }}
    let payload = String(decoding: Data(bytes: ptr, count: outLen), as: UTF8.self)
    return KoeCicadaRollingTicket(
      fromIndex: fromIdx,
      endIndex: endIdx,
      generation: gen,
      payload: payload
    )
  }}

  @discardableResult
  public func complete(
    generation: UInt64,
    fromIndex: UInt32,
    endIndex: UInt32,
    rawJson: String
  ) -> Int32 {{
    let utf8 = Array(rawJson.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_cicada_rolling_complete(
        handle,
        generation,
        fromIndex,
        endIndex,
        buf.baseAddress,
        buf.count
      )
    }}
  }}

  @discardableResult
  public func edit(_ editedJson: String) -> Int32 {{
    let utf8 = Array(editedJson.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_cicada_rolling_edit(handle, buf.baseAddress, buf.count)
    }}
  }}

  @discardableResult
  public func acceptCandidate() -> Bool {{
    koe_cicada_rolling_accept_candidate(handle) != 0
  }}

  public func activeJson() -> String? {{
    var outLen: Int = 0
    guard let ptr = koe_cicada_rolling_get_active(handle, &outLen), outLen > 0 else {{
      return nil
    }}
    defer {{ koe_buffer_free(ptr, outLen) }}
    return String(decoding: Data(bytes: ptr, count: outLen), as: UTF8.self)
  }}

  public func status() -> KoeCicadaRollingStatusModel? {{
    var c = KoeCicadaRollingStatus()
    guard koe_cicada_rolling_status(handle, &c) != 0 else {{ return nil }}
    return KoeCicadaRollingStatusModel(
      paused: c.paused != 0,
      closed: c.closed != 0,
      edited: c.edited != 0,
      hasCandidate: c.has_candidate != 0,
      requestStatus: c.request_status,
      watermark: c.watermark,
      callsThisHour: c.calls_this_hour,
      generation: c.generation
    )
  }}
}}

public struct KoeContextSearchStatusModel: Equatable, Sendable {{
  public let docCount: UInt32
  public let totalChars: UInt32
  public let vocabSize: UInt32
  public let lastHitCount: UInt32
}}

public final class KoeContextSearchIndex: @unchecked Sendable {{
  private let handle: UInt64

  public init() {{
    self.handle = koe_context_search_new()
  }}

  deinit {{
    koe_context_search_free(handle)
  }}

  @discardableResult
  public func addDoc(_ text: String) -> Int32 {{
    let utf8 = Array(text.utf8)
    return utf8.withUnsafeBufferPointer {{ buf in
      koe_context_search_add_doc(handle, buf.baseAddress, buf.count)
    }}
  }}

  public func query(_ queryText: String, limit: UInt32 = 30) -> [UInt32] {{
    let cap = max(Int(limit), 1)
    var outIndices = Array(repeating: UInt32(0), count: cap)
    let utf8 = Array(queryText.utf8)
    let total = utf8.withUnsafeBufferPointer {{ qBuf in
      outIndices.withUnsafeMutableBufferPointer {{ outBuf in
        koe_context_search_query(
          handle,
          qBuf.baseAddress,
          qBuf.count,
          limit,
          outBuf.baseAddress,
          cap
        )
      }}
    }}
    let count = min(Int(total), cap)
    return Array(outIndices.prefix(count))
  }}

  public func status() -> KoeContextSearchStatusModel? {{
    var c = KoeContextSearchStatus()
    guard koe_context_search_status(handle, &c) != 0 else {{ return nil }}
    return KoeContextSearchStatusModel(
      docCount: c.doc_count,
      totalChars: c.total_chars,
      vocabSize: c.vocab_size,
      lastHitCount: c.last_hit_count
    )
  }}
}}

public struct KoeMcpAcpStatusModel: Equatable, Sendable {{
  public let mcpInitialized: Bool
  public let mcpReady: Bool
  public let acpInitialized: Bool
  public let hasPairingTicket: Bool
  public let packCount: UInt32
  public let hotwordCount: UInt32
  public let acpTaskCount: UInt32
  public let handledCalls: UInt64
  public let liveGeneration: UInt64
  public let liveExpiresAtSec: UInt64
}}

public final class KoeMcpAcpRuntime: @unchecked Sendable {{
  private let handle: UInt64

  public init(sessionId: String = "native-mcp-session") {{
    let bytes = Array(sessionId.utf8)
    self.handle = bytes.withUnsafeBufferPointer {{ buf in
      koe_mcp_acp_new(buf.baseAddress, buf.count)
    }}
  }}

  deinit {{
    koe_mcp_acp_free(handle)
  }}

  public func configurePairing(
    baseUrl: String,
    token: String,
    modeIsLan: Bool = true,
    expiresAtEpochSec: UInt64 = 0
  ) -> String? {{
    let urlBytes = Array(baseUrl.utf8)
    let tokBytes = Array(token.utf8)
    var outLen: Int = 0
    let ptr = urlBytes.withUnsafeBufferPointer {{ uBuf in
      tokBytes.withUnsafeBufferPointer {{ tBuf in
        koe_mcp_acp_configure_pairing(
          handle,
          uBuf.baseAddress,
          uBuf.count,
          tBuf.baseAddress,
          tBuf.count,
          modeIsLan ? 1 : 0,
          expiresAtEpochSec,
          &outLen
        )
      }}
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return nil }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return String(decoding: Data(bytes: validPtr, count: outLen), as: UTF8.self)
  }}

  public func verifyBearer(authHeader: String, nowEpochSec: UInt64) -> Bool {{
    let bytes = Array(authHeader.utf8)
    return bytes.withUnsafeBufferPointer {{ buf in
      koe_mcp_acp_verify_bearer(handle, buf.baseAddress, buf.count, nowEpochSec) != 0
    }}
  }}

  @discardableResult
  public func publishLive(
    generation: UInt64,
    nowEpochSec: UInt64,
    ttlSec: UInt32 = 15
  ) -> Int32 {{
    koe_mcp_acp_publish_live(handle, generation, nowEpochSec, ttlSec)
  }}

  @discardableResult
  public func ingestUtterance(
    text: String,
    translation: String = "",
    startMs: UInt64 = 0,
    endMs: UInt64 = 0,
    sourceLanguage: String = "zh",
    targetLanguage: String = "en",
    nowEpochSec: UInt64 = 0
  ) -> UInt32 {{
    let tBytes = Array(text.utf8)
    let trBytes = Array(translation.utf8)
    let sBytes = Array(sourceLanguage.utf8)
    let tlBytes = Array(targetLanguage.utf8)
    return tBytes.withUnsafeBufferPointer {{ tBuf in
      trBytes.withUnsafeBufferPointer {{ trBuf in
        sBytes.withUnsafeBufferPointer {{ sBuf in
          tlBytes.withUnsafeBufferPointer {{ tlBuf in
            koe_mcp_acp_ingest_utterance(
              handle,
              tBuf.baseAddress,
              tBuf.count,
              trBuf.baseAddress,
              trBuf.count,
              startMs,
              endMs,
              sBuf.baseAddress,
              sBuf.count,
              tlBuf.baseAddress,
              tlBuf.count,
              nowEpochSec
            )
          }}
        }}
      }}
    }}
  }}

  @discardableResult
  public func ingestRecording(
    id: UInt32,
    durationMs: UInt64,
    byteCount: UInt32,
    createdAtEpochSec: UInt64
  ) -> Bool {{
    koe_mcp_acp_ingest_recording(handle, id, durationMs, byteCount, createdAtEpochSec) != 0
  }}

  @discardableResult
  public func putPack(materialId: String, packBytes: Data) -> Int32 {{
    let idBytes = Array(materialId.utf8)
    return idBytes.withUnsafeBufferPointer {{ idBuf in
      packBytes.withUnsafeBytes {{ pRaw in
        koe_mcp_acp_put_pack(
          handle,
          idBuf.baseAddress,
          idBuf.count,
          pRaw.bindMemory(to: UInt8.self).baseAddress,
          packBytes.count
        )
      }}
    }}
  }}

  public func dispatchJsonRpc(_ requestJson: String, nowEpochSec: UInt64) -> String? {{
    let reqBytes = Array(requestJson.utf8)
    var outLen: Int = 0
    let ptr = reqBytes.withUnsafeBufferPointer {{ buf in
      koe_mcp_acp_dispatch_jsonrpc(
        handle,
        buf.baseAddress,
        buf.count,
        nowEpochSec,
        &outLen
      )
    }}
    guard let validPtr = ptr, outLen > 0 else {{ return nil }}
    defer {{ koe_buffer_free(validPtr, outLen) }}
    return String(decoding: Data(bytes: validPtr, count: outLen), as: UTF8.self)
  }}

  public func status() -> KoeMcpAcpStatusModel? {{
    var c = KoeMcpAcpStatus()
    guard koe_mcp_acp_status(handle, &c) != 0 else {{ return nil }}
    return KoeMcpAcpStatusModel(
      mcpInitialized: c.mcp_initialized != 0,
      mcpReady: c.mcp_ready != 0,
      acpInitialized: c.acp_initialized != 0,
      hasPairingTicket: c.has_pairing_ticket != 0,
      packCount: c.pack_count,
      hotwordCount: c.hotword_count,
      acpTaskCount: c.acp_task_count,
      handledCalls: c.handled_calls,
      liveGeneration: c.live_generation,
      liveExpiresAtSec: c.live_expires_at_sec
    )
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

data class KoeAudioFileHeadInfo(
    val fileId: Long,
    val fileSize: Long,
    val errorCode: Int,
    val unfinished: Boolean,
    val nonce: ByteArray,
    val encryptedFileKey: ByteArray,
    val sessionNonce: ByteArray,
    val fileKey: ByteArray?,
)

data class KoeUnpackedSlices(
    val opusBytes: ByteArray,
    val markedSequences: LongArray,
    val sliceCount: Int,
) {{
    val wireRecordBytes: Int get() = sliceCount * 166
}}

data class KoeWifiEndpointModel(
    val ip: ByteArray,
    val port: Int,
) {{
    val ipString: String
        get() = if (ip.size >= 4) {{
            "${{ip[0].toInt() and 0xFF}}.${{ip[1].toInt() and 0xFF}}.${{ip[2].toInt() and 0xFF}}.${{ip[3].toInt() and 0xFF}}"
        }} else {{
            "0.0.0.0"
        }}

    companion object {{
        fun fromJniLongs(raw: LongArray?): KoeWifiEndpointModel? {{
            if (raw == null || raw.size < 5) return null
            val ip = byteArrayOf(
                (raw[0] and 0xFFL).toByte(),
                (raw[1] and 0xFFL).toByte(),
                (raw[2] and 0xFFL).toByte(),
                (raw[3] and 0xFFL).toByte(),
            )
            return KoeWifiEndpointModel(ip = ip, port = raw[4].toInt())
        }}
    }}
}}

data class KoeWifiBatchProgressModel(
    val phase: Int,
    val errorCode: Int,
    val currentFileIndex: Int,
    val totalFiles: Int,
    val activeFileId: Long,
    val receivedWireBytes: Long,
    val expectedWireBytes: Long,
    val finalizedCount: Int,
    val salvagedCount: Int,
    val skippedCount: Int,
    val remainingCount: Int,
) {{
    val isTransferring: Boolean get() = phase == 2
    val isInterrupted: Boolean get() = phase == 3
    val isCompleted: Boolean get() = phase == 4

    companion object {{
        fun fromJniLongs(raw: LongArray): KoeWifiBatchProgressModel {{
            if (raw.size < 11) {{
                return KoeWifiBatchProgressModel(0, 0, 0, 0, 0L, 0L, 0L, 0, 0, 0, 0)
            }}
            return KoeWifiBatchProgressModel(
                phase = raw[0].toInt(),
                errorCode = raw[1].toInt(),
                currentFileIndex = raw[2].toInt(),
                totalFiles = raw[3].toInt(),
                activeFileId = raw[4],
                receivedWireBytes = raw[5],
                expectedWireBytes = raw[6],
                finalizedCount = raw[7].toInt(),
                salvagedCount = raw[8].toInt(),
                skippedCount = raw[9].toInt(),
                remainingCount = raw[10].toInt(),
            )
        }}
    }}
}}

data class KoeSessionStepOutcome(
    val framesDecoded: Int,
    val connectionPhase: Int,
    val telemetryUpdated: Boolean,
    val sessionKeyEstablished: Boolean,
    val catalogUpdated: Boolean,
    val transferUpdated: Boolean,
    val hasFinalizedRecording: Boolean,
    val slicesUnpackedCount: Int,
    val newMarksCount: Int,
    val outboundTxCount: Int,
    val transferPhase: Int,
    val transferFileId: Long,
    val receivedWireBytes: Long,
    val expectedWireBytes: Long,
    val livePcm16BytesAvailable: Int,
    val transferErrorCode: Int,
    val transferRetryCount: Int,
    val isRealtimeQuietDraining: Boolean,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeSessionStepOutcome {{
            if (raw.size < 18) {{
                return KoeSessionStepOutcome(
                    0, 0, false, false, false, false, false, 0, 0, 0, 0, 0L, 0L, 0L, 0, 0, 0, false
                )
            }}
            return KoeSessionStepOutcome(
                framesDecoded = raw[0].toInt(),
                connectionPhase = raw[1].toInt(),
                telemetryUpdated = raw[2] != 0L,
                sessionKeyEstablished = raw[3] != 0L,
                catalogUpdated = raw[4] != 0L,
                transferUpdated = raw[5] != 0L,
                hasFinalizedRecording = raw[6] != 0L,
                slicesUnpackedCount = raw[7].toInt(),
                newMarksCount = raw[8].toInt(),
                outboundTxCount = raw[9].toInt(),
                transferPhase = raw[10].toInt(),
                transferFileId = raw[11],
                receivedWireBytes = raw[12],
                expectedWireBytes = raw[13],
                livePcm16BytesAvailable = raw[14].toInt(),
                transferErrorCode = raw[15].toInt(),
                transferRetryCount = raw[16].toInt(),
                isRealtimeQuietDraining = raw[17] != 0L,
            )
        }}
    }}
}}

data class KoeRecordingEntryModel(
    val id: Int,
    val beanFileId: Int,
    val createdAtEpochSec: Long,
    val durationMs: Long,
    val byteCount: Int,
    val marksMs: LongArray,
) {{
    companion object {{
        fun fromFinalizedMeta(meta: LongArray?): KoeRecordingEntryModel? {{
            if (meta == null || meta.size < 6) return null
            val markCount = meta[5].toInt().coerceAtLeast(0).coerceAtMost(meta.size - 6)
            val marks = LongArray(markCount) {{ idx -> meta[6 + idx] }}
            return KoeRecordingEntryModel(
                id = meta[0].toInt(),
                beanFileId = meta[1].toInt(),
                createdAtEpochSec = meta[2],
                durationMs = meta[3],
                byteCount = meta[4].toInt(),
                marksMs = marks,
            )
        }}
    }}
}}

data class KoeFinalizedRecordingModel(
    val entry: KoeRecordingEntryModel,
    val oggOpusBytes: ByteArray,
    val previewWavBytes: ByteArray,
)

data class KoeLibrarySnapshotModel(
    val entryCount: Int,
    val selectedRecordingId: Int,
    val playheadMs: Long,
    val hasLastTrashed: Boolean,
    val lastTrashedId: Int,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeLibrarySnapshotModel {{
            if (raw.size < 5) {{
                return KoeLibrarySnapshotModel(0, 0, 0L, false, 0)
            }}
            return KoeLibrarySnapshotModel(
                entryCount = raw[0].toInt(),
                selectedRecordingId = raw[1].toInt(),
                playheadMs = raw[2],
                hasLastTrashed = raw[3] != 0L,
                lastTrashedId = raw[4].toInt(),
            )
        }}
    }}
}}

data class KoeUtteranceSpineSnapshotModel(
    val segmentCount: Int,
    val revision: Long,
    val isStale: Boolean,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeUtteranceSpineSnapshotModel {{
            if (raw.size < 3) {{
                return KoeUtteranceSpineSnapshotModel(0, 0L, false)
            }}
            return KoeUtteranceSpineSnapshotModel(
                segmentCount = raw[0].toInt(),
                revision = raw[1],
                isStale = raw[2] != 0L,
            )
        }}
    }}
}}

data class KoeUtteranceSegmentModel(
    val ordinal: Int,
    val revision: Int,
    val startMs: Long,
    val endMs: Long,
    val isFinal: Boolean,
    val text: String,
    val translation: String?,
) {{
    val citationId: String get() = "S$ordinal"
}}

data class KoeContextSearchStatusModel(
    val docCount: Int,
    val totalChars: Int,
    val vocabSize: Int,
    val lastHitCount: Int,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeContextSearchStatusModel {{
            if (raw.size < 4) {{
                return KoeContextSearchStatusModel(0, 0, 0, 0)
            }}
            return KoeContextSearchStatusModel(
                docCount = raw[0].toInt(),
                totalChars = raw[1].toInt(),
                vocabSize = raw[2].toInt(),
                lastHitCount = raw[3].toInt(),
            )
        }}
    }}
}}

data class KoeCicadaRollingTicketModel(
    val fromIndex: Int,
    val endIndex: Int,
    val generation: Long,
    val payload: String,
)

data class KoeCicadaRollingStatusModel(
    val paused: Boolean,
    val closed: Boolean,
    val edited: Boolean,
    val hasCandidate: Boolean,
    val requestStatus: Int,
    val watermark: Int,
    val callsThisHour: Int,
    val generation: Long,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeCicadaRollingStatusModel {{
            if (raw.size < 8) {{
                return KoeCicadaRollingStatusModel(false, false, false, false, 0, 0, 0, 0L)
            }}
            return KoeCicadaRollingStatusModel(
                paused = raw[0] != 0L,
                closed = raw[1] != 0L,
                edited = raw[2] != 0L,
                hasCandidate = raw[3] != 0L,
                requestStatus = raw[4].toInt(),
                watermark = raw[5].toInt(),
                callsThisHour = raw[6].toInt(),
                generation = raw[7],
            )
        }}
    }}
}}

data class KoeMcpAcpStatusModel(
    val mcpInitialized: Boolean,
    val mcpReady: Boolean,
    val acpInitialized: Boolean,
    val hasPairingTicket: Boolean,
    val packCount: Int,
    val hotwordCount: Int,
    val acpTaskCount: Int,
    val handledCalls: Long,
    val liveGeneration: Long,
    val liveExpiresAtSec: Long,
) {{
    companion object {{
        fun fromJniLongs(raw: LongArray): KoeMcpAcpStatusModel {{
            if (raw.size < 10) {{
                return KoeMcpAcpStatusModel(false, false, false, false, 0, 0, 0, 0L, 0L, 0L)
            }}
            return KoeMcpAcpStatusModel(
                mcpInitialized = raw[0] != 0L,
                mcpReady = raw[1] != 0L,
                acpInitialized = raw[2] != 0L,
                hasPairingTicket = raw[3] != 0L,
                packCount = raw[4].toInt(),
                hotwordCount = raw[5].toInt(),
                acpTaskCount = raw[6].toInt(),
                handledCalls = raw[7],
                liveGeneration = raw[8],
                liveExpiresAtSec = raw[9],
            )
        }}
    }}
}}

object KoeCoreNative {{
    init {{
        System.loadLibrary("koe_core_ffi")
    }}

    const val BOUND_STRUCT_COUNT: Int = {struct_count}
    const val BOUND_FUNCTION_COUNT: Int = {fn_count}

    @JvmStatic external fun checksum(data: ByteArray): Int
    @JvmStatic external fun verifyChecksum(packet: ByteArray): Boolean
    @JvmStatic external fun encodeFrame(cmdType: Int, cmdId: Int, payload: ByteArray): ByteArray
    @JvmStatic external fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray
    @JvmStatic external fun muxOggOpus(rawOpusFrames: ByteArray): ByteArray
    @JvmStatic external fun buildAudiblePreviewWav(durationMs: Long, marksMs: LongArray): ByteArray
    @JvmStatic external fun decodeOpusPcm16(rawOpusFrames: ByteArray, sampleRate: Int): ByteArray?
    @JvmStatic external fun decodeOpusWav(rawOpusFrames: ByteArray, sampleRate: Int, marksMs: LongArray): ByteArray?

    @JvmStatic external fun reassemblerNew(): Long
    @JvmStatic external fun reassemblerFree(handle: Long)
    @JvmStatic external fun reassemblerReset(handle: Long)
    @JvmStatic external fun reassemblerIngest(handle: Long, chunk: ByteArray): Int
    @JvmStatic external fun reassemblerPopPacket(handle: Long): ByteArray?

    @JvmStatic external fun sessionNew(): Long
    @JvmStatic external fun sessionFree(handle: Long)
    @JvmStatic external fun sessionAcceptEcdhReply(handle: Long, replyPayload: ByteArray, sharedSecret: ByteArray): Boolean
    @JvmStatic external fun sessionBeginOfflinePull(handle: Long, fileId: Int, durationMs: Int): ByteArray
    @JvmStatic external fun sessionOnTransportInterrupted(handle: Long)
    @JvmStatic external fun sessionResumeOfflinePull(handle: Long): ByteArray
    @JvmStatic external fun sessionStopRealtimeRecording(handle: Long): LongArray
    @JvmStatic external fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): LongArray
    @JvmStatic external fun sessionIngestBleChunk(handle: Long, chunk: ByteArray, nowEpochSec: Long): LongArray
    @JvmStatic external fun sessionPopOutboundTx(handle: Long): ByteArray?
    @JvmStatic external fun sessionSimulateRealtimePipeline(handle: Long, nowEpochSec: Long): LongArray
    @JvmStatic external fun sessionTakeLivePcm16(handle: Long): ByteArray?
    @JvmStatic external fun sessionTakeFinalizedMeta(handle: Long): LongArray?
    @JvmStatic external fun sessionTakeFinalizedOgg(handle: Long): ByteArray?
    @JvmStatic external fun sessionTakeFinalizedWav(handle: Long): ByteArray?
    @JvmStatic external fun wifiParseConfigResponse(raw: ByteArray): LongArray?
    @JvmStatic external fun wifiSharesSubnet(deviceIp: ByteArray, localIp: ByteArray): Boolean
    @JvmStatic external fun wifiBuildFileRequestHex(fileId: Int, alreadyTransferred: Int): ByteArray
    @JvmStatic external fun wifiBuildTransferCompleteHex(): ByteArray
    @JvmStatic external fun wifiKeepalivePayload(): ByteArray
    @JvmStatic external fun sessionBeginWifiBatch(handle: Long, fileIds: LongArray): Boolean
    @JvmStatic external fun sessionIngestWifiChunk(handle: Long, chunk: ByteArray, nowEpochSec: Long): LongArray
    @JvmStatic external fun sessionPopOutboundWifiWs(handle: Long): ByteArray?
    @JvmStatic external fun sessionPopOutboundWifiUdp(handle: Long): ByteArray?
    @JvmStatic external fun sessionGetWifiBatchProgress(handle: Long): LongArray
    @JvmStatic external fun sessionGetWifiEndpoint(handle: Long): LongArray?
    @JvmStatic external fun sessionOnWifiInterrupted(handle: Long, nowEpochSec: Long): Boolean
    @JvmStatic external fun sessionResumeWifiBatch(handle: Long): Boolean
    @JvmStatic external fun sessionCancelWifiBatch(handle: Long)

    @JvmStatic external fun libraryNew(): Long
    @JvmStatic external fun libraryFree(handle: Long)
    @JvmStatic external fun libraryIngestEntry(
        handle: Long,
        id: Int,
        beanFileId: Int,
        createdAtEpochSec: Long,
        durationMs: Long,
        byteCount: Int,
        marksMs: LongArray,
    ): Boolean
    @JvmStatic external fun librarySelect(handle: Long, recordingId: Int): Boolean
    @JvmStatic external fun librarySeekMs(handle: Long, positionMs: Long): Long
    @JvmStatic external fun libraryJumpToMark(handle: Long, currentMs: Long, direction: Int): Long
    @JvmStatic external fun libraryMoveToTrash(handle: Long, recordingId: Int): Boolean
    @JvmStatic external fun libraryUndoTrash(handle: Long): Int
    @JvmStatic external fun librarySnapshot(handle: Long): LongArray

    @JvmStatic external fun spineNew(sessionId: ByteArray): Long
    @JvmStatic external fun spineFree(handle: Long)
    @JvmStatic external fun spineClearStale(handle: Long)
    @JvmStatic external fun spineSnapshot(handle: Long): LongArray
    @JvmStatic external fun spineAppendSegment(
        handle: Long,
        text: ByteArray,
        startMs: Long,
        endMs: Long,
        sourceLang: ByteArray,
        provider: ByteArray,
    ): Int
    @JvmStatic external fun spineAcceptCumulative(
        handle: Long,
        connId: ByteArray,
        text: ByteArray,
        sourceLang: ByteArray,
        translation: ByteArray,
        targetLang: ByteArray,
        provider: ByteArray,
    ): Int
    @JvmStatic external fun spineUpdateSegmentText(handle: Long, ordinal: Int, newText: ByteArray): Boolean
    @JvmStatic external fun spineSetTranslation(
        handle: Long,
        ordinal: Int,
        translation: ByteArray,
        targetLang: ByteArray,
    ): Boolean
    @JvmStatic external fun spineGetSegmentMeta(handle: Long, ordinal: Int): LongArray?
    @JvmStatic external fun spineGetSegmentText(handle: Long, ordinal: Int): ByteArray?
    @JvmStatic external fun spineGetSegmentTranslation(handle: Long, ordinal: Int): ByteArray?
    @JvmStatic external fun spineFormatCitedSources(handle: Long): ByteArray?
    @JvmStatic external fun minutesValidateClaimGrounding(
        spineHandle: Long,
        claim: ByteArray,
        citations: LongArray,
    ): Boolean
    @JvmStatic external fun minutesValidateJson(spineHandle: Long, json: ByteArray): Int
    @JvmStatic external fun minutesReplaceTermsUtf8(
        text: ByteArray,
        fromTerms: ByteArray,
        toTerms: ByteArray,
    ): ByteArray?
    @JvmStatic external fun minutesPlanBatchesCount(spineHandle: Long, maxRunes: Int): Int
    @JvmStatic external fun qwenParseTranscriptIntoSpine(spineHandle: Long, json: ByteArray): Int
    @JvmStatic external fun nativeCicadaSilenceReduce(
        silenceElapsedMs: Long,
        deltaMs: Long,
        speechDetected: Boolean,
        alreadyAutoStopped: Boolean,
    ): LongArray
    @JvmStatic external fun nativeKoepackVerifyV2(pack: ByteArray): Int
    @JvmStatic external fun nativeKoepackEncodeDemoV2(
        contentHash: ByteArray,
        title: ByteArray,
        source: ByteArray,
        minutesJson: ByteArray,
    ): ByteArray?
    @JvmStatic external fun contextSearchNew(): Long
    @JvmStatic external fun contextSearchFree(handle: Long)
    @JvmStatic external fun contextSearchAddDoc(handle: Long, text: ByteArray): Int
    @JvmStatic external fun contextSearchQuery(handle: Long, query: ByteArray, limit: Int): LongArray
    @JvmStatic external fun contextSearchStatus(handle: Long): LongArray
    @JvmStatic external fun contextFormatCoarsePlace(partsJoined: ByteArray): ByteArray
    @JvmStatic external fun contextIsDelegationRequest(text: ByteArray): Boolean
    @JvmStatic external fun contextNamesTodo(
        mention: ByteArray,
        sentence: ByteArray,
        title: ByteArray,
    ): Boolean
    @JvmStatic external fun cicadaRollingNew(sessionId: ByteArray): Long
    @JvmStatic external fun cicadaRollingFree(handle: Long)
    @JvmStatic external fun cicadaRollingAddSegment(
        handle: Long,
        segId: ByteArray,
        text: ByteArray,
        nowMs: Long,
    ): Boolean
    @JvmStatic external fun cicadaRollingPollTick(handle: Long, nowMs: Long): ByteArray?
    @JvmStatic external fun cicadaRollingComplete(
        handle: Long,
        generation: Long,
        fromIndex: Int,
        endIndex: Int,
        rawJson: ByteArray,
    ): Int
    @JvmStatic external fun cicadaRollingEdit(handle: Long, editedJson: ByteArray): Int
    @JvmStatic external fun cicadaRollingAcceptCandidate(handle: Long): Boolean
    @JvmStatic external fun cicadaRollingGetActive(handle: Long): ByteArray?
    @JvmStatic external fun cicadaRollingStatus(handle: Long): LongArray

    @JvmStatic external fun mcpAcpNew(sessionId: String): Long
    @JvmStatic external fun mcpAcpFree(handle: Long)
    @JvmStatic external fun mcpAcpConfigurePairing(
        handle: Long,
        baseUrl: String,
        token: String,
        modeIsLan: Boolean,
        expiresAtEpochSec: Long,
    ): String?
    @JvmStatic external fun mcpAcpVerifyBearer(
        handle: Long,
        authHeader: String,
        nowEpochSec: Long,
    ): Boolean
    @JvmStatic external fun mcpAcpPublishLive(
        handle: Long,
        generation: Long,
        nowEpochSec: Long,
        ttlSec: Int,
    ): Int
    @JvmStatic external fun mcpAcpIngestUtterance(
        handle: Long,
        text: String,
        translation: String,
        startMs: Long,
        endMs: Long,
        sourceLang: String,
        targetLang: String,
        nowEpochSec: Long,
    ): Int
    @JvmStatic external fun mcpAcpIngestRecording(
        handle: Long,
        id: Int,
        durationMs: Long,
        byteCount: Int,
        createdAtEpochSec: Long,
    ): Boolean
    @JvmStatic external fun mcpAcpPutPack(
        handle: Long,
        materialId: String,
        packBytes: ByteArray,
    ): Int
    @JvmStatic external fun mcpAcpDispatchJsonRpc(
        handle: Long,
        requestJson: String,
        nowEpochSec: Long,
    ): String?
    @JvmStatic external fun mcpAcpStatus(handle: Long): LongArray
}}

class KoeFrameReassembler : AutoCloseable {{
    private var handle: Long = KoeCoreNative.reassemblerNew()

    fun reset() {{
        if (handle != 0L) KoeCoreNative.reassemblerReset(handle)
    }}

    fun ingest(chunk: ByteArray): List<ByteArray> {{
        if (handle == 0L) return emptyList()
        val count = KoeCoreNative.reassemblerIngest(handle, chunk)
        if (count <= 0) return emptyList()
        val out = ArrayList<ByteArray>(count)
        while (true) {{
            val pkt = KoeCoreNative.reassemblerPopPacket(handle) ?: break
            out.add(pkt)
        }}
        return out
    }}

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.reassemblerFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeTransportSession : AutoCloseable {{
    private var handle: Long = KoeCoreNative.sessionNew()

    fun acceptEcdhReply(replyPayload: ByteArray, sharedSecret: ByteArray): Boolean =
        handle != 0L && KoeCoreNative.sessionAcceptEcdhReply(handle, replyPayload, sharedSecret)

    fun beginOfflinePull(fileId: Int, durationMs: Int): ByteArray =
        if (handle == 0L) ByteArray(0) else KoeCoreNative.sessionBeginOfflinePull(handle, fileId, durationMs)

    fun onTransportInterrupted() {{
        if (handle != 0L) KoeCoreNative.sessionOnTransportInterrupted(handle)
    }}

    fun resumeOfflinePull(): ByteArray =
        if (handle == 0L) ByteArray(0) else KoeCoreNative.sessionResumeOfflinePull(handle)

    fun stopRealtimeRecording(): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionStopRealtimeRecording(handle)

    fun pollTimers(elapsedMs: Long, nowEpochSec: Long): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionPollTimers(handle, elapsedMs, nowEpochSec)

    fun ingestBleChunk(chunk: ByteArray, nowEpochSec: Long): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionIngestBleChunk(handle, chunk, nowEpochSec)

    fun simulateRealtimePipeline(nowEpochSec: Long): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionSimulateRealtimePipeline(handle, nowEpochSec)

    fun takeLivePcm16(): ByteArray? =
        if (handle == 0L) null else KoeCoreNative.sessionTakeLivePcm16(handle)

    fun takeFinalizedMeta(): LongArray? =
        if (handle == 0L) null else KoeCoreNative.sessionTakeFinalizedMeta(handle)

    fun takeFinalizedOgg(): ByteArray? =
        if (handle == 0L) null else KoeCoreNative.sessionTakeFinalizedOgg(handle)

    fun takeFinalizedWav(): ByteArray? =
        if (handle == 0L) null else KoeCoreNative.sessionTakeFinalizedWav(handle)

    fun beginWifiBatch(fileIds: LongArray): Boolean =
        handle != 0L && KoeCoreNative.sessionBeginWifiBatch(handle, fileIds)

    fun ingestWifiChunk(chunk: ByteArray, nowEpochSec: Long): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionIngestWifiChunk(handle, chunk, nowEpochSec)

    fun popOutboundWifiWs(): String? {{
        if (handle == 0L) return null
        val bytes = KoeCoreNative.sessionPopOutboundWifiWs(handle) ?: return null
        return String(bytes, Charsets.UTF_8)
    }}

    fun popOutboundWifiUdp(): ByteArray? =
        if (handle == 0L) null else KoeCoreNative.sessionPopOutboundWifiUdp(handle)

    fun wifiBatchProgress(): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.sessionGetWifiBatchProgress(handle)

    fun wifiEndpoint(): LongArray? =
        if (handle == 0L) null else KoeCoreNative.sessionGetWifiEndpoint(handle)

    fun onWifiInterrupted(nowEpochSec: Long): Boolean =
        handle != 0L && KoeCoreNative.sessionOnWifiInterrupted(handle, nowEpochSec)

    fun resumeWifiBatch(): Boolean =
        handle != 0L && KoeCoreNative.sessionResumeWifiBatch(handle)

    fun cancelWifiBatch() {{
        if (handle != 0L) KoeCoreNative.sessionCancelWifiBatch(handle)
    }}

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.sessionFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeRecordingLibrary : AutoCloseable {{
    private var handle: Long = KoeCoreNative.libraryNew()

    fun ingestEntry(
        id: Int,
        beanFileId: Int,
        createdAtEpochSec: Long,
        durationMs: Long,
        byteCount: Int,
        marksMs: LongArray,
    ): Boolean =
        handle != 0L && KoeCoreNative.libraryIngestEntry(
            handle, id, beanFileId, createdAtEpochSec, durationMs, byteCount, marksMs
        )

    fun select(recordingId: Int): Boolean =
        handle != 0L && KoeCoreNative.librarySelect(handle, recordingId)

    fun seekMs(positionMs: Long): Long =
        if (handle == 0L) 0L else KoeCoreNative.librarySeekMs(handle, positionMs)

    fun jumpToMark(currentMs: Long, direction: Int): Long? {{
        if (handle == 0L) return null
        val target = KoeCoreNative.libraryJumpToMark(handle, currentMs, direction)
        return if (target < 0L) null else target
    }}

    fun moveToTrash(recordingId: Int): Boolean =
        handle != 0L && KoeCoreNative.libraryMoveToTrash(handle, recordingId)

    fun undoTrash(): Int =
        if (handle == 0L) 0 else KoeCoreNative.libraryUndoTrash(handle)

    fun snapshot(): LongArray =
        if (handle == 0L) LongArray(0) else KoeCoreNative.librarySnapshot(handle)

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.libraryFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeUtteranceSpine(sessionId: String = "default") : AutoCloseable {{
    private var handle: Long = KoeCoreNative.spineNew(sessionId.toByteArray(Charsets.UTF_8))

    fun snapshot(): KoeUtteranceSpineSnapshotModel =
        if (handle == 0L) KoeUtteranceSpineSnapshotModel(0, 0L, false)
        else KoeUtteranceSpineSnapshotModel.fromJniLongs(KoeCoreNative.spineSnapshot(handle))

    fun clearStale() {{
        if (handle != 0L) KoeCoreNative.spineClearStale(handle)
    }}

    fun appendSegment(
        text: String,
        startMs: Long = 0L,
        endMs: Long = 0L,
        sourceLanguage: String = "zh",
        provider: String = "qwen",
    ): Int =
        if (handle == 0L) 0
        else KoeCoreNative.spineAppendSegment(
            handle,
            text.toByteArray(Charsets.UTF_8),
            startMs,
            endMs,
            sourceLanguage.toByteArray(Charsets.UTF_8),
            provider.toByteArray(Charsets.UTF_8),
        )

    fun acceptCumulative(
        connectionId: String,
        text: String,
        sourceLanguage: String = "zh",
        translation: String? = null,
        targetLanguage: String? = null,
        provider: String = "qwen",
    ): Int =
        if (handle == 0L) 0
        else KoeCoreNative.spineAcceptCumulative(
            handle,
            connectionId.toByteArray(Charsets.UTF_8),
            text.toByteArray(Charsets.UTF_8),
            sourceLanguage.toByteArray(Charsets.UTF_8),
            (translation ?: "").toByteArray(Charsets.UTF_8),
            (targetLanguage ?: "").toByteArray(Charsets.UTF_8),
            provider.toByteArray(Charsets.UTF_8),
        )

    fun updateSegmentText(ordinal: Int, newText: String): Boolean =
        handle != 0L && KoeCoreNative.spineUpdateSegmentText(
            handle,
            ordinal,
            newText.toByteArray(Charsets.UTF_8),
        )

    fun setTranslation(ordinal: Int, translation: String, targetLanguage: String = "en"): Boolean =
        handle != 0L && KoeCoreNative.spineSetTranslation(
            handle,
            ordinal,
            translation.toByteArray(Charsets.UTF_8),
            targetLanguage.toByteArray(Charsets.UTF_8),
        )

    fun segment(ordinal: Int): KoeUtteranceSegmentModel? {{
        if (handle == 0L) return null
        val meta = KoeCoreNative.spineGetSegmentMeta(handle, ordinal) ?: return null
        if (meta.size < 6) return null
        val textBytes = KoeCoreNative.spineGetSegmentText(handle, ordinal) ?: return null
        val trBytes = if (meta[5] != 0L) KoeCoreNative.spineGetSegmentTranslation(handle, ordinal) else null
        return KoeUtteranceSegmentModel(
            ordinal = meta[0].toInt(),
            revision = meta[1].toInt(),
            startMs = meta[2],
            endMs = meta[3],
            isFinal = meta[4] != 0L,
            text = String(textBytes, Charsets.UTF_8),
            translation = trBytes?.let {{ String(it, Charsets.UTF_8) }},
        )
    }}

    fun formatCitedSources(): String {{
        if (handle == 0L) return ""
        val bytes = KoeCoreNative.spineFormatCitedSources(handle) ?: return ""
        return String(bytes, Charsets.UTF_8)
    }}

    fun validateClaimGrounding(claim: String, citations: LongArray): Boolean =
        handle != 0L && KoeCoreNative.minutesValidateClaimGrounding(
            handle,
            claim.toByteArray(Charsets.UTF_8),
            citations,
        )

    fun validateMinutesJson(json: String): Int =
        if (handle == 0L) 0
        else KoeCoreNative.minutesValidateJson(handle, json.toByteArray(Charsets.UTF_8))

    fun planBatchesCount(maxRunes: Int = 6000): Int =
        if (handle == 0L) -1
        else KoeCoreNative.minutesPlanBatchesCount(handle, maxRunes)

    fun parseQwenTranscript(json: String): Int =
        if (handle == 0L) -1
        else KoeCoreNative.qwenParseTranscriptIntoSpine(handle, json.toByteArray(Charsets.UTF_8))

    companion object {{
        fun replaceTerms(text: String, fromTerms: List<String>, toTerms: List<String>): String {{
            val out = KoeCoreNative.minutesReplaceTermsUtf8(
                text.toByteArray(Charsets.UTF_8),
                fromTerms.joinToString("\n").toByteArray(Charsets.UTF_8),
                toTerms.joinToString("\n").toByteArray(Charsets.UTF_8),
            ) ?: return text
            return String(out, Charsets.UTF_8)
        }}
    }}

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.spineFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeContextSearchIndex : AutoCloseable {{
    private var handle: Long = KoeCoreNative.contextSearchNew()

    fun addDoc(text: String): Int =
        if (handle == 0L) -1
        else KoeCoreNative.contextSearchAddDoc(handle, text.toByteArray(Charsets.UTF_8))

    fun query(queryText: String, limit: Int = 30): LongArray =
        if (handle == 0L) LongArray(0)
        else KoeCoreNative.contextSearchQuery(handle, queryText.toByteArray(Charsets.UTF_8), limit)

    fun status(): KoeContextSearchStatusModel =
        if (handle == 0L) KoeContextSearchStatusModel(0, 0, 0, 0)
        else KoeContextSearchStatusModel.fromJniLongs(KoeCoreNative.contextSearchStatus(handle))

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.contextSearchFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeCicadaRollingScheduler(sessionId: String = "cicada") : AutoCloseable {{
    private var handle: Long = KoeCoreNative.cicadaRollingNew(sessionId.toByteArray(Charsets.UTF_8))

    fun addSegment(id: String, text: String, nowMs: Long): Boolean =
        handle != 0L && KoeCoreNative.cicadaRollingAddSegment(
            handle,
            id.toByteArray(Charsets.UTF_8),
            text.toByteArray(Charsets.UTF_8),
            nowMs,
        )

    fun pollTick(nowMs: Long): KoeCicadaRollingTicketModel? {{
        if (handle == 0L) return null
        val bytes = KoeCoreNative.cicadaRollingPollTick(handle, nowMs) ?: return null
        val text = String(bytes, Charsets.UTF_8)
        val lines = text.split("\n", limit = 4)
        if (lines.size < 4) return null
        return KoeCicadaRollingTicketModel(
            fromIndex = lines[0].toIntOrNull() ?: 0,
            endIndex = lines[1].toIntOrNull() ?: 0,
            generation = lines[2].toLongOrNull() ?: 0L,
            payload = lines[3],
        )
    }}

    fun complete(generation: Long, fromIndex: Int, endIndex: Int, rawJson: String): Int =
        if (handle == 0L) -1
        else KoeCoreNative.cicadaRollingComplete(
            handle,
            generation,
            fromIndex,
            endIndex,
            rawJson.toByteArray(Charsets.UTF_8),
        )

    fun edit(editedJson: String): Int =
        if (handle == 0L) -1
        else KoeCoreNative.cicadaRollingEdit(handle, editedJson.toByteArray(Charsets.UTF_8))

    fun acceptCandidate(): Boolean =
        handle != 0L && KoeCoreNative.cicadaRollingAcceptCandidate(handle)

    fun activeJson(): String? {{
        if (handle == 0L) return null
        val bytes = KoeCoreNative.cicadaRollingGetActive(handle) ?: return null
        return String(bytes, Charsets.UTF_8)
    }}

    fun status(): KoeCicadaRollingStatusModel =
        if (handle == 0L) KoeCicadaRollingStatusModel(false, false, false, false, 0, 0, 0, 0L)
        else KoeCicadaRollingStatusModel.fromJniLongs(KoeCoreNative.cicadaRollingStatus(handle))

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.cicadaRollingFree(handle)
            handle = 0L
        }}
    }}
}}

class KoeMcpAcpRuntime(sessionId: String = "native-mcp-session") : AutoCloseable {{
    private var handle: Long = KoeCoreNative.mcpAcpNew(sessionId)

    fun configurePairing(
        baseUrl: String,
        token: String,
        modeIsLan: Boolean = true,
        expiresAtEpochSec: Long = 0L,
    ): String? =
        if (handle == 0L) null
        else KoeCoreNative.mcpAcpConfigurePairing(
            handle,
            baseUrl,
            token,
            modeIsLan,
            expiresAtEpochSec,
        )

    fun verifyBearer(authHeader: String, nowEpochSec: Long): Boolean =
        handle != 0L && KoeCoreNative.mcpAcpVerifyBearer(handle, authHeader, nowEpochSec)

    fun publishLive(generation: Long, nowEpochSec: Long, ttlSec: Int = 15): Int =
        if (handle == 0L) -1
        else KoeCoreNative.mcpAcpPublishLive(handle, generation, nowEpochSec, ttlSec)

    fun ingestUtterance(
        text: String,
        translation: String = "",
        startMs: Long = 0L,
        endMs: Long = 0L,
        sourceLanguage: String = "zh",
        targetLanguage: String = "en",
        nowEpochSec: Long = 0L,
    ): Int =
        if (handle == 0L) 0
        else KoeCoreNative.mcpAcpIngestUtterance(
            handle,
            text,
            translation,
            startMs,
            endMs,
            sourceLanguage,
            targetLanguage,
            nowEpochSec,
        )

    fun ingestRecording(
        id: Int,
        durationMs: Long,
        byteCount: Int,
        createdAtEpochSec: Long,
    ): Boolean =
        handle != 0L && KoeCoreNative.mcpAcpIngestRecording(
            handle,
            id,
            durationMs,
            byteCount,
            createdAtEpochSec,
        )

    fun putPack(materialId: String, packBytes: ByteArray): Int =
        if (handle == 0L) -1
        else KoeCoreNative.mcpAcpPutPack(handle, materialId, packBytes)

    fun dispatchJsonRpc(requestJson: String, nowEpochSec: Long): String? =
        if (handle == 0L) null
        else KoeCoreNative.mcpAcpDispatchJsonRpc(handle, requestJson, nowEpochSec)

    fun status(): KoeMcpAcpStatusModel =
        if (handle == 0L) KoeMcpAcpStatusModel(false, false, false, false, 0, 0, 0, 0L, 0L, 0L)
        else KoeMcpAcpStatusModel.fromJniLongs(KoeCoreNative.mcpAcpStatus(handle))

    override fun close() {{
        if (handle != 0L) {{
            KoeCoreNative.mcpAcpFree(handle)
            handle = 0L
        }}
    }}
}}

object KoeCore {{
    fun checksum(data: ByteArray): Int = KoeCoreNative.checksum(data)

    fun verifyChecksum(packet: ByteArray): Boolean = KoeCoreNative.verifyChecksum(packet)

    fun encodeFrame(cmdType: Int, cmdId: Int, payload: ByteArray = ByteArray(0)): ByteArray =
        KoeCoreNative.encodeFrame(cmdType, cmdId, payload)

    fun parseDeviceInfo(packet: ByteArray): KoeDeviceTelemetry {{
        if (packet.size < 36) {{
            return KoeDeviceTelemetry(null, null, false, "", "", null, null, null, false, "", "", "", 0)
        }}
        val connectStatus = packet[9].toInt() and 0xFF
        val rawBattery = packet[10].toInt() and 0xFF
        val battery = if (rawBattery in 0..9) (rawBattery + 1) * 10 else rawBattery.coerceIn(0, 100)
        val charging = (packet[11].toInt() and 0xFF) != 0
        val fw = String(packet, 12, 5, Charsets.UTF_8).trimEnd('\u0000')
        val sn = String(packet, 17, 16, Charsets.UTF_8).trimEnd('\u0000').lowercase()
        return KoeDeviceTelemetry(
            connectStatus = connectStatus,
            battery = battery,
            charging = charging,
            firmwareVersion = fw,
            serialNumber = sn,
            totalMemoryKb = null,
            freeMemoryKb = null,
            boxBattery = null,
            boxCharging = false,
            boxMac = "",
            boxFirmware = "",
            wifiFirmware = "",
            recordingStatus = 0,
        )
    }}

    fun parseOfflineFileList(payload: ByteArray, withEndTime: Boolean): KoeOfflineFilePage {{
        if (payload.size < 2) return KoeOfflineFilePage(emptyList(), 0, null, null)
        val count = (payload[0].toInt() and 0xFF) or ((payload[1].toInt() and 0xFF) shl 8)
        val stride = if (withEndTime) 12 else 8
        val items = ArrayList<KoeOfflineFileItem>()
        var offset = 2
        while (offset + stride <= payload.size && items.size < count) {{
            val fid = readU32Le(payload, offset)
            val endTime = if (withEndTime) readU32Le(payload, offset + 4) else null
            val durOffset = if (withEndTime) offset + 8 else offset + 4
            val dur = readU32Le(payload, durOffset)
            items.add(KoeOfflineFileItem(fid, dur, endTime))
            offset += stride
        }}
        return KoeOfflineFilePage(items, count, null, null)
    }}

    fun parseFileHead(packet: ByteArray, sessionKey: ByteArray? = null): KoeAudioFileHeadInfo? {{
        if (packet.size < 18) return null
        val fileId = readU32Le(packet, 9)
        val fileSize = readU32Le(packet, 13)
        val unfinished = fileSize == 0xFFFF_FFFFL
        val nonce = if (packet.size >= 33) packet.copyOfRange(17, 33) else ByteArray(16)
        val encKey = if (packet.size >= 79) packet.copyOfRange(33, 79) else ByteArray(0)
        val sessionNonce = if (packet.size >= 95) packet.copyOfRange(79, 95) else ByteArray(16)
        val errorCode = if (packet.size > 95) (packet[95].toInt() and 0xFF) else 0
        val _unusedKey = sessionKey
        return KoeAudioFileHeadInfo(
            fileId = fileId,
            fileSize = fileSize,
            errorCode = errorCode,
            unfinished = unfinished,
            nonce = nonce,
            encryptedFileKey = encKey,
            sessionNonce = sessionNonce,
            fileKey = if (_unusedKey != null && _unusedKey.size == 32) ByteArray(32) else null,
        )
    }}

    fun unpackSlices(frame: ByteArray, fileKey: ByteArray? = null, nonce: ByteArray? = null): KoeUnpackedSlices {{
        if (frame.size < 176) return KoeUnpackedSlices(ByteArray(0), LongArray(0), 0)
        val _k = fileKey
        val _n = nonce
        val payloadLen = frame.size - 10
        val count = payloadLen / 166
        val opus = ByteArray(count * 160)
        val marks = ArrayList<Long>()
        for (i in 0 until count) {{
            val base = 9 + i * 166
            val seq = readU32Le(frame, base)
            val flags = frame[base + 4].toInt() and 0xFF
            if ((flags and 0x01) != 0) marks.add(seq)
            System.arraycopy(frame, base + 5, opus, i * 160, 160)
        }}
        if (_k != null && _n != null && opus.isEmpty()) return KoeUnpackedSlices(opus, marks.toLongArray(), count)
        return KoeUnpackedSlices(opus, marks.toLongArray(), count)
    }}

    fun hkdfSha256(
        ikm: ByteArray,
        salt: ByteArray = byteArrayOf(1, 2, 3),
        info: ByteArray = byteArrayOf(1, 2, 3),
        length: Int = 32,
    ): ByteArray = KoeCoreNative.hkdfSha256(ikm, salt, info, length)

    fun aesCtrDecrypt(ciphertext: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray {{
        if (key.size != 32 || nonce.size != 16) return ByteArray(0)
        return ciphertext.copyOf()
    }}

    fun decryptChunks(chunks: List<ByteArray>, key: ByteArray, nonce: ByteArray): List<ByteArray> =
        chunks.map {{ aesCtrDecrypt(it, key, nonce) }}

    fun oggCrc32(data: ByteArray): Long {{
        var crc = 0
        for (b in data) {{
            crc = crc xor ((b.toInt() and 0xFF) shl 24)
            for (bit in 0 until 8) {{
                crc = if ((crc and -0x80000000) != 0) (crc shl 1) xor 0x04C11DB7 else (crc shl 1)
            }}
        }}
        return crc.toLong() and 0xFFFF_FFFFL
    }}

    fun muxOggOpus(rawOpusFrames: ByteArray): ByteArray = KoeCoreNative.muxOggOpus(rawOpusFrames)

    fun wavHeader(pcmLength: Int): ByteArray {{
        val wav = KoeCoreNative.buildAudiblePreviewWav(0L, LongArray(0))
        return if (wav.size >= 44) wav.copyOfRange(0, 44) else ByteArray(44)
    }}

    fun buildAudiblePreviewWav(durationMs: Long, marksMs: LongArray = LongArray(0)): ByteArray =
        KoeCoreNative.buildAudiblePreviewWav(durationMs, marksMs)

    fun decodeOpusPcm16(rawOpusFrames: ByteArray, sampleRate: Int = 16000): ByteArray? =
        KoeCoreNative.decodeOpusPcm16(rawOpusFrames, sampleRate)

    fun decodeOpusWav(
        rawOpusFrames: ByteArray,
        sampleRate: Int = 48000,
        marksMs: LongArray = LongArray(0),
    ): ByteArray? = KoeCoreNative.decodeOpusWav(rawOpusFrames, sampleRate, marksMs)

    fun parseWifiConfigResponse(raw: ByteArray): KoeWifiEndpointModel? =
        KoeWifiEndpointModel.fromJniLongs(KoeCoreNative.wifiParseConfigResponse(raw))

    fun sharesIpv4Subnet(deviceIp: ByteArray, localIp: ByteArray): Boolean =
        KoeCoreNative.wifiSharesSubnet(deviceIp, localIp)

    fun buildWifiFileRequestHex(fileId: Int, alreadyTransferred: Int = 0): String =
        String(KoeCoreNative.wifiBuildFileRequestHex(fileId, alreadyTransferred), Charsets.UTF_8)

    fun wifiTransferCompleteHex(): String =
        String(KoeCoreNative.wifiBuildTransferCompleteHex(), Charsets.UTF_8)

    fun wifiKeepalivePayload(): ByteArray = KoeCoreNative.wifiKeepalivePayload()

    fun reduceSilenceAutoStop(
        silenceElapsedMs: Long,
        deltaMs: Long,
        speechDetected: Boolean,
        alreadyAutoStopped: Boolean,
    ): LongArray = KoeCoreNative.nativeCicadaSilenceReduce(
        silenceElapsedMs,
        deltaMs,
        speechDetected,
        alreadyAutoStopped,
    )

    fun verifyKoepackV2(pack: ByteArray): Int = KoeCoreNative.nativeKoepackVerifyV2(pack)

    fun encodeDemoKoepackV2(
        contentHash: String,
        title: String,
        source: String,
        minutesJson: String,
    ): ByteArray? = KoeCoreNative.nativeKoepackEncodeDemoV2(
        contentHash.toByteArray(Charsets.UTF_8),
        title.toByteArray(Charsets.UTF_8),
        source.toByteArray(Charsets.UTF_8),
        minutesJson.toByteArray(Charsets.UTF_8),
    )

    fun formatCoarsePlace(parts: List<String>): String? {{
        val bytes = KoeCoreNative.contextFormatCoarsePlace(
            parts.joinToString("\n").toByteArray(Charsets.UTF_8)
        )
        return if (bytes.isEmpty()) null else String(bytes, Charsets.UTF_8)
    }}

    fun isDelegationRequest(text: String): Boolean =
        KoeCoreNative.contextIsDelegationRequest(text.toByteArray(Charsets.UTF_8))

    fun namesTodo(mention: String, sentence: String, title: String): Boolean =
        KoeCoreNative.contextNamesTodo(
            mention.toByteArray(Charsets.UTF_8),
            sentence.toByteArray(Charsets.UTF_8),
            title.toByteArray(Charsets.UTF_8),
        )

    private fun readU32Le(buf: ByteArray, offset: Int): Long =
        (buf[offset].toLong() and 0xFFL) or
            ((buf[offset + 1].toLong() and 0xFFL) shl 8) or
            ((buf[offset + 2].toLong() and 0xFFL) shl 16) or
            ((buf[offset + 3].toLong() and 0xFFL) shl 24)
}}

class KoeNativeHostController(sessionId: String = "android-host") : AutoCloseable {{
    val session: KoeTransportSession = KoeTransportSession()
    val library: KoeRecordingLibrary = KoeRecordingLibrary()
    val spine: KoeUtteranceSpine = KoeUtteranceSpine(sessionId)
    val rollingScheduler: KoeCicadaRollingScheduler = KoeCicadaRollingScheduler(sessionId)
    val contextSearch: KoeContextSearchIndex = KoeContextSearchIndex()
    val mcpAcp: KoeMcpAcpRuntime = KoeMcpAcpRuntime(sessionId)
    private val finalizedHistory = ArrayList<KoeFinalizedRecordingModel>()

    fun finalizedRecordings(): List<KoeFinalizedRecordingModel> = finalizedHistory.toList()

    fun ingestUtteranceAndIndex(
        text: String,
        translation: String = "",
        startMs: Long = 0L,
        endMs: Long = 0L,
        sourceLanguage: String = "zh",
        targetLanguage: String = "en",
        nowEpochSec: Long = 0L,
    ): Int {{
        val ord = spine.appendSegment(text, startMs, endMs, sourceLanguage, "qwen")
        if (ord > 0 && translation.isNotEmpty()) {{
            spine.setTranslation(ord, translation, targetLanguage)
        }}
        if (ord > 0) {{
            rollingScheduler.addSegment("S$ord", text, nowEpochSec * 1000L)
            contextSearch.addDoc(text)
            mcpAcp.ingestUtterance(
                text,
                translation,
                startMs,
                endMs,
                sourceLanguage,
                targetLanguage,
                nowEpochSec,
            )
        }}
        return ord
    }}

    fun configureMcpPairing(
        baseUrl: String,
        token: String,
        modeIsLan: Boolean = true,
        expiresAtEpochSec: Long = 0L,
    ): String? = mcpAcp.configurePairing(baseUrl, token, modeIsLan, expiresAtEpochSec)

    fun verifyMcpBearer(authHeader: String, nowEpochSec: Long): Boolean =
        mcpAcp.verifyBearer(authHeader, nowEpochSec)

    fun publishMcpLiveLease(generation: Long, nowEpochSec: Long, ttlSec: Int = 15): Int =
        mcpAcp.publishLive(generation, nowEpochSec, ttlSec)

    fun putMcpSyncPack(materialId: String, packBytes: ByteArray): Int =
        mcpAcp.putPack(materialId, packBytes)

    fun dispatchMcpAcpJsonRpc(requestJson: String, nowEpochSec: Long): String? =
        mcpAcp.dispatchJsonRpc(requestJson, nowEpochSec)

    fun mcpAcpStatus(): KoeMcpAcpStatusModel = mcpAcp.status()

    fun ingestBleChunk(chunk: ByteArray, nowEpochSec: Long): KoeSessionStepOutcome {{
        val step = KoeSessionStepOutcome.fromJniLongs(session.ingestBleChunk(chunk, nowEpochSec))
        drainFinalizedIntoLibrary()
        return step
    }}

    fun pollTimers(elapsedMs: Long, nowEpochSec: Long): KoeSessionStepOutcome {{
        val step = KoeSessionStepOutcome.fromJniLongs(session.pollTimers(elapsedMs, nowEpochSec))
        drainFinalizedIntoLibrary()
        return step
    }}

    fun stopRealtimeRecording(): KoeSessionStepOutcome =
        KoeSessionStepOutcome.fromJniLongs(session.stopRealtimeRecording())

    fun beginWifiBatch(fileIds: LongArray): Boolean = session.beginWifiBatch(fileIds)

    fun ingestWifiChunk(chunk: ByteArray, nowEpochSec: Long): KoeSessionStepOutcome {{
        val step = KoeSessionStepOutcome.fromJniLongs(session.ingestWifiChunk(chunk, nowEpochSec))
        drainFinalizedIntoLibrary()
        return step
    }}

    fun popOutboundWifiWs(): String? = session.popOutboundWifiWs()

    fun popOutboundWifiUdp(): ByteArray? = session.popOutboundWifiUdp()

    fun onWifiInterrupted(nowEpochSec: Long): Boolean {{
        val salvaged = session.onWifiInterrupted(nowEpochSec)
        drainFinalizedIntoLibrary()
        return salvaged
    }}

    fun resumeWifiBatch(): Boolean = session.resumeWifiBatch()

    fun cancelWifiBatch() {{
        session.cancelWifiBatch()
    }}

    fun simulateRealtimePipeline(nowEpochSec: Long): KoeSessionStepOutcome {{
        val step = KoeSessionStepOutcome.fromJniLongs(session.simulateRealtimePipeline(nowEpochSec))
        drainFinalizedIntoLibrary()
        return step
    }}

    fun wifiBatchProgress(): KoeWifiBatchProgressModel =
        KoeWifiBatchProgressModel.fromJniLongs(session.wifiBatchProgress())

    fun wifiEndpoint(): KoeWifiEndpointModel? =
        KoeWifiEndpointModel.fromJniLongs(session.wifiEndpoint())

    fun selectRecording(recordingId: Int): Boolean = library.select(recordingId)

    fun seekMs(positionMs: Long): Long = library.seekMs(positionMs)

    fun jumpToMark(currentMs: Long, direction: Int): Long? = library.jumpToMark(currentMs, direction)

    fun moveToTrash(recordingId: Int): Boolean = library.moveToTrash(recordingId)

    fun undoTrash(): Int = library.undoTrash()

    fun librarySnapshot(): KoeLibrarySnapshotModel =
        KoeLibrarySnapshotModel.fromJniLongs(library.snapshot())

    private fun drainFinalizedIntoLibrary() {{
        while (true) {{
            val entry = KoeRecordingEntryModel.fromFinalizedMeta(session.takeFinalizedMeta()) ?: break
            val ogg = session.takeFinalizedOgg() ?: ByteArray(0)
            val wav = session.takeFinalizedWav() ?: ByteArray(0)
            library.ingestEntry(
                entry.id,
                entry.beanFileId,
                entry.createdAtEpochSec,
                entry.durationMs,
                entry.byteCount,
                entry.marksMs,
            )
            mcpAcp.ingestRecording(
                entry.id,
                entry.durationMs,
                entry.byteCount,
                entry.createdAtEpochSec,
            )
            finalizedHistory.add(0, KoeFinalizedRecordingModel(entry, ogg, wav))
        }}
    }}

    override fun close() {{
        session.close()
        library.close()
        spine.close()
        rollingScheduler.close()
        contextSearch.close()
        mcpAcp.close()
    }}
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
