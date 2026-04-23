Map<String, dynamic> buildTerminalAttachMessage({
  required String terminalId,
  int protocolVersion = authorityTerminalProtocolVersion,
  String syncMode = authorityTerminalSyncMode,
  String clientKind = 'desktop_app',
}) {
  return {
    'type': 'terminal.attach',
    'payload': {
      'terminal_id': terminalId,
      'protocol_version': protocolVersion,
      'sync_mode': syncMode,
      'client_kind': clientKind,
    },
  };
}

bool isAuthorityTerminalProtocol({
  required int protocolVersion,
  required String? syncMode,
}) {
  return protocolVersion == authorityTerminalProtocolVersion &&
      syncMode == authorityTerminalSyncMode;
}

bool isCliRawFallbackTerminalProtocol({
  required int protocolVersion,
  required String? syncMode,
}) {
  return protocolVersion == rawStreamTerminalProtocolVersion &&
      syncMode == rawStreamTerminalSyncMode;
}

Map<String, dynamic> buildTerminalBootstrapRequestMessage({
  required String terminalId,
}) {
  return {
    'type': 'terminal.bootstrap.request',
    'payload': {
      'terminal_id': terminalId,
    },
  };
}

Map<String, dynamic> buildTerminalHistoryRangeRequestMessage({
  required String requestId,
  required String terminalId,
  int? historyGeneration,
  required int startLine,
  required int endLine,
}) {
  return {
    'type': 'terminal.history.range.request',
    'payload': {
      'request_id': requestId,
      'terminal_id': terminalId,
      'history_generation': historyGeneration,
      'start_line': startLine,
      'end_line': endLine,
    },
  };
}

Map<String, dynamic> buildTerminalDetachMessage({
  required String terminalId,
  required String clientKind,
  int? viewerPresenceEpoch,
}) {
  return {
    'type': 'terminal.detach',
    'payload': {
      'terminal_id': terminalId,
      'client_kind': clientKind,
      'viewer_presence_epoch': viewerPresenceEpoch,
    },
  };
}

Map<String, dynamic> buildTerminalInputMessage({
  required String terminalId,
  required String dataBase64,
}) {
  return {
    'type': 'terminal.input',
    'terminal_id': terminalId,
    'data_base64': dataBase64,
  };
}

Map<String, dynamic> buildTerminalResizeMessage({
  required String terminalId,
  required int cols,
  required int rows,
  required String clientKind,
  int? viewerPresenceEpoch,
}) {
  return {
    'type': 'terminal.resize',
    'terminal_id': terminalId,
    'cols': cols,
    'rows': rows,
    'client_kind': clientKind,
    'viewer_presence_epoch': viewerPresenceEpoch,
  };
}

Map<String, dynamic> buildTerminalCloseMessage({
  required String terminalId,
}) {
  return {
    'type': 'terminal.close',
    'terminal_id': terminalId,
  };
}

const int authorityTerminalProtocolVersion = 2;
const String authorityTerminalSyncMode = 'state-cache-v2';

const int rawStreamTerminalProtocolVersion = 1;
const String rawStreamTerminalSyncMode = 'raw-v1';

const String terminalReadyEventType = 'terminal.ready';
const String terminalStateSnapshotEventType = 'terminal.state.snapshot';
const String terminalScreenSnapshotEventType = 'terminal.screen.snapshot';
const String terminalHistoryAppendEventType = 'terminal.history.append';
const String terminalHistoryInvalidatedEventType = 'terminal.history.invalidated';
const String terminalHistoryRangeResponseEventType = 'terminal.history.range.response';
const String terminalHistoryRangeErrorEventType = 'terminal.history.range.error';
const String terminalLayoutChangedEventType = 'terminal.layout.changed';
const String terminalGeometryChangedEventType = 'terminal.geometry.changed';
const String terminalBufferChangedEventType = 'terminal.buffer.changed';
const String terminalScrollbackTrimmedEventType = 'terminal.scrollback.trimmed';
const String terminalOutputEventType = 'terminal.output';
const String terminalSnapshotEventType = 'terminal.snapshot';
