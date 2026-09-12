use std::ffi::{CStr, CString};
use std::os::raw::c_char;
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
    let result = std::panic::catch_unwind(|| -> Result<serde_json::Value, String> {
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
        let mut tokenizer = StatefulTokenizer::new(dict.clone(), Mode::B);
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
