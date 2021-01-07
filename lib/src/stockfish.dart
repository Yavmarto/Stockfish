import 'dart:async';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'ffi.dart';
import 'stockfish_state.dart';

class Stockfish {
  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();
  final _mainPort = ReceivePort();
  final _stdoutPort = ReceivePort();

  StreamSubscription _mainSubscription;
  StreamSubscription _stdoutSubscription;

  Stockfish._() {
    _mainSubscription = _mainPort.listen((message) {
      debugPrint('[stockfish] The main isolate sent $message');
      _dispose(message is int ? message : 1);
    });
    _stdoutSubscription = _stdoutPort.listen((message) {
      if (message is String) {
        _stdoutController.sink.add(message);
      } else {
        debugPrint('[stockfish] The stdout isolate sent $message');
      }
    });
    compute(_spawnIsolates, [_mainPort.sendPort, _stdoutPort.sendPort]).then(
      (success) => _state
          ._setValue(success ? StockfishState.ready : StockfishState.error),
      onError: (error) {
        debugPrint('[stockfish] The init isolate encountered an error $error');
        _dispose(1);
      },
    );
  }

  static Stockfish _instance;

  factory Stockfish() {
    if (_instance != null) {
      // only one instance can be used at a time
      // owner must issue `quit` command to dispose it before
      // a new instance can be created
      return null;
    }

    _instance = Stockfish._();
    return _instance;
  }

  ValueListenable<StockfishState> get state => _state;

  Stream<String> get stdout => _stdoutController.stream;

  set stdin(String line) {
    final pointer = Utf8.toUtf8('$line\n');
    nativeStdinWrite(pointer);
    free(pointer);
  }

  void _dispose(int exitCode) {
    _stdoutController.close();

    _mainSubscription?.cancel();
    _stdoutSubscription?.cancel();

    _state._setValue(
        exitCode == 0 ? StockfishState.disposed : StockfishState.error);

    _instance = null;
  }
}

const _quitok = 'quitok';

class _StockfishState extends ChangeNotifier
    implements ValueListenable<StockfishState> {
  StockfishState _value = StockfishState.starting;

  @override
  StockfishState get value => _value;

  _setValue(StockfishState v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }
}

void _isolateMain(SendPort mainPort) {
  final exitCode = nativeMain();
  mainPort.send(exitCode);

  debugPrint('[stockfish] nativeMain exitCode=$exitCode');
}

void _isolateStdout(SendPort stdoutPort) {
  String previous = '';

  while (true) {
    final pointer = nativeStdoutRead();

    if (pointer == null) {
      debugPrint('[stockfish] nativeStdoutRead pointer=null');
      return;
    }

    final data = previous + Utf8.fromUtf8(pointer);
    final lines = data.split('\n');
    previous = lines.removeLast();
    for (final line in lines) {
      stdoutPort.send(line);

      if (line == _quitok) {
        debugPrint('[stockfish] nativeStdoutRead line=$line');
        return;
      }
    }
  }
}

Future<bool> _spawnIsolates(List<SendPort> mainAndStdout) async {
  final initResult = nativeInit();
  if (initResult != 0) {
    debugPrint('[stockfish] initResult=$initResult');
    return false;
  }

  final stdoutIsolate = await Isolate.spawn(_isolateStdout, mainAndStdout[1])
      .catchError((error) => debugPrint('stdout error=$error'));
  if (stdoutIsolate == null) {
    debugPrint('[stockfish] Failed to spawn stdout isolate');
    return false;
  }

  final mainIsolate = await Isolate.spawn(_isolateMain, mainAndStdout[0])
      .catchError((error) => debugPrint('main error=$error'));
  if (mainIsolate == null) {
    debugPrint('[stockfish] Failed to spawn main isolate');
    return false;
  }

  return true;
}