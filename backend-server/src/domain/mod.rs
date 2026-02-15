use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: Uuid,
    pub username: String,
    pub password_hash: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: Uuid,
    pub user_id: Uuid,
    pub device_name: String,
    pub platform: String,
    pub client_version: String,
    pub auto_approve_screen_share: bool,
    pub last_seen_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenInfo {
    pub screen_id: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub is_primary: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenSnapshot {
    pub screen_id: String,
    pub captured_at: DateTime<Utc>,
    pub width: u32,
    pub height: u32,
    pub preview_base64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionRequest {
    pub id: Uuid,
    pub requester_user_id: Uuid,
    pub target_device_id: Uuid,
    pub status: RequestStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RequestStatus {
    Requested,
    Accepted,
    Rejected,
}

impl RequestStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::Accepted => "accepted",
            Self::Rejected => "rejected",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareSession {
    pub id: Uuid,
    pub request_id: Uuid,
    pub requester_user_id: Uuid,
    pub target_device_id: Uuid,
    pub state: SessionState,
    pub selected_screen_id: Option<String>,
    pub quality_mode: QualityMode,
    pub quality_profile: Option<QualityProfile>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub pause_deadline_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Requested,
    PendingApproval,
    Connecting,
    Streaming,
    Paused,
    Terminated,
}

impl SessionState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::PendingApproval => "pending_approval",
            Self::Connecting => "connecting",
            Self::Streaming => "streaming",
            Self::Paused => "paused",
            Self::Terminated => "terminated",
        }
    }

    pub fn from_db(value: &str) -> Self {
        match value {
            "pending_approval" => Self::PendingApproval,
            "connecting" => Self::Connecting,
            "streaming" => Self::Streaming,
            "paused" => Self::Paused,
            "terminated" => Self::Terminated,
            _ => Self::Requested,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QualityMode {
    Manual,
    Auto,
}

impl QualityMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Auto => "auto",
        }
    }

    pub fn from_db(value: &str) -> Self {
        match value {
            "manual" => Self::Manual,
            _ => Self::Auto,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QualityProfile {
    P480,
    P720,
    P1080,
}

impl QualityProfile {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::P480 => "p480",
            Self::P720 => "p720",
            Self::P1080 => "p1080",
        }
    }

    pub fn from_db(value: &str) -> Self {
        match value {
            "p480" => Self::P480,
            "p1080" => Self::P1080,
            _ => Self::P720,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEvent {
    pub session_id: Uuid,
    pub event_type: String,
    pub created_at: DateTime<Utc>,
    pub payload: serde_json::Value,
}
