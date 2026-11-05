use super::*;
pub(super) fn validate(value: &Value) -> Result<()> {
    object(value)?;
    let history = array(&value["history"])?;
    if history.len() > 10 {
        return Err("minutes history exceeds 10".into());
    }
    for result in std::iter::once(&value["current"]).chain(history) {
        object(result)?;
        let text = nonempty(&result["text"])?;
        nonempty(&result["model"])?;
        string(&result["instruction"])?;
        if !is_hash(string(&result["sourceHash"])?) {
            return Err("invalid minutes source hash".into());
        }
        date(&result["createdAt"])?;
        if present(&result["editedAt"]) {
            date(&result["editedAt"])?;
        }
        if present(&result["templateId"]) {
            string(&result["templateId"])?;
        }
        if integer(&result["templateVersion"])? == 0 {
            return Err("invalid template version".into());
        }
        result["isDraft"].as_bool().ok_or("invalid draft flag")?;
        let sources: Vec<_> = array(&result["sources"])?
            .iter()
            .map(string)
            .collect::<Result<_>>()?;
        let body: Value =
            serde_json::from_str(text).map_err(|_| "invalid structured minutes JSON")?;
        document(&body, &sources)?;
    }
    Ok(())
}
struct Rules<'a> {
    version: u64,
    sources: &'a [&'a str],
}
impl Rules<'_> {
    fn text<'a>(&self, v: &'a Value) -> Result<&'a str> {
        let s = nonempty(v)?;
        if self.version == 2 && s.encode_utf16().count() > 20000 {
            return Err("minutes text too long".into());
        }
        Ok(s)
    }
    fn list<'a>(&self, v: &'a Value, max: usize) -> Result<&'a Vec<Value>> {
        let a = array(v)?;
        if self.version == 2 && a.len() > max {
            return Err("minutes list too long".into());
        }
        Ok(a)
    }
    fn refs(&self, v: &Value) -> Result<Vec<usize>> {
        let a = self.list(v, 10000)?;
        if a.is_empty() {
            return Err("missing minutes sources".into());
        }
        a.iter()
            .map(|v| {
                let s = string(v)?
                    .strip_prefix('S')
                    .ok_or("invalid source reference")?;
                if s.starts_with('0') || !s.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("invalid source reference".into());
                }
                let n: usize = s.parse().map_err(|_| "invalid source reference")?;
                if n == 0 || n > self.sources.len() {
                    return Err("source reference out of range".into());
                }
                Ok(n - 1)
            })
            .collect()
    }
    fn item(&self, v: &Value, action: bool, topic: bool) -> Result<()> {
        let obj = object(v)?;
        self.text(&v["text"])?;
        self.refs(&v["sources"])?;
        let expanded = ["summary", "points", "fishbone"]
            .iter()
            .any(|k| obj.contains_key(*k));
        if expanded {
            if !topic || self.version != 2 {
                return Err("unexpected topic extension".into());
            }
            self.text(&v["summary"])?;
            for point in self.list(&v["points"], 100)? {
                self.item(point, false, false)?;
            }
            let fish = &v["fishbone"];
            if present(fish) {
                object(fish)?;
                self.text(&fish["question"])?;
                let branches = self.list(&fish["branches"], 30)?;
                if branches.is_empty() {
                    return Err("missing fishbone branches".into());
                }
                for branch in branches {
                    object(branch)?;
                    self.text(&branch["text"])?;
                    self.text(&branch["detail"])?;
                    self.refs(&branch["sources"])?;
                }
            }
        }
        if action {
            self.text(&v["owner"])?;
            self.text(&v["due"])?;
        }
        Ok(())
    }
}
fn document(v: &Value, sources: &[&str]) -> Result<()> {
    let obj = object(v)?;
    let version = if obj.contains_key("schemaVersion") {
        integer(&v["schemaVersion"])?
    } else {
        1
    };
    if ![1, 2].contains(&version) {
        return Err("unsupported minutes schema".into());
    }
    let r = Rules { version, sources };
    r.text(&v["title"])?;
    r.text(&v["overview"])?;
    for section in ["topics", "decisions", "actions", "questions"] {
        for item in r.list(&v[section], 100)? {
            r.item(item, section == "actions", section == "topics")?;
        }
    }
    if obj.contains_key("terms") {
        if version != 2 {
            return Err("terms require schema 2".into());
        }
        for term in r.list(&v["terms"], 200)? {
            object(term)?;
            r.text(&term["name"])?;
            r.text(&term["note"])?;
            let refs = r.refs(&term["sources"])?;
            if term.get("heard").is_some() {
                for spelling in r.list(&term["heard"], 30)? {
                    let spelling = r.text(spelling)?;
                    if !refs.iter().any(|i| sources[*i].contains(spelling)) {
                        return Err("heard spelling absent from sources".into());
                    }
                }
            }
            let adoption = &term["adoption"];
            if present(adoption) {
                object(adoption)?;
                if !["vocabulary", "replaced"].contains(&string(&adoption["kind"])?) {
                    return Err("invalid term adoption".into());
                }
                date(&adoption["at"])?;
                if !is_hash(string(&adoption["previousVersion"])?) {
                    return Err("invalid adoption fingerprint".into());
                }
            }
        }
    }
    if present(&v["custom"]) {
        for section in array(&v["custom"])? {
            object(section)?;
            r.text(&section["title"])?;
            for item in array(&section["items"])? {
                r.item(item, false, false)?;
            }
        }
    }
    let review = if present(&v["reviewItems"]) {
        &v["reviewItems"]
    } else {
        &v["review_items"]
    };
    if present(review) {
        array(review)?;
    }
    Ok(())
}
