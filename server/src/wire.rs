//! A call's arguments as they come over HTTP (a JSON array), and the core's results back.
use anyhow::{anyhow, Context};
use serde_json::Value;
use std::ffi::{c_char, CStr, CString};

/// The positional arguments of one call.
pub struct Args(pub Vec<Value>);

impl Args {
    fn at(&self, i: usize) -> anyhow::Result<&Value> { self.0.get(i).with_context(|| format!("argument {i} missing")) }

    /// A string argument (null stays null) as the C string the core reads.
    pub fn c_str(&self, i: usize) -> anyhow::Result<Option<CString>> {
        match self.at(i)? {
            Value::Null => Ok(None),
            Value::String(s) => Ok(Some(CString::new(s.replace('\0', ""))?)),
            v => Err(anyhow!("argument {i}: a string, not {v}")),
        }
    }

    pub fn ptr(&self, s: &Option<CString>) -> *const c_char { s.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()) }

    pub fn int<T: TryFrom<i128>>(&self, i: usize) -> anyhow::Result<T> {
        let v = self.at(i)?;
        let n: i128 = v.as_i64().map(i128::from).or_else(|| v.as_u64().map(i128::from))
            .or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i128))
            .with_context(|| format!("argument {i}: a whole number, not {v}"))?;
        T::try_from(n).map_err(|_| anyhow!("argument {i}: {n} out of range"))
    }

    pub fn bool(&self, i: usize) -> anyhow::Result<bool> {
        self.at(i)?.as_bool().with_context(|| format!("argument {i}: true or false"))
    }
}

/// A string the core handed over (and that is freed here); null stays null.
pub fn take(p: *mut c_char) -> Value {
    if p.is_null() { return Value::Null; }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    tl_core::ffi::tl_string_free(p);
    Value::String(s)
}
