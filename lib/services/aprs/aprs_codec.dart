/// APRS-Hilfsfunktionen ohne Netzwerk: Passcode, Rufzeichen, Positions-
/// meldung und das Auslesen eingehender Pakete (APRS-IS-Textzeilen).
class AprsCodec {
  AprsCodec._();

  /// Zielkennung fuer selbst gesendete Pakete (APZ = experimentelle Software).
  static const String toCall = 'APZCBF';

  /// APRS-IS-Passcode aus dem Basis-Rufzeichen (ohne SSID), Standardverfahren.
  static int passcode(String callSign) {
    final base = callSign.trim().toUpperCase().split('-').first;
    var hash = 0x73e2;
    for (var i = 0; i < base.length; i += 2) {
      hash ^= base.codeUnitAt(i) << 8;
      if (i + 1 < base.length) hash ^= base.codeUnitAt(i + 1);
    }
    return hash & 0x7fff;
  }

  /// Rufzeichen in APRS-Form: Grossbuchstaben und Ziffern, optional "-SSID"
  /// (1-2 Zeichen), hoechstens 9 Zeichen. null, wenn nichts Brauchbares bleibt.
  /// Beispiele: "13cb123-5" -> "13CB123-5", "DK-ALPHA" -> "DKALPHA".
  static String? callSign(String input) {
    final upper = input.trim().toUpperCase();
    if (upper.isEmpty) return null;
    var base = upper;
    String? ssid;
    final dash = upper.lastIndexOf('-');
    if (dash > 0) {
      final candidate = upper.substring(dash + 1);
      if (RegExp(r'^[A-Z0-9]{1,2}$').hasMatch(candidate)) {
        base = upper.substring(0, dash);
        ssid = candidate;
      }
    }
    base = base.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (base.isEmpty) return null;
    final maxBase = ssid == null ? 9 : 9 - 1 - ssid.length;
    if (base.length > maxBase) base = base.substring(0, maxBase);
    return ssid == null ? base : '$base-$ssid';
  }

  /// Breite als APRS "DDMM.mmN".
  static String latitude(double value) => _coordinate(value, 2, 'N', 'S');

  /// Laenge als APRS "DDDMM.mmE".
  static String longitude(double value) => _coordinate(value, 3, 'E', 'W');

  static String _coordinate(
    double value,
    int degreeDigits,
    String positive,
    String negative,
  ) {
    final hemisphere = value >= 0 ? positive : negative;
    final absolute = value.abs();
    var degrees = absolute.floor();
    var hundredths = ((absolute - degrees) * 6000).round();
    if (hundredths >= 6000) {
      degrees++;
      hundredths -= 6000;
    }
    final minutes = (hundredths ~/ 100).toString().padLeft(2, '0');
    final fraction = (hundredths % 100).toString().padLeft(2, '0');
    return '${degrees.toString().padLeft(degreeDigits, '0')}'
        '$minutes.$fraction$hemisphere';
  }

  /// Positionsmeldung fuer APRS-IS (ohne Zeilenende). Symbol "/-" = Station
  /// (Haus). Der Kommentar wird auf druckbares ASCII gekuerzt.
  static String positionPacket({
    required String callSign,
    required double latitude,
    required double longitude,
    String comment = '',
  }) {
    final cleanComment = comment.replaceAll(RegExp(r'[^\x20-\x7e]'), '').trim();
    final shortComment = cleanComment.length > 43
        ? cleanComment.substring(0, 43)
        : cleanComment;
    return '$callSign>$toCall,TCPIP*:!${AprsCodec.latitude(latitude)}/'
        '${AprsCodec.longitude(longitude)}-$shortComment';
  }

  /// Liest eine APRS-IS-Zeile. null bei Serverzeilen (#), Paketen ohne
  /// Position oder unbekanntem Format.
  static AprsReport? parse(String line) {
    if (line.isEmpty || line.startsWith('#')) return null;
    final gt = line.indexOf('>');
    if (gt <= 0) return null;
    final colon = line.indexOf(':', gt);
    if (colon < 0 || colon + 1 >= line.length) return null;
    final source = line.substring(0, gt).trim().toUpperCase();
    final header = line.substring(gt + 1, colon);
    final destination = header.split(',').first;
    final info = line.substring(colon + 1);
    if (source.isEmpty) return null;

    switch (info[0]) {
      case '!':
      case '=':
        return _position(source, source, info.substring(1));
      case '/':
      case '@':
        if (info.length < 9) return null;
        return _position(source, source, info.substring(8));
      case ';':
        // Objekt: ;NAME_____*DDHHMMz<Position>
        if (info.length < 19) return null;
        final name = info.substring(1, 10).trim();
        if (name.isEmpty) return null;
        if (info[10] == '_') return AprsReport.removed(name, source);
        if (info[10] != '*') return null;
        return _position(name, source, info.substring(18));
      case ')':
        // Item: )NAME!<Position> bzw. )NAME_ (geloescht)
        final end = info.indexOf(RegExp(r'[!_]'), 1);
        if (end < 2 || end > 10) return null;
        final name = info.substring(1, end).trim();
        if (info[end] == '_') return AprsReport.removed(name, source);
        return _position(name, source, info.substring(end + 1));
      case '`':
      case "'":
        return _micE(source, destination, info);
    }
    return null;
  }

  static AprsReport? _position(String name, String source, String body) {
    if (body.isEmpty) return null;
    if (_isDigit(body.codeUnitAt(0))) {
      // Unkomprimiert: DDMM.mmN/DDDMM.mmE$
      if (body.length < 19) return null;
      final lat = _parseDegrees(body.substring(0, 8), 2, 'N', 'S', 90);
      final lon = _parseDegrees(body.substring(9, 18), 3, 'E', 'W', 180);
      if (lat == null || lon == null) return null;
      return AprsReport(
        name: name,
        source: source,
        latitude: lat,
        longitude: lon,
        symbolTable: body[8],
        symbolCode: body[18],
        comment: body.substring(19),
      );
    }
    // Komprimiert: T YYYY XXXX $ cs t
    if (body.length < 13) return null;
    final table = body[0];
    if (!RegExp(r'^[/\\A-Za-j]$').hasMatch(table)) return null;
    final y = _base91(body.substring(1, 5));
    final x = _base91(body.substring(5, 9));
    if (y == null || x == null) return null;
    final lat = 90 - y / 380926;
    final lon = -180 + x / 190463;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return AprsReport(
      name: name,
      source: source,
      latitude: lat,
      longitude: lon,
      symbolTable: table,
      symbolCode: body[9],
      comment: body.substring(13),
    );
  }

  static double? _parseDegrees(
    String text,
    int degreeDigits,
    String positive,
    String negative,
    double limit,
  ) {
    // Positionsmehrdeutigkeit: Leerzeichen statt Ziffern -> 0 (Mitte reicht)
    final value = text.replaceAll(' ', '0');
    final hemisphere = value[value.length - 1].toUpperCase();
    if (hemisphere != positive && hemisphere != negative) return null;
    final degrees = int.tryParse(value.substring(0, degreeDigits));
    final minutes = double.tryParse(
      value.substring(degreeDigits, value.length - 1),
    );
    if (degrees == null || minutes == null || minutes >= 60) return null;
    final result = degrees + minutes / 60;
    if (result > limit) return null;
    return hemisphere == negative ? -result : result;
  }

  static int? _base91(String text) {
    var value = 0;
    for (final unit in text.codeUnits) {
      if (unit < 33 || unit > 123) return null;
      value = value * 91 + (unit - 33);
    }
    return value;
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  /// Mic-E: Breite steckt in der Zieladresse, Laenge in den Infobytes.
  static AprsReport? _micE(String source, String destination, String info) {
    final dest = destination.split('-').first.toUpperCase();
    if (dest.length < 6 || info.length < 9) return null;
    final digits = <int>[];
    for (var i = 0; i < 6; i++) {
      final c = dest.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        digits.add(c - 0x30);
      } else if (c >= 0x41 && c <= 0x4a) {
        digits.add(c - 0x41); // A-J
      } else if (c >= 0x50 && c <= 0x59) {
        digits.add(c - 0x50); // P-Y
      } else if (c == 0x4b || c == 0x4c || c == 0x5a) {
        digits.add(0); // K, L, Z = Leerstelle
      } else {
        return null;
      }
    }
    bool high(int index) {
      final c = dest.codeUnitAt(index);
      return c >= 0x50 && c <= 0x5a; // P-Z
    }

    final latDegrees = digits[0] * 10 + digits[1];
    final latMinutes =
        digits[2] * 10 + digits[3] + (digits[4] * 10 + digits[5]) / 100;
    if (latDegrees > 90 || latMinutes >= 60) return null;
    var lat = latDegrees + latMinutes / 60;
    if (!high(3)) lat = -lat;

    var lonDegrees = info.codeUnitAt(1) - 28;
    if (high(4)) lonDegrees += 100;
    if (lonDegrees >= 180 && lonDegrees <= 189) {
      lonDegrees -= 80;
    } else if (lonDegrees >= 190 && lonDegrees <= 199) {
      lonDegrees -= 190;
    }
    var lonMinutes = info.codeUnitAt(2) - 28;
    if (lonMinutes >= 60) lonMinutes -= 60;
    final lonHundredths = info.codeUnitAt(3) - 28;
    if (lonDegrees < 0 ||
        lonDegrees > 180 ||
        lonMinutes < 0 ||
        lonHundredths < 0 ||
        lonHundredths > 99) {
      return null;
    }
    var lon = lonDegrees + (lonMinutes + lonHundredths / 100) / 60;
    if (lon > 180) return null;
    if (high(5)) lon = -lon;

    return AprsReport(
      name: source,
      source: source,
      latitude: lat,
      longitude: lon,
      symbolTable: info[8],
      symbolCode: info[7],
      comment: info.substring(9),
    );
  }
}

/// Ausgelesene APRS-Position (Station, Objekt oder Item).
class AprsReport {
  const AprsReport({
    required this.name,
    required this.source,
    required this.latitude,
    required this.longitude,
    required this.symbolTable,
    required this.symbolCode,
    required this.comment,
  }) : removed = false;

  const AprsReport.removed(this.name, this.source)
    : latitude = 0,
      longitude = 0,
      symbolTable = '/',
      symbolCode = ' ',
      comment = '',
      removed = true;

  /// Rufzeichen der Station bzw. Name des Objekts
  final String name;

  /// Absender des Pakets
  final String source;
  final double latitude;
  final double longitude;
  final String symbolTable;
  final String symbolCode;
  final String comment;

  /// Objekt/Item wurde vom Absender geloescht
  final bool removed;
}
