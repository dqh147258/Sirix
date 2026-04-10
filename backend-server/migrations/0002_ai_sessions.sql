CREATE TABLE IF NOT EXISTS ai_sessions (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL,
    creator_user_id UUID NOT NULL,
    terminal_id UUID NOT NULL,
    workspace_root TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    model_id TEXT NOT NULL,
    status TEXT NOT NULL,
    entrypoint TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    closed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS ai_session_participants (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL,
    participant_type TEXT NOT NULL,
    client_instance_id TEXT,
    joined_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_session_approvals (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL,
    capability_key TEXT NOT NULL,
    decision TEXT NOT NULL,
    scope TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_sessions_device_id_fkey') THEN
        ALTER TABLE ai_sessions
            ADD CONSTRAINT ai_sessions_device_id_fkey
            FOREIGN KEY (device_id)
            REFERENCES devices(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_sessions_creator_user_id_fkey') THEN
        ALTER TABLE ai_sessions
            ADD CONSTRAINT ai_sessions_creator_user_id_fkey
            FOREIGN KEY (creator_user_id)
            REFERENCES users(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_sessions_terminal_id_fkey') THEN
        ALTER TABLE ai_sessions
            ADD CONSTRAINT ai_sessions_terminal_id_fkey
            FOREIGN KEY (terminal_id)
            REFERENCES terminal_sessions(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_session_participants_session_id_fkey') THEN
        ALTER TABLE ai_session_participants
            ADD CONSTRAINT ai_session_participants_session_id_fkey
            FOREIGN KEY (session_id)
            REFERENCES ai_sessions(id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_session_approvals_session_id_fkey') THEN
        ALTER TABLE ai_session_approvals
            ADD CONSTRAINT ai_session_approvals_session_id_fkey
            FOREIGN KEY (session_id)
            REFERENCES ai_sessions(id)
            ON DELETE CASCADE;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_sessions_terminal_id
    ON ai_sessions(terminal_id);
CREATE INDEX IF NOT EXISTS idx_ai_sessions_device_id
    ON ai_sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_ai_sessions_creator_user_id
    ON ai_sessions(creator_user_id);
CREATE INDEX IF NOT EXISTS idx_ai_sessions_updated_at
    ON ai_sessions(updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_ai_session_participants_session_id
    ON ai_session_participants(session_id, joined_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_session_approvals_session_id
    ON ai_session_approvals(session_id, created_at DESC);
