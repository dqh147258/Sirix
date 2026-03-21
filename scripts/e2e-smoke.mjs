#!/usr/bin/env node

import { createRequire } from 'node:module';
import process from 'node:process';
import { setTimeout as delay } from 'node:timers/promises';

const apiBaseUrl = process.env.FREELOOM_API_BASE_URL ?? 'http://127.0.0.1:8080';
const desktopWsUrl = process.env.FREELOOM_DESKTOP_LOCAL_WS_URL ?? 'ws://127.0.0.1:9700/ws';
const require = createRequire(import.meta.url);
const wsImplSpecifier = process.env.FREELOOM_WS_IMPL ?? 'ws';
const WsImplModule = require(wsImplSpecifier);
const WsImpl = WsImplModule.WebSocket ?? WsImplModule.default ?? WsImplModule;

if (!WsImpl) {
  throw new Error('failed to load WebSocket implementation');
}

const username = process.env.FREELOOM_E2E_USERNAME ?? 'smoke_e2e';
const password = process.env.FREELOOM_E2E_PASSWORD ?? 'password123';

function log(step, detail) {
  const suffix = detail == null ? '' : ` ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`;
  console.log(`[e2e] ${step}${suffix}`);
}

async function api(path, { method = 'GET', token, body } = {}) {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body == null ? undefined : JSON.stringify(body),
  });

  const text = await response.text();
  let json;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = text;
    }
  }

  if (!response.ok) {
    throw new Error(`${method} ${path} failed: ${response.status} ${text}`);
  }

  return json;
}

async function registerOrLogin() {
  try {
    return await api('/api/v1/auth/register', {
      method: 'POST',
      body: { username, password },
    });
  } catch (error) {
    if (!String(error.message).includes('AUTH_USERNAME_EXISTS')) {
      throw error;
    }

    return api('/api/v1/auth/login', {
      method: 'POST',
      body: { username, password, client_type: 'smoke' },
    });
  }
}

function createJsonSocket(url, options = {}) {
  const socket = new WsImpl(url, options);
  const queue = [];
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });

  socket.onopen = () => readyResolve();
  socket.onerror = (event) => {
    const reason = event?.error?.message ?? event?.message ?? 'websocket error';
    readyReject(new Error(`${url} ${reason}`));
  };
  socket.onmessage = (event) => {
    const raw = typeof event.data === 'string' ? event.data : event.data.toString();
    const parsed = JSON.parse(raw);
    queue.push(parsed);
  };

  async function waitFor(predicate, label, timeoutMs = 15000) {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      for (let index = 0; index < queue.length; index += 1) {
        const message = queue[index];
        if (predicate(message)) {
          queue.splice(index, 1);
          return message;
        }
      }
      await delay(50);
    }
    throw new Error(`timed out waiting for ${label}`);
  }

  function send(payload) {
    socket.send(JSON.stringify(payload));
  }

  async function close() {
    await new Promise((resolve) => {
      socket.onclose = () => resolve();
      socket.close();
    });
  }

  return { socket, ready, waitFor, send, close };
}

async function main() {
  log('register.user');
  const auth = await registerOrLogin();

  log('connect.desktop.local_ws', desktopWsUrl);
  const desktopWs = createJsonSocket(desktopWsUrl);
  await desktopWs.ready;
  const settingsSync = await desktopWs.waitFor(
    (message) => message.type === 'settings.sync',
    'desktop settings.sync',
  );
  const deviceId = settingsSync.device_id;
  if (!deviceId) {
    throw new Error('desktop settings.sync missing device_id');
  }
  log('desktop.settings.sync', { deviceId, localWsPort: settingsSync.local_ws_port });

  log('register.device', deviceId);
  const device = await api('/api/v1/devices/register', {
    method: 'POST',
    token: auth.access_token,
    body: {
      device_name: `Desktop-${deviceId.slice(0, 8)}`,
      platform: 'desktop',
      client_version: '0.1.0',
      preferred_device_id: deviceId,
    },
  });

  await api(`/api/v1/devices/${deviceId}/settings`, {
    method: 'PATCH',
    token: auth.access_token,
    body: { auto_approve_screen_share: false },
  });

  log('connect.mobile.events_ws');
  const mobileWs = createJsonSocket(
    `${apiBaseUrl.replace(/^http/, 'ws')}/api/v1/mobile/events/ws`,
    {
      headers: { Authorization: `Bearer ${auth.access_token}` },
    },
  );
  await mobileWs.ready;

  const devices = await api('/api/v1/devices/my', { token: auth.access_token });
  const listedDevice = devices.find((entry) => entry.id === device.id);
  if (!listedDevice || !listedDevice.online) {
    throw new Error('registered desktop device is not online');
  }
  log('device.online.confirmed', listedDevice.id);

  log('create.connection_request');
  const connection = await api('/api/v1/connections/requests', {
    method: 'POST',
    token: auth.access_token,
    body: {
      target_device_id: device.id,
      initial_quality_profile: 'p720',
    },
  });

  const authorizeRequest = await desktopWs.waitFor(
    (message) => message.type === 'authorize.request',
    'desktop authorize.request',
  );
  log('desktop.authorize.request', authorizeRequest.session_id);
  desktopWs.send({
    type: 'authorize.response',
    session_id: authorizeRequest.session_id,
    decision: 'approve',
  });

  const acceptedEvent = await mobileWs.waitFor(
    (message) => message.type === 'connection.request.accepted',
    'mobile connection.request.accepted',
  );
  log('mobile.accepted', acceptedEvent.payload);

  log('mobile.send.offer');
  await api('/api/v1/webrtc/signal', {
    method: 'POST',
    token: auth.access_token,
    body: {
      session_id: connection.session_id,
      role: 'mobile',
      signal_type: 'offer',
      sdp: 'v=0\no=mobile 1 2 IN IP4 127.0.0.1\ns=freeloom\nt=0 0\na=group:BUNDLE 0\n',
    },
  });

  const desktopOffer = await desktopWs.waitFor(
    (message) => message.type === 'webrtc.offer',
    'desktop webrtc.offer',
  );
  log('desktop.received.offer', desktopOffer.payload?.session_id);
  desktopWs.send({
    type: 'webrtc.signal',
    session_id: connection.session_id,
    signal_type: 'answer',
    sdp: 'v=0\no=desktop 1 2 IN IP4 127.0.0.1\ns=freeloom\nt=0 0\na=group:BUNDLE 0\n',
  });

  const answerEvent = await mobileWs.waitFor(
    (message) => message.type === 'webrtc.answer',
    'mobile webrtc.answer',
  );
  log('mobile.received.answer', answerEvent.payload?.session_id);

  const streamingEvent = await mobileWs.waitFor(
    (message) =>
      message.type === 'session.state.changed' && message.payload?.state === 'streaming',
    'mobile session.state.changed streaming',
  );
  log('mobile.streaming', streamingEvent.payload);

  log('read.snapshots');
  const snapshots = await api(`/api/v1/devices/${device.id}/snapshots`, {
    token: auth.access_token,
  });
  if (!Array.isArray(snapshots) || snapshots.length === 0) {
    throw new Error('no snapshots returned');
  }
  log('snapshots.count', snapshots.length);

  log('pause.session');
  await api(`/api/v1/sessions/${connection.session_id}/pause`, {
    method: 'POST',
    token: auth.access_token,
  });
  await mobileWs.waitFor(
    (message) =>
      message.type === 'session.state.changed' && message.payload?.state === 'paused',
    'mobile session.state.changed paused',
  );

  log('resume.session');
  await api(`/api/v1/sessions/${connection.session_id}/resume`, {
    method: 'POST',
    token: auth.access_token,
  });
  await mobileWs.waitFor(
    (message) =>
      message.type === 'session.state.changed' && message.payload?.state === 'streaming',
    'mobile session.state.changed resumed streaming',
  );

  log('terminate.session');
  await api(`/api/v1/sessions/${connection.session_id}/terminate`, {
    method: 'POST',
    token: auth.access_token,
  });
  await mobileWs.waitFor(
    (message) =>
      message.type === 'session.state.changed' && message.payload?.state === 'terminated',
    'mobile session.state.changed terminated',
  );

  const sessionEvents = await api(`/api/v1/sessions/${connection.session_id}/events?limit=20`, {
    token: auth.access_token,
  });
  const eventTypes = sessionEvents.map((entry) => entry.event_type);
  log('session.events', eventTypes);

  await desktopWs.close();
  await mobileWs.close();
  log('success');
}

main().catch((error) => {
  console.error(`[e2e] failure ${error.stack ?? error.message}`);
  process.exitCode = 1;
});
