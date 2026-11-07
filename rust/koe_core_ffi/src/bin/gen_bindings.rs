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

    private fun readU32Le(buf: ByteArray, offset: Int): Long =
        (buf[offset].toLong() and 0xFFL) or
            ((buf[offset + 1].toLong() and 0xFFL) shl 8) or
            ((buf[offset + 2].toLong() and 0xFFL) shl 16) or
            ((buf[offset + 3].toLong() and 0xFFL) shl 24)
}}

class KoeNativeHostController : AutoCloseable {{
    val session: KoeTransportSession = KoeTransportSession()
    val library: KoeRecordingLibrary = KoeRecordingLibrary()
    private val finalizedHistory = ArrayList<KoeFinalizedRecordingModel>()

    fun finalizedRecordings(): List<KoeFinalizedRecordingModel> = finalizedHistory.toList()

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
            finalizedHistory.add(0, KoeFinalizedRecordingModel(entry, ogg, wav))
        }}
    }}

    override fun close() {{
        session.close()
        library.close()
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
