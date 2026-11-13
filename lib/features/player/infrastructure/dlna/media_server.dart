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
      // QuickTime uses an ISO-style ftyp box too, but its major brand is
      // `qt  `. Only trust the brand when the complete bounded box is present.
      final size = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
      if (size >= 16 &&
          size <= h.length &&
          h[8] == 0x71 &&
          h[9] == 0x74 &&
          h[10] == 0x20 &&
          h[11] == 0x20) {
        return 'video/quicktime';
      }
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
    if (_isTransportStream(h)) return 'video/mp2t';
    return 'application/octet-stream';
  }

  static bool _isTransportStream(List<int> bytes) {
    // MPEG-TS uses 188-byte packets; Blu-ray transport streams prepend a
    // four-byte timestamp to each packet. Check four complete packet headers
    // so that a lone sync byte or a short file is not treated as video.
    bool matches(int packetSize, int prefix) {
      if (bytes.length < packetSize * 4) return false;
      for (var i = 0; i < 4; i++) {
        final offset = i * packetSize + prefix;
        if (bytes[offset] != 0x47) return false;
        final adaptation = (bytes[offset + 3] >> 4) & 0x03;
        if (adaptation == 0) return false;
        if ((adaptation & 0x02) != 0 && bytes[offset + 4] > 183) {
          return false;
        }
      }
      return true;
    }

    return matches(188, 0) || matches(192, 4);
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
        final requestedRange = ranges?.join(',');
        // Range applies to GET only. We do not publish a strong validator, so
        // an If-Range condition cannot be verified and must receive the whole
        // representation. Ignore unsupported units and multi-range requests
        // rather than returning 416 for ranges we have not evaluated.
        final raw =
            req.method == 'GET' &&
                req.headers[HttpHeaders.ifRangeHeader] == null &&
                requestedRange != null &&
                requestedRange.toLowerCase().startsWith('bytes=') &&
                !requestedRange.contains(',')
            ? requestedRange
            : null;
        var start = 0;
        var end = _length - 1;
        if (raw != null) {
          final range = RegExp(
            r'^bytes=(\d*)-(\d*)$',
            caseSensitive: false,
          ).firstMatch(raw);
          if (range == null ||
              (range[1]!.isEmpty && range[2]!.isEmpty) ||
              _length == 0) {
            res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          } else if (range[1]!.isEmpty) {
            final suffix = _boundedRangeNumber(range[2]!, _length);
            if (suffix <= 0) {
              res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            } else {
              start = max(0, _length - suffix);
            }
          } else {
            start = _boundedRangeNumber(range[1]!, _length);
            if (range[2]!.isNotEmpty) {
              end = _boundedRangeNumber(range[2]!, end);
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

  // HTTP byte positions can be arbitrarily large decimal numbers. Compare
  // their digits before parsing and cap them at the useful file boundary.
  static int _boundedRangeNumber(String digits, int limit) {
    var first = 0;
    while (first < digits.length && digits.codeUnitAt(first) == 48) {
      first++;
    }
    if (first == digits.length) return 0;
    final significant = digits.substring(first);
    final boundary = limit.toString();
    if (significant.length > boundary.length ||
        (significant.length == boundary.length &&
            significant.compareTo(boundary) > 0)) {
      return limit;
    }
    return int.parse(significant);
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
