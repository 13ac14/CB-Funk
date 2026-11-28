import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../services/aprs/aprs_codec.dart';
import '../services/aprs/aprs_service.dart';
import '../services/map_station_registry.dart';
import '../services/mqtt_service.dart';
import '../state/radio_controller.dart';
import 'settings_screen.dart';
import 'theme.dart';

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  bool _mapReady = false;
  String? _selectedStation;
  String? _hoveredStation;

  String _stationKey(MapStation station) =>
      '${station.callSign}:${station.senderId}';

  void _zoomBy(double amount) {
    if (!_mapReady) return;
    final camera = _mapController.camera;
    final zoom = (camera.zoom + amount).clamp(3.0, 18.0).toDouble();
    _mapController.move(camera.center, zoom);
  }

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioController>();
    // APRS-Stationen aktualisieren sich gebuendelt ueber den APRS-Dienst
    return ListenableBuilder(
      listenable: radio.aprs,
      builder: (context, _) => _buildMap(context, radio),
    );
  }

  /// APRS-Stationen (nur bei Opt-in), ohne Doppel zu Programm-Stationen.
  List<AprsStation> _aprsStations(
    RadioController radio,
    List<MapStation> stations,
  ) {
    if (!radio.aprsEnabled) return const <AprsStation>[];
    final own = <String>{
      for (final station in stations) ...[
        station.callSign.toUpperCase(),
        ?AprsCodec.callSign(station.callSign),
      ],
      ?radio.aprs.aprsCallSign,
    };
    return radio.aprs.stations
        .where((station) => !own.contains(station.name))
        .toList();
  }

  Widget _buildMap(BuildContext context, RadioController radio) {
    final stations = radio.mqtt.mapStations;
    final aprsStations = _aprsStations(radio, stations);
    final center = stations.isEmpty
        ? const LatLng(51.1657, 10.4515)
        : LatLng(stations.first.latitude, stations.first.longitude);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: widget.onBack,
                    tooltip: 'Zum Funkgerät',
                    icon: const Icon(Icons.radio),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LIVE-KARTE',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Text(
                          'Aktive Stationen · CB-Kanäle 1–80',
                          style: TextStyle(color: CbColors.textDim),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${stations.length} Station${stations.length == 1 ? '' : 'en'}'
                    '${radio.aprsEnabled ? ' · ${aprsStations.length} APRS' : ''}',
                    style: const TextStyle(
                      color: CbColors.displayBlue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => showSettings(context),
                    tooltip: 'Standort-Einstellungen',
                    icon: const Icon(Icons.settings),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: 6,
                          minZoom: 3,
                          maxZoom: 18,
                          onMapReady: () => setState(() => _mapReady = true),
                          onTap: (_, __) {
                            if (_selectedStation != null) {
                              setState(() => _selectedStation = null);
                            }
                          },
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'de.cbfunk.cb_funk',
                          ),
                          // APRS unter den eigenen Programm-Stationen
                          if (aprsStations.isNotEmpty)
                            MarkerLayer(
                              markers: [
                                for (final station in aprsStations)
                                  _aprsMarker(station),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              for (final station in stations)
                                _stationMarker(station),
                            ],
                          ),
                          const RichAttributionWidget(
                            attributions: [
                              TextSourceAttribution(
                                '© OpenStreetMap contributors',
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (stations.isEmpty && aprsStations.isEmpty)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.all(16),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: CbColors.bgBottom.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              radio.mqtt.state == LinkState.online
                                  ? 'Noch keine Station mit freigegebenem Standort'
                                  : 'Warte auf MQTT-Verbindung …',
                              style: const TextStyle(color: CbColors.text),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Material(
                          color: CbColors.bgBottom.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: _mapReady ? () => _zoomBy(1) : null,
                                tooltip: 'Vergrößern',
                                icon: const Icon(Icons.add),
                              ),
                              const Divider(height: 1),
                              IconButton(
                                onPressed: _mapReady ? () => _zoomBy(-1) : null,
                                tooltip: 'Verkleinern',
                                icon: const Icon(Icons.remove),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Marker _stationMarker(MapStation station) {
    final key = _stationKey(station);
    final showInfo = _selectedStation == key || _hoveredStation == key;
    return Marker(
      key: ValueKey(key),
      point: LatLng(station.latitude, station.longitude),
      width: 164,
      height: 94,
      alignment: Alignment.bottomCenter,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hoveredStation = key),
          onExit: (_) {
            if (_hoveredStation == key) {
              setState(() => _hoveredStation = null);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(
              () => _selectedStation = _selectedStation == key ? null : key,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showInfo) _stationInfo(station),
                if (showInfo) const SizedBox(height: 4),
                _AntennaMarker(transmitting: station.transmitting),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Marker _aprsMarker(AprsStation station) {
    final key = 'aprs:${station.name}';
    final showInfo = _selectedStation == key || _hoveredStation == key;
    return Marker(
      key: ValueKey(key),
      point: LatLng(station.latitude, station.longitude),
      width: 200,
      height: showInfo ? 96 : 28,
      alignment: Alignment.bottomCenter,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hoveredStation = key),
          onExit: (_) {
            if (_hoveredStation == key) {
              setState(() => _hoveredStation = null);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(
              () => _selectedStation = _selectedStation == key ? null : key,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showInfo) _aprsInfo(station),
                if (showInfo) const SizedBox(height: 4),
                _AprsDot(symbolCode: station.symbolCode),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _aprsInfo(AprsStation station) {
    final minutes = DateTime.now().difference(station.lastHeard).inMinutes;
    final age = minutes < 1 ? 'gerade eben' : 'vor $minutes min';
    final comment = station.comment.length > 60
        ? '${station.comment.substring(0, 60)}…'
        : station.comment;
    return Container(
      constraints: const BoxConstraints(maxWidth: 196),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xE8172028),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _AprsDot.color, width: 1.2),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 5, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${station.name} · APRS · $age',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (comment.isNotEmpty)
            Text(
              comment,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: CbColors.textDim, fontSize: 10.5),
            ),
        ],
      ),
    );
  }

  Widget _stationInfo(MapStation station) => Container(
    constraints: const BoxConstraints(maxWidth: 154),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xE8172028),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: CbColors.displayBlue, width: 1.2),
      boxShadow: const [
        BoxShadow(color: Colors.black45, blurRadius: 5, offset: Offset(0, 2)),
      ],
    ),
    child: Text(
      '${station.callSign} / Kanal ${station.channel}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _AntennaMarker extends StatefulWidget {
  const _AntennaMarker({required this.transmitting});

  final bool transmitting;

  @override
  State<_AntennaMarker> createState() => _AntennaMarkerState();
}

class _AntennaMarkerState extends State<_AntennaMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.transmitting) _pulse.repeat();
  }

  @override
  void didUpdateWidget(covariant _AntennaMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transmitting == oldWidget.transmitting) return;
    if (widget.transmitting) {
      _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 42,
    height: 42,
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final txColor = widget.transmitting
            ? const Color(0xFFFF725E)
            : CbColors.displayBlue;
        return Stack(
          alignment: Alignment.center,
          children: [
            if (widget.transmitting)
              Opacity(
                opacity: 1 - _pulse.value,
                child: Transform.scale(
                  scale: 0.65 + _pulse.value * 0.9,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: txColor, width: 2),
                    ),
                  ),
                ),
              ),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xE8172028),
                shape: BoxShape.circle,
                border: Border.all(color: txColor, width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(Icons.cell_tower, color: txColor, size: 22),
            ),
          ],
        );
      },
    ),
  );
}

/// Kleiner Marker fuer APRS-Stationen (Symbol grob nach APRS-Symbolcode).
class _AprsDot extends StatelessWidget {
  const _AprsDot({required this.symbolCode});

  static const Color color = Color(0xFFFFB74D);

  final String symbolCode;

  IconData get _icon => switch (symbolCode) {
    '>' || 'k' || 'u' || 'v' || 'j' || 'U' => Icons.directions_car,
    'X' || '^' || "'" || 'O' => Icons.flight,
    '_' || 'W' => Icons.wb_cloudy_outlined,
    '-' || 'y' => Icons.home_outlined,
    '#' || '&' || 'n' || 'r' || 'I' => Icons.settings_input_antenna,
    '[' => Icons.directions_walk,
    'b' => Icons.pedal_bike,
    's' || 'Y' => Icons.directions_boat,
    _ => Icons.place_outlined,
  };

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      color: const Color(0xE8172028),
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1.4),
      boxShadow: const [
        BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1)),
      ],
    ),
    child: Icon(_icon, color: color, size: 14),
  );
}
