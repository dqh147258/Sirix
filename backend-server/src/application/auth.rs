use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    let mut salt_bytes = [0u8; 16];
    OsRng.fill_bytes(&mut salt_bytes);
    let salt = hex::encode(salt_bytes);
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(password.as_bytes());
    let digest = hex::encode(hasher.finalize());
    Ok(format!("sha256${salt}${digest}"))
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let parts: Vec<&str> = hash.split('$').collect();
    if parts.len() != 3 {
        return false;
    }

    let salt = parts[1];
    let expected = parts[2];

    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(password.as_bytes());
    let current = hex::encode(hasher.finalize());

    current == expected
}

pub fn build_token_pair() -> (String, String) {
    let access_token = format!("atk_{}", Uuid::new_v4());
    let refresh_token = format!("rtk_{}", Uuid::new_v4());

    (access_token, refresh_token)
}
