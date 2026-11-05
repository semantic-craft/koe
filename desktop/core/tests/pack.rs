use koe_core::read_pack;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::{self, Read};
fn manifest() -> Value {
    json!({"format":"koe-material-pack","version":1,"exportedAt":"2026-11-05T10:00:00.000",
        "material":{"contentHash":format!("{:x}",Sha256::digest(b"audio")),"title":"周会","source":"phone"},
        "transcript":{"text":"原文","manual":"校订","segments":[{"text":"一","startMs":0,"endMs":1200,"speaker":"1"},{"text":"二","startMs":1200,"endMs":null,"speaker":"1"}],"segmentSpeakers":{"1":"2"},"speakerAliases":{"1":"甲","2":"乙"},"revision":2,"translation":{"text":"translation"}},
        "audio":{"included":false}, "futureField":{"keep":true}})
}
fn bytes(v: &Value, audio: &[u8]) -> Vec<u8> {
    let data = serde_json::to_vec(v).unwrap();
    let mut result = format!("KOEPACK1\n{}\n", data.len()).into_bytes();
    result.extend(data);
    result.extend(audio);
    result
}
#[test]
fn reads_corrected_text_speakers_and_preserves_original() {
    let v = manifest();
    let p = read_pack(&bytes(&v, &[])[..]).unwrap();
    assert_eq!(p.title, "周会");
    assert_eq!(p.text.as_deref(), Some("校订"));
    assert_eq!(p.segments[0]["speaker"], "甲");
    assert_eq!(p.segments[1]["speaker"], "乙");
    assert_eq!(p.segments[1]["startMs"], 1200);
    assert_eq!(p.manifest, v);
}
#[test]
fn empty_correction_is_not_missing() {
    let mut v = manifest();
    v["transcript"]["manual"] = json!("");
    let p = read_pack(&bytes(&v, &[])[..]).unwrap();
    assert_eq!(p.text.as_deref(), Some(""));
    v["transcript"]["segmentSpeakers"]["0"] = json!("");
    assert!(read_pack(&bytes(&v, &[])[..]).unwrap().segments[0]["speaker"].is_null());
}
#[test]
fn validates_audio_digest_length_and_trailing_bytes() {
    let mut v = manifest();
    v["audio"] =
        json!({"included":true,"bytes":5,"extension":".wav","sha256":v["material"]["contentHash"]});
    assert!(read_pack(&bytes(&v, b"audio")[..]).is_ok());
    for a in [b"audix".as_slice(), b"audi", b"audio!"] {
        assert!(read_pack(&bytes(&v, a)[..]).is_err());
    }
    v["audio"]["sha256"] = json!("a".repeat(64));
    assert!(read_pack(&bytes(&v, b"audio")[..]).is_err());
    assert!(read_pack(&bytes(&manifest(), b"x")[..]).is_err());
}
#[test]
fn rejects_bad_types_versions_and_ranges() {
    for version in [json!(0), json!(3), json!(1.0), json!("1"), json!(null)] {
        let mut v = manifest();
        v["version"] = version;
        assert!(read_pack(&bytes(&v, &[])[..]).is_err());
    }
    for (pointer, value) in [
        ("/material/title", json!(42)),
        ("/exportedAt", json!(false)),
        ("/audio/included", json!("false")),
        ("/transcript/manual", json!([])),
        ("/transcript/segments/0/startMs", json!(-1)),
        ("/transcript/segments/0/endMs", json!(-1)),
        ("/transcript/segmentSpeakers/1", json!(3)),
    ] {
        let mut v = manifest();
        *v.pointer_mut(pointer).unwrap() = value;
        assert!(read_pack(&bytes(&v, &[])[..]).is_err(), "{pointer}");
    }
    let mut v = manifest();
    v["minutes"] = json!(null);
    assert!(read_pack(&bytes(&v, &[])[..]).is_err());
}
#[test]
fn rejects_broken_framing_without_panicking() {
    for data in [
        b"WRONG\n2\n{}".as_slice(),
        b"KOEPACK1\n33554433\n{}",
        b"KOEPACK1\n0\n",
        b"KOEPACK1\n99999999999999999\n",
        b"KOEPACK1\n10\n{}",
        b"KOEPACK1\n2\n\xff\xff",
    ] {
        assert!(read_pack(data).is_err());
    }
    let valid = bytes(&manifest(), &[]);
    for n in 0..valid.len() {
        assert!(read_pack(&valid[..n]).is_err(), "prefix {n}");
    }
}
struct Chunks<'a>(&'a [u8]);
impl Read for Chunks<'_> {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        assert!(b.len() <= 65536, "audio must be streamed");
        let n = b.len().min(7).min(self.0.len());
        b[..n].copy_from_slice(&self.0[..n]);
        self.0 = &self.0[n..];
        Ok(n)
    }
}
#[test]
fn accepts_short_reads_and_streams_large_audio() {
    let audio = vec![17; 200_000];
    let mut v = manifest();
    let hash = format!("{:x}", Sha256::digest(&audio));
    v["material"]["contentHash"] = json!(hash);
    v["audio"] = json!({"included":true,"bytes":audio.len(),"extension":".wav","sha256":hash});
    assert!(read_pack(Chunks(&bytes(&v, &audio))).is_ok());
}

#[test]
fn recomputes_speaker_changes_from_corrected_ids_before_aliases() {
    let mut v = manifest();
    v["transcript"]["segments"] = json!([
        {"text":"first", "startMs":0, "speaker":"1", "speakerChanged":false},
        {"text":"merged", "startMs":1, "speaker":"2", "speakerChanged":true},
        {"text":"distinct id", "startMs":2, "speaker":"1", "speakerChanged":false},
        {"text":"cleared", "startMs":3, "speaker":"2", "speakerChanged":true},
        {"text":"resumed", "startMs":4, "speaker":"2", "speakerChanged":false},
        {"text":"same speaker", "startMs":5, "speaker":"2", "speakerChanged":true}
    ]);
    v["transcript"]["segmentSpeakers"] = json!({"1":"1", "2":"2", "3":""});
    v["transcript"]["speakerAliases"] = json!({"1":"同名", "2":"同名"});
    let p = read_pack(&bytes(&v, &[])[..]).unwrap();
    let changed: Vec<_> = p
        .segments
        .iter()
        .map(|s| s["speakerChanged"].clone())
        .collect();
    assert_eq!(
        changed,
        vec![
            json!(true),
            json!(false),
            json!(true),
            json!(false),
            json!(true),
            json!(false)
        ]
    );
    assert_eq!(p.segments[1]["speaker"], p.segments[2]["speaker"]);
    assert!(p.segments[3]["speaker"].is_null());
    assert_eq!(p.manifest, v);
}
