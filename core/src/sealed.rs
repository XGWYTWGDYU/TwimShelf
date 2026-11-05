//! Secrets on Windows and Linux, where the app keeps them itself: values sealed with
//! ChaCha20-Poly1305 under a key in the data folder. This keeps them from being read as plain
//! text by a glance or a search; it does not stop a program that can read the data folder.
//! (Apple devices use the Keychain, Android the Keystore.)
use anyhow::{bail, Context};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};

pub fn new_key() -> String { hex::encode(rand::random::<[u8; 32]>()) }

fn cipher(key_hex: &str) -> anyhow::Result<ChaCha20Poly1305> {
    let k = hex::decode(key_hex).context("key")?;
    if k.len() != 32 { bail!("key") }
    Ok(ChaCha20Poly1305::new(Key::from_slice(&k)))
}

/// nonce ‖ ciphertext, hex.
pub fn seal(key_hex: &str, text: &str) -> anyhow::Result<String> {
    let nonce: [u8; 12] = rand::random();
    let ct = cipher(key_hex)?.encrypt(Nonce::from_slice(&nonce), text.as_bytes()).map_err(|_| anyhow::anyhow!("seal"))?;
    Ok(hex::encode([&nonce[..], &ct].concat()))
}

pub fn open(key_hex: &str, blob_hex: &str) -> anyhow::Result<String> {
    let b = hex::decode(blob_hex).context("blob")?;
    if b.len() < 12 + 16 { bail!("blob") }
    let pt = cipher(key_hex)?.decrypt(Nonce::from_slice(&b[..12]), &b[12..]).map_err(|_| anyhow::anyhow!("open"))?;
    Ok(String::from_utf8(pt)?)
}

#[cfg(test)]
mod tests {
    #[test] fn round_trip() {
        let k = super::new_key();
        let s = super::seal(&k, "秘密").unwrap();
        assert_eq!(super::open(&k, &s).unwrap(), "秘密");
        assert!(super::open(&super::new_key(), &s).is_err());
    }
}
