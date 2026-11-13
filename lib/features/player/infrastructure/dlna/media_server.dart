import 'dart:async';
import 'dart:io';
import 'dart:math';

/// A single leased open file, advertised only to the chosen IPv4 peer.
/// Caller owns the security scope and must await close() before releasing it.
class LeasedMediaServer {
  LeasedMediaServer._(
    this._server,
    this._file,
    this._length,
    this._peer,
    this.mimeType,
    this.token,
    this._ttl,
  ) {
    _renewExpiry();
    _subscription = _server.listen(_accept, onError: (Object _) {});
  }
  final HttpServer _server;
  final RandomAccessFile _file;
  final int _length;
  final InternetAddress _peer;
  final String mimeType;
  final String token;
  final Duration _ttl;
  Timer? _expiry;
  final Completer<void> _expired = Completer<void>();
  Future<void> get expired => _expired.future;
  late final StreamSubscription<HttpRequest> _subscription;
  final _active = <Future<void>>{};
  Future<void> _reads = Future.value();
  bool _revoked = false;
  Future<void>? _closing;

  static Future<LeasedMediaServer> start({
    required File file,
    required InternetAddress bind,
    required InternetAddress peer,
    Duration ttl = const Duration(minutes: 5),
  }) async {
    if (ttl <= Duration.zero) throw ArgumentError.value(ttl);
    if (bind.type != InternetAddressType.IPv4 ||
        peer.type != InternetAddressType.IPv4 ||
        bind.address == '0.0.0.0' ||
        peer.address == '0.0.0.0' ||
        peer.isMulticast) {
      throw ArgumentError('specific unicast IPv4 addresses required');
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      final len = await raf.length();
      // EBML's DocType follows variable-length header fields, so read a
      // bounded prefix rather than assuming the first four bytes identify MKV.
      final header = await raf.read(min(4096, len));
      final mime = _containerMime(header);
      final srv = await HttpServer.bind(bind, 0, shared: false);
      final rng = Random.secure();
      final token = List.generate(
        32,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      return LeasedMediaServer._(srv, raf, len, peer, mime, token, ttl);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  static String _containerMime(List<int> h) {
    if (h.length >= 8 &&
        h[4] == 0x66 &&
        h[5] == 0x74 &&
        h[6] == 0x79 &&
        h[7] == 0x70) {
      return 'video/mp4';
    }
    if (h.length >= 4 &&
        h[0] == 0x1a &&
        h[1] == 0x45 &&
        h[2] == 0xdf &&
        h[3] == 0xa3) {
      return _isWebm(h) ? 'video/webm' : 'video/x-matroska';
    }
    if (h.length >= 12 &&
        h[0] == 0x52 &&
        h[1] == 0x49 &&
        h[2] == 0x46 &&
        h[3] == 0x46 &&
        h[8] == 0x41 &&
        h[9] == 0x56 &&
        h[10] == 0x49 &&
        h[11] == 0x20) {
      return 'video/x-msvideo';
    }
    return 'application/octet-stream';
  }

  static bool _isWebm(List<int> h) {
    // Scan bounded header children until DocType is found, not a full EBML
    // validation. Parsing failures before DocType retain the Matroska fallback.
    (int, int)? sizeAt(int offset) {
      if (offset >= h.length) return null;
      final first = h[offset];
      var marker = 0x80;
      var width = 1;
      while (marker != 0 && first & marker == 0) {
        marker >>= 1;
        width++;
      }
      if (marker == 0 || offset + width > h.length) return null;
      var value = first & (marker - 1);
      for (var i = 1; i < width; i++) {
        if (value > h.length) return null;
        value = (value << 8) | h[offset + i];
      }
      return (width, value);
    }

    final headerSize = sizeAt(4);
    if (headerSize == null) return false;
    var offset = 4 + headerSize.$1;
    final end = offset + headerSize.$2;
    if (end > h.length) return false;
    while (offset < end) {
      final first = h[offset];
      var marker = 0x80;
      var idWidth = 1;
      while (marker != 0 && first & marker == 0) {
        marker >>= 1;
        idWidth++;
      }
      if (marker == 0 || idWidth > 4 || offset + idWidth > end) return false;
      final isDocType = idWidth == 2 && first == 0x42 && h[offset + 1] == 0x82;
      offset += idWidth;
      final size = sizeAt(offset);
      if (size == null) return false;
      offset += size.$1;
      if (offset + size.$2 > end) return false;
      if (isDocType) {
        return size.$2 == 4 &&
            h[offset] == 0x77 &&
            h[offset + 1] == 0x65 &&
            h[offset + 2] == 0x62 &&
            h[offset + 3] == 0x6d;
      }
      offset += size.$2;
    }
    return false;
  }

  Uri get uri => Uri(
    scheme: 'http',
    host: _server.address.address,
    port: _server.port,
    path: '/$token',
  );

  /// Renew only while the controller has confirmed the remote session remains active.
  void renew() {
    if (_revoked) throw StateError('lease is closed');
    _renewExpiry();
  }

  void _renewExpiry() {
    _expiry?.cancel();
    _expiry = Timer(_ttl, () {
      if (!_expired.isCompleted) _expired.complete();
      close().ignore();
    });
  }

  void _accept(HttpRequest req) {
    final future = _serve(req);
    _active.add(future);
    future.whenComplete(() => _active.remove(future)).ignore();
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _reads.then((_) => operation());
    _reads = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _serve(HttpRequest req) async {
    try {
      final res = req.response;
      final remote = req.connectionInfo?.remoteAddress;
      if (_revoked ||
          remote?.type != InternetAddressType.IPv4 ||
          remote?.address != _peer.address ||
          req.uri.path != '/$token' ||
          req.uri.hasQuery ||
          req.uri.hasFragment) {
        res.statusCode = HttpStatus.notFound;
      } else if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      } else {
        final ranges = req.headers[HttpHeaders.rangeHeader];
        final raw = ranges?.join(',');
        var start = 0;
        var end = _length - 1;
        if (raw != null) {
          final range = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(raw);
          if (range == null ||
              (range[1]!.isEmpty && range[2]!.isEmpty) ||
              _length == 0) {
            res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          } else if (range[1]!.isEmpty) {
            final suffix = int.tryParse(range[2]!) ?? 0;
            if (suffix <= 0) {
              res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            } else {
              start = max(0, _length - suffix);
            }
          } else {
            start = int.tryParse(range[1]!) ?? _length;
            if (range[2]!.isNotEmpty) {
              end = min(int.tryParse(range[2]!) ?? -1, end);
            }
            if (start >= _length || end < start) {
              res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            }
          }
          if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$_length');
          } else {
            res.statusCode = HttpStatus.partialContent;
            res.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/$_length',
            );
          }
        }
        res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        res.headers.set(HttpHeaders.contentTypeHeader, mimeType);
        res.headers.set('transferMode.dlna.org', 'Streaming');
        final count = res.statusCode == HttpStatus.requestedRangeNotSatisfiable
            ? 0
            : max(0, end - start + 1);
        res.contentLength = count;
        if (req.method == 'GET' && count > 0) {
          var offset = start;
          while (offset <= end && !_revoked) {
            final at = offset;
            final data = await _serialized(() async {
              if (_revoked) return <int>[];
              await _file.setPosition(at);
              return _file.read(min(65536, end - at + 1));
            });
            if (_revoked || data.isEmpty) break;
            res.add(data);
            offset += data.length;
            await res.flush();
          }
        }
      }
      await res.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Synchronous revocation precedes asynchronous draining. A timeout by a
  /// caller does not cancel this future or authorize releasing its file lease.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _revoked = true;
    _expiry?.cancel();
    return _closing = _close();
  }

  Future<void> _close() async {
    await _subscription.cancel();
    await _server.close(force: true);
    await Future.wait(List<Future<void>>.of(_active));
    await _reads;
    await _file.close();
  }
}
