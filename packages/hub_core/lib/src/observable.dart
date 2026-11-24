import 'dart:async';

/// A value that notifies listeners when it changes (pure-Dart replacement for
/// Flutter's `ValueNotifier`). Listeners are called synchronously, only when
/// the new value differs from the old one.
class Observable<T> {
  Observable(this._value);

  T _value;
  final _changes = StreamController<T>.broadcast(sync: true);

  T get value => _value;

  set value(T next) {
    if (_value == next) return;
    _value = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// Emits each new value.
  Stream<T> get changes => _changes.stream;

  final Map<void Function(), StreamSubscription<T>> _listeners = {};

  void addListener(void Function() listener) {
    _listeners[listener]?.cancel();
    _listeners[listener] = _changes.stream.listen((_) => listener());
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener)?.cancel();
  }

  void dispose() {
    for (final s in _listeners.values) {
      s.cancel();
    }
    _listeners.clear();
    _changes.close();
  }
}
