use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use sudachi::analysis::stateful_tokenizer::StatefulTokenizer;
use sudachi::config::Config;
use sudachi::dic::dictionary::JapaneseDictionary;
use sudachi::prelude::{Mode, MorphemeList};

static DICTIONARY: OnceLock<Mutex<Option<(String, Arc<JapaneseDictionary>)>>> = OnceLock::new();

unsafe fn string(pointer: *const c_char) -> Result<String, String> {
    if pointer.is_null() { return Err("null argument".into()); }
    CStr::from_ptr(pointer).to_str().map(str::to_owned).map_err(|e| e.to_string())
}

#[no_mangle]
pub unsafe extern "C" fn jp_sudachi_analyze(config: *const c_char, resources: *const c_char,
    dictionary: *const c_char, text: *const c_char) -> *mut c_char {
    jp_sudachi_analyze_with_mode(config, resources, dictionary, text, 2)
}

#[no_mangle]
pub unsafe extern "C" fn jp_sudachi_analyze_with_mode(config: *const c_char, resources: *const c_char,
    dictionary: *const c_char, text: *const c_char, split_mode: c_int) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<serde_json::Value, String> {
        let mode = match split_mode {
            0 => Mode::A, 1 => Mode::B, 2 => Mode::C,
            _ => return Err("invalid split mode: expected 0(A), 1(B), or 2(C)".into()),
        };
        let config = string(config)?; let resources = string(resources)?;
        let dictionary = string(dictionary)?; let text = string(text)?;
        let key = format!("{}|{}|{}", config, resources, dictionary);
        let mut cached = DICTIONARY.get_or_init(|| Mutex::new(None)).lock().map_err(|e| e.to_string())?;
        if cached.as_ref().map(|v| &v.0) != Some(&key) {
            let cfg = Config::new(Some(PathBuf::from(config)), Some(PathBuf::from(resources)), Some(PathBuf::from(dictionary))).map_err(|e| e.to_string())?;
            let dict = JapaneseDictionary::from_cfg(&cfg).map_err(|e| e.to_string())?;
            *cached = Some((key, Arc::new(dict)));
        }
        let dict = cached.as_ref().unwrap().1.clone();
        drop(cached);
        let mut tokenizer = StatefulTokenizer::new(dict.clone(), mode);
        tokenizer.reset().push_str(&text);
        tokenizer.do_tokenize().map_err(|e| e.to_string())?;
        let mut morphemes = MorphemeList::empty(dict);
        morphemes.collect_results(&mut tokenizer).map_err(|e| e.to_string())?;
        let mut tokens = vec![];
        for i in 0..morphemes.len() {
            let m = morphemes.get(i);
            if m.begin() == m.end() { continue; }
            tokens.push(serde_json::json!({
                "surface": m.surface().to_string(), "lemma": m.dictionary_form(), "reading": m.reading_form(),
                "start": text[..m.begin()].encode_utf16().count(), "end": text[..m.end()].encode_utf16().count()
            }));
        }
        Ok(serde_json::json!({"tokens": tokens}))
    });
    let value = match result { Ok(Ok(value)) => value, Ok(Err(error)) => serde_json::json!({"error":error}),
        Err(_) => serde_json::json!({"error":"Sudachi panic contained at FFI boundary"}) };
    CString::new(value.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn jp_sudachi_free(pointer: *mut c_char) {
    if !pointer.is_null() { drop(CString::from_raw(pointer)); }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_mode_is_reported_before_dereferencing_arguments() {
        unsafe {
            let pointer = jp_sudachi_analyze_with_mode(std::ptr::null(), std::ptr::null(),
                std::ptr::null(), std::ptr::null(), 99);
            let value: serde_json::Value = serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
            jp_sudachi_free(pointer);
            assert!(value["error"].as_str().unwrap().contains("invalid split mode"));
        }
    }

    #[test]
    fn actual_dictionary_supports_abc_and_original_utf16_ranges() {
        let resources = std::env::var("JP_SUDACHI_TEST_RESOURCES")
            .expect("Set JP_SUDACHI_TEST_RESOURCES to the prepared Sudachi folder");
        let path = PathBuf::from(&resources);
        let config = CString::new(path.join("sudachi.json").to_str().unwrap()).unwrap();
        let dictionary = CString::new(path.join("system.dic").to_str().unwrap()).unwrap();
        let resources = CString::new(resources).unwrap();
        let mut counts = vec![];
        for mode in 0..=2 {
            for source in ["国家公務員", "🎮東京都で遊んだ。", "𠮷野家で食べました。"] {
                let text = CString::new(source).unwrap();
                let value: serde_json::Value = unsafe {
                    let pointer = jp_sudachi_analyze_with_mode(config.as_ptr(), resources.as_ptr(),
                        dictionary.as_ptr(), text.as_ptr(), mode);
                    let value = serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
                    jp_sudachi_free(pointer);
                    value
                };
                assert!(value.get("error").is_none(), "{}", value);
                let tokens = value["tokens"].as_array().unwrap();
                let mut rebuilt = String::new();
                let mut offset = 0;
                for token in tokens {
                    let surface = token["surface"].as_str().unwrap();
                    assert_eq!(token["start"].as_u64().unwrap() as usize, offset);
                    offset += surface.encode_utf16().count();
                    assert_eq!(token["end"].as_u64().unwrap() as usize, offset);
                    rebuilt.push_str(surface);
                }
                assert_eq!(rebuilt, source);
                if source == "国家公務員" { counts.push(tokens.len()); }
            }
        }
        assert!(counts[0] >= counts[1] && counts[1] >= counts[2]);
        assert!(counts[0] > counts[2], "A and C must produce distinct splits for the fixture");
    }
}
