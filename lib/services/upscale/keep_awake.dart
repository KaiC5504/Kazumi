import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:kazumi/services/logging/logger.dart';

/// Stops Windows idle sleep while long jobs run, so a bake queue left
/// overnight isn't paused an hour in. The display can still turn off.
///
/// Uses a power request rather than SetThreadExecutionState because the
/// request belongs to a handle, not to whichever thread happened to call it.
/// It shows up in an elevated `powercfg /requests` under SYSTEM.
class KeepAwake {
  KeepAwake._();

  static final instance = KeepAwake._();

  static const _reason = 'Kazumi 正在烘焙或上传超分视频';
  static const _powerRequestSystemRequired = 1;
  static const _powerRequestContextSimpleString = 0x1;
  static const _invalidHandle = -1;

  int _holders = 0;
  int? _handle;

  bool get isHeld => _handle != null;

  void acquire() {
    if (_holders++ > 0 || !Platform.isWindows) return;
    try {
      _handle = _createRequest();
    } catch (e) {
      KazumiLogger().w('KeepAwake: power request failed', error: e);
    }
  }

  void release() {
    if (_holders == 0) return;
    if (--_holders > 0) return;
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    _powerClearRequest(handle, _powerRequestSystemRequired);
    _closeHandle(handle);
  }

  static int? _createRequest() {
    final context = calloc<_ReasonContext>();
    final reason = _reason.toNativeUtf16();
    try {
      context.ref
        ..version = 0
        ..flags = _powerRequestContextSimpleString
        ..simpleReasonString = reason;
      final handle = _powerCreateRequest(context);
      if (handle == _invalidHandle || handle == 0) {
        KazumiLogger().w('KeepAwake: PowerCreateRequest returned no handle');
        return null;
      }
      if (_powerSetRequest(handle, _powerRequestSystemRequired) == 0) {
        KazumiLogger().w('KeepAwake: PowerSetRequest failed');
        _closeHandle(handle);
        return null;
      }
      return handle;
    } finally {
      calloc.free(reason);
      calloc.free(context);
    }
  }
}

final class _ReasonContext extends Struct {
  @Uint32()
  external int version;

  @Uint32()
  external int flags;

  external Pointer<Utf16> simpleReasonString;

  // Rest of the REASON_CONTEXT union (its Detailed member is 24 bytes).
  @Array(16)
  external Array<Uint8> reserved;
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _powerCreateRequest = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<_ReasonContext>),
      int Function(Pointer<_ReasonContext>)
    >('PowerCreateRequest');

final _powerSetRequest = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'PowerSetRequest',
    );

final _powerClearRequest = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'PowerClearRequest',
    );

final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
