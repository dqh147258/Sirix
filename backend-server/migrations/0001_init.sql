CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    client_version TEXT NOT NULL,
    auto_approve_screen_share BOOLEAN NOT NULL DEFAULT FALSE,
    last_seen_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS connection_requests (
    id UUID PRIMARY KEY,
    requester_user_id UUID NOT NULL,
    target_device_id UUID NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS share_sessions (
    id UUID PRIMARY KEY,
    request_id UUID NOT NULL,
    requester_user_id UUID NOT NULL,
    target_device_id UUID NOT NULL,
    state TEXT NOT NULL,
    selected_screen_id TEXT,
    quality_mode TEXT NOT NULL,
    quality_profile TEXT,
    pause_deadline_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS session_events (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS terminal_sessions (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL,
    creator_user_id UUID NOT NULL,
    title TEXT NOT NULL,
    shell TEXT NOT NULL,
    cwd TEXT NOT NULL,
    state TEXT NOT NULL,
    cols INTEGER NOT NULL,
    rows INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    closed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS terminal_session_participants (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL,
    user_id UUID NOT NULL,
    client_type TEXT NOT NULL,
    joined_at TIMESTAMPTZ NOT NULL
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'devices_user_id_fkey') THEN
        ALTER TABLE devices
            ADD CONSTRAINT devices_user_id_fkey
            FOREIGN KEY (user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'connection_requests_requester_user_id_fkey') THEN
        ALTER TABLE connection_requests
            ADD CONSTRAINT connection_requests_requester_user_id_fkey
            FOREIGN KEY (requester_user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'connection_requests_target_device_id_fkey') THEN
        ALTER TABLE connection_requests
            ADD CONSTRAINT connection_requests_target_device_id_fkey
            FOREIGN KEY (target_device_id)
            REFERENCES devices(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'share_sessions_request_id_fkey') THEN
        ALTER TABLE share_sessions
            ADD CONSTRAINT share_sessions_request_id_fkey
            FOREIGN KEY (request_id)
            REFERENCES connection_requests(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'share_sessions_requester_user_id_fkey') THEN
        ALTER TABLE share_sessions
            ADD CONSTRAINT share_sessions_requester_user_id_fkey
            FOREIGN KEY (requester_user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'share_sessions_target_device_id_fkey') THEN
        ALTER TABLE share_sessions
            ADD CONSTRAINT share_sessions_target_device_id_fkey
            FOREIGN KEY (target_device_id)
            REFERENCES devices(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'session_events_session_id_fkey') THEN
        ALTER TABLE session_events
            ADD CONSTRAINT session_events_session_id_fkey
            FOREIGN KEY (session_id)
            REFERENCES share_sessions(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'terminal_sessions_device_id_fkey') THEN
        ALTER TABLE terminal_sessions
            ADD CONSTRAINT terminal_sessions_device_id_fkey
            FOREIGN KEY (device_id)
            REFERENCES devices(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'terminal_sessions_creator_user_id_fkey') THEN
        ALTER TABLE terminal_sessions
            ADD CONSTRAINT terminal_sessions_creator_user_id_fkey
            FOREIGN KEY (creator_user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'terminal_session_participants_session_id_fkey') THEN
        ALTER TABLE terminal_session_participants
            ADD CONSTRAINT terminal_session_participants_session_id_fkey
            FOREIGN KEY (session_id)
            REFERENCES terminal_sessions(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'terminal_session_participants_user_id_fkey') THEN
        ALTER TABLE terminal_session_participants
            ADD CONSTRAINT terminal_session_participants_user_id_fkey
            FOREIGN KEY (user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen_at ON devices(last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_connection_requests_requester_user_id
    ON connection_requests(requester_user_id);
CREATE INDEX IF NOT EXISTS idx_connection_requests_target_device_id
    ON connection_requests(target_device_id);
CREATE INDEX IF NOT EXISTS idx_connection_requests_created_at
    ON connection_requests(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_share_sessions_request_id ON share_sessions(request_id);
CREATE INDEX IF NOT EXISTS idx_share_sessions_requester_user_id ON share_sessions(requester_user_id);
CREATE INDEX IF NOT EXISTS idx_share_sessions_target_device_id ON share_sessions(target_device_id);
CREATE INDEX IF NOT EXISTS idx_share_sessions_state ON share_sessions(state);
CREATE INDEX IF NOT EXISTS idx_share_sessions_updated_at ON share_sessions(updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_session_events_session_id_created_at
    ON session_events(session_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_terminal_sessions_device_id
    ON terminal_sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_creator_user_id
    ON terminal_sessions(creator_user_id);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_updated_at
    ON terminal_sessions(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_terminal_session_participants_session_id
    ON terminal_session_participants(session_id, joined_at DESC);
