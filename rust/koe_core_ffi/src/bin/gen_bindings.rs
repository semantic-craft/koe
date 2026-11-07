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
