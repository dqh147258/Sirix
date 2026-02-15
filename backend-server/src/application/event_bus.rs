use std::{collections::HashMap, sync::Arc};

use tokio::sync::{broadcast, RwLock};

#[derive(Clone, Default)]
pub struct EventBus {
    channels: Arc<RwLock<HashMap<String, broadcast::Sender<String>>>>,
}

impl EventBus {
    pub async fn subscribe(&self, key: &str) -> broadcast::Receiver<String> {
        let mut guard = self.channels.write().await;
        let sender = guard
            .entry(key.to_string())
            .or_insert_with(|| {
                let (sender, _) = broadcast::channel(256);
                sender
            })
            .clone();
        sender.subscribe()
    }

    pub async fn publish(&self, key: &str, payload: String) -> usize {
        let sender = {
            let mut guard = self.channels.write().await;
            guard
                .entry(key.to_string())
                .or_insert_with(|| {
                    let (sender, _) = broadcast::channel(256);
                    sender
                })
                .clone()
        };

        sender.send(payload).unwrap_or_default()
    }
}
