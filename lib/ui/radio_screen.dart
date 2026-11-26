import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../platform/desktop_window.dart';
import '../models/enums.dart';
import '../services/mqtt_service.dart';
import '../state/radio_controller.dart';
import 'settings_screen.dart';
import 'live_map_screen.dart';
import 'digital_radio_overlay.dart';
import 'theme.dart';
import 'widgets/knob.dart';
import 'widgets/lcd_display.dart';
import 'widgets/radio_button.dart';
import '../services/packet_radio_service.dart';
import '../services/sstv_service.dart';

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  bool _showMap = false;
  DigitalOverlayMode? _digitalOverlay;
  SstvService? _sstvService;
  PacketRadioService? _packetRadioService;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      final radio = context.read<RadioController>();
      _sstvService = SstvService(radio);
      _packetRadioService = PacketRadioService(radio);
    }
  }

  @override
  void dispose() {
    _sstvService?.dispose();
    _packetRadioService?.dispose();
    super.dispose();
  }

  void _openDigital(RadioController radio, DigitalOverlayMode mode) {
    final targetChannel = mode == DigitalOverlayMode.sstv ? 25 : 24;
    if (!radio.power) radio.togglePower();
    radio.setChannel(targetChannel);
    radio.mqtt.joinChannel(targetChannel);
    _sstvService?.setActive(mode == DigitalOverlayMode.sstv);
    _packetRadioService?.setActive(mode == DigitalOverlayMode.packet);
    setState(() => _digitalOverlay = mode);
  }

  void _closeDigital() {
    _sstvService?.setActive(false);
    _packetRadioService?.setActive(false);
    setState(() => _digitalOverlay = null);
  }

  @override
  Widget build(BuildContext context) {
    final r = context.watch<RadioController>();
    if (Platform.isWindows && _showMap) {
      return LiveMapScreen(onBack: () => setState(() => _showMap = false));
    }
    // Das Funkgeraet ist eine feste Gestaltung: Eine stark vergroesserte
    // System-Schrift (Android "Schriftgroesse") sprengt sonst Tasten und
    // Display. Der Einstellungsdialog behaelt die volle Vergroesserung.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [CbColors.bgTop, CbColors.bgBottom],
                ),
              ),
              child: SafeArea(
                child: SizedBox.expand(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final contentWidth = constraints.maxWidth;
                      if (Platform.isWindows ||
                          (contentWidth >= 800 &&
                              contentWidth > constraints.maxHeight)) {
                        return _landscape(
                          context,
                          r,
                          constraints,
                          onShowMap: () => setState(() => _showMap = true),
                        );
                      }
                      final horizontalPadding = (contentWidth * 0.018).clamp(
                        6.0,
                        18.0,
                      );
                      final knobSize =
                          ((contentWidth - horizontalPadding * 2 - 30) / 4)
                              .clamp(64.0, 110.0);
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: contentWidth,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPadding,
                              8,
                              horizontalPadding,
                              8,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _header(r),
                                const SizedBox(height: 14),
                                LcdDisplay(radio: r),
                                const SizedBox(height: 14),
                                _knobs(r, knobSize),
                                const SizedBox(height: 14),
                                _keys(context, r),
                                const SizedBox(height: 12),
                                _status(r),
                                const SizedBox(height: 12),
                                _ptt(r),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (Platform.isWindows &&
                _digitalOverlay != null &&
                _sstvService != null &&
                _packetRadioService != null)
              DigitalRadioOverlay(
                mode: _digitalOverlay!,
                radio: r,
                sstv: _sstvService!,
                packet: _packetRadioService!,
                onClose: _closeDigital,
              ),
          ],
        ),
      ),
    );
  }

  Widget _landscape(
    BuildContext context,
    RadioController r,
    BoxConstraints constraints, {
    required VoidCallback onShowMap,
  }) {
    return Padding(
      padding: EdgeInsets.all(Platform.isWindows ? 7 : 10),
      child: Container(
        padding: EdgeInsets.all(Platform.isWindows ? 10 : 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: Platform.isWindows
                ? const [
                    Color(0xFF42251A),
                    Color(0xFF1D120D),
                    Color(0xFF352017),
                  ]
                : const [Color(0xFF545B5A), Color(0xFF343A3C)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Platform.isWindows
                ? const Color(0xFF9B6943)
                : const Color(0xFF171A1B),
            width: Platform.isWindows ? 2 : 3,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black54,
              blurRadius: Platform.isWindows ? 18 : 14,
              offset: Offset(0, 7),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (Platform.isWindows)
              const Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _WoodGrainPainter()),
                ),
              ),
            LayoutBuilder(
              builder: (context, panelConstraints) {
                final sideWidth = Platform.isWindows
                    ? (panelConstraints.maxWidth * 0.135).clamp(112.0, 154.0)
                    : (panelConstraints.maxWidth * 0.145).clamp(122.0, 170.0);
                final gap = Platform.isWindows ? 9.0 : 12.0;
                return Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: sideWidth, child: _desktopLeftPanel(r)),
                        SizedBox(width: gap),
                        Expanded(
                          child: Platform.isWindows
                              ? _windowsCenterPanel(context, r, onShowMap)
                              : _desktopCenterPanel(context, r),
                        ),
                        SizedBox(width: gap),
                        SizedBox(
                          width: sideWidth,
                          child: _desktopRightPanel(r),
                        ),
                      ],
                    ),
                    if (Platform.isWindows)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 84,
                        height: 18,
                        child: _DesktopDragRegion(),
                      ),
                    if (Platform.isWindows)
                      Positioned(
                        top: -12,
                        right: -12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _windowButton(
                              tooltip: 'Minimieren',
                              icon: Icons.remove,
                              onPressed: () =>
                                  unawaited(DesktopWindow.minimize()),
                            ),
                            const SizedBox(width: 6),
                            _windowButton(
                              tooltip: 'Schließen',
                              icon: Icons.close,
                              onPressed: () => unawaited(_closeApp(r)),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _windowButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
    style: IconButton.styleFrom(
      foregroundColor: const Color(0xFFFFE2B2),
      backgroundColor: const Color(0x88532818),
      side: const BorderSide(color: Color(0xFFB97943)),
      minimumSize: const Size(28, 28),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  /// Schliesst wie Alt+F4; RadioController.didRequestAppExit sichert vorher
  /// Einstellungen und beendet eine laufende Sendung.
  Future<void> _closeApp(RadioController r) => DesktopWindow.close();

  Widget _desktopLeftPanel(RadioController r) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'CB-FUNK',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.3,
          color: Platform.isWindows
              ? const Color(0xFFFFD89B)
              : const Color(0xFFE5E8E6),
        ),
      ),
      const SizedBox(height: 3),
      const Text(
        'CB-80 · FM · AM · USB · LSB',
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: 9, color: CbColors.textDim),
      ),
      const SizedBox(height: 12),
      if (Platform.isWindows) ...[
        Expanded(flex: 5, child: _onlineStations(r)),
        const SizedBox(height: 8),
        Expanded(flex: 4, child: _speakerGrille()),
      ] else
        Expanded(child: _speakerGrille()),
      const SizedBox(height: 8),
      _desktopPowerButton(r),
      const Center(
        child: Text(
          'POWER',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: CbColors.textDim,
          ),
        ),
      ),
    ],
  );

  Widget _onlineStations(RadioController r) {
    final online = r.mqtt.state == LinkState.online;
    final stations = r.mqtt.stationCallSigns(r.callSign);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Platform.isWindows
            ? const Color(0xFF24150F)
            : const Color(0xFF202426),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Platform.isWindows ? const Color(0xFF29140D) : Colors.black54,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'STATIONEN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: online ? CbColors.online : CbColors.textDim,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                online ? '${r.stationsOnChannel}' : '—',
                style: const TextStyle(
                  color: Color(0xFFFFD89B),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Expanded(
            child: !online
                ? const Center(
                    child: Text(
                      'Offline',
                      style: TextStyle(color: CbColors.textDim, fontSize: 10),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: stations.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) => Row(
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 6,
                          color: CbColors.online,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            stations[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE8D2B2),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _desktopPowerButton(RadioController r) {
    final color = r.power ? CbColors.accentRed : CbColors.textDim;
    if (!Platform.isWindows) {
      return IconButton(
        iconSize: 42,
        onPressed: r.togglePower,
        icon: Icon(Icons.power_settings_new, color: color),
        style: IconButton.styleFrom(side: BorderSide(color: color, width: 2)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6A4030), Color(0xFF180D0A)],
        ),
        border: Border.all(color: const Color(0xFF9D6846), width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color(0xA9000000),
            offset: Offset(0, 3),
            blurRadius: 5,
          ),
          BoxShadow(
            color: Color(0x558E5339),
            offset: Offset(0, -1),
            blurRadius: 1,
          ),
        ],
      ),
      child: IconButton(
        iconSize: 34,
        onPressed: r.togglePower,
        icon: Icon(Icons.power_settings_new, color: color),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF1B0D0C),
          side: BorderSide(color: color.withValues(alpha: 0.88), width: 1.5),
          shape: const CircleBorder(),
          minimumSize: const Size(46, 46),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _speakerGrille() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    decoration: BoxDecoration(
      color: Platform.isWindows
          ? const Color(0xFF24150F)
          : const Color(0xFF202426),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Platform.isWindows ? const Color(0xFF29140D) : Colors.black54,
        width: 2,
      ),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(Platform.isWindows ? 8 : 15, (index) {
        final firstFlex = index % 3 == 0 ? 3 : 5;
        return Row(
          children: [
            Expanded(flex: firstFlex, child: _speakerSlot()),
            const SizedBox(width: 6),
            Expanded(flex: 5, child: _speakerSlot()),
          ],
        );
      }),
    ),
  );

  Widget _speakerSlot() => Container(
    height: 4,
    decoration: BoxDecoration(
      color: Platform.isWindows
          ? const Color(0xFF130B08)
          : const Color(0xFF9AA09D),
      borderRadius: BorderRadius.circular(4),
      boxShadow: const [
        BoxShadow(color: Colors.black54, offset: Offset(0, 1), blurRadius: 1),
      ],
    ),
  );

  Widget _desktopCenterPanel(BuildContext context, RadioController r) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final knobSize = ((constraints.maxWidth * 0.47 - 28) / 4).clamp(
            64.0,
            100.0,
          );
          return Column(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Expanded(flex: 7, child: LcdDisplay(radio: r)),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _desktopCard(
                        child: Center(
                          child: Knob(
                            label: 'KANAL',
                            value: (r.channel - 1) / 79,
                            onChanged: (value) =>
                                r.setChannel((value * 79).round() + 1),
                            enabled: r.power,
                            size: (constraints.maxHeight * 0.20).clamp(
                              68.0,
                              104.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Expanded(
                      flex: 11,
                      child: _desktopCard(
                        child: Center(child: _knobs(r, knobSize)),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      flex: 12,
                      child: _desktopCard(child: _desktopKeys(context, r)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(height: 62, child: _status(r)),
            ],
          );
        },
      );

  Widget _windowsCenterPanel(
    BuildContext context,
    RadioController r,
    VoidCallback onShowMap,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final knobSize = ((constraints.maxWidth * 0.44 - 22) / 4).clamp(
        50.0,
        86.0,
      );
      return Column(
        children: [
          Expanded(
            flex: 7,
            child: Row(
              children: [
                Expanded(
                  flex: 8,
                  child: _desktopCard(
                    wood: true,
                    child: _SpectrumAnalyzer(radio: r),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _desktopCard(
                    wood: true,
                    child: Center(
                      child: Knob(
                        label: 'KANAL',
                        value: (r.channel - 1) / 79,
                        onChanged: (value) =>
                            r.setChannel((value * 79).round() + 1),
                        enabled: r.power,
                        chromeStyle: true,
                        size: (constraints.maxHeight * 0.23).clamp(80.0, 132.0),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 6,
            child: LcdDisplay(radio: r, compact: true, showFlags: false),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 6,
            child: Row(
              children: [
                Expanded(
                  flex: 11,
                  child: _desktopCard(
                    wood: true,
                    child: Center(
                      child: _knobs(r, knobSize, chromeStyle: true),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 12,
                  child: _desktopCard(
                    wood: true,
                    child: _desktopKeys(context, r, onShowMap: onShowMap),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(height: 38, child: _windowsStatus(r)),
        ],
      );
    },
  );

  Widget _windowsStatus(RadioController r) {
    final online = r.mqtt.state == LinkState.online;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF20140E),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF3C2417)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 9,
            color: online ? CbColors.online : const Color(0xFF84766B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              online
                  ? 'Online · ${r.stationsOnChannel} Station(en) auf Kanal ${r.channel} · ${r.statusDetail}'
                  : r.statusDetail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE8D2B2),
                fontSize: 10,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            r.modulation.label,
            style: const TextStyle(
              color: Color(0xFFFFD08B),
              fontWeight: FontWeight.w800,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopRightPanel(RadioController r) => Column(
    children: [
      if (Platform.isWindows) const SizedBox(height: 24),
      SizedBox(
        height: 132,
        child: _desktopCard(
          wood: Platform.isWindows,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'MIC',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                  color: CbColors.text,
                ),
              ),
              const SizedBox(height: 2),
              Knob(
                label: '',
                value: ((r.micSensitivity - 0.5) / 1.5).clamp(0.0, 1.0),
                onChanged: (value) => r.setMicSensitivity(0.5 + value * 1.5),
                size: 74,
                warmStyle: false,
                chromeStyle: Platform.isWindows,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      Expanded(child: _desktopPtt(r)),
    ],
  );

  Widget _desktopCard({required Widget child, bool wood = false}) => Container(
    width: double.infinity,
    height: double.infinity,
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: wood ? null : const Color(0xFF414849),
      gradient: wood
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF40261B), Color(0xFF281810)],
            )
          : null,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: wood ? const Color(0xFF21120C) : const Color(0xFF252A2B),
        width: 2,
      ),
    ),
    child: child,
  );

  Widget _desktopKeys(
    BuildContext context,
    RadioController r, {
    VoidCallback? onShowMap,
  }) {
    Widget key(
      String label,
      VoidCallback onTap, {
      bool active = false,
      Color? color,
    }) => RadioKey(
      label: label,
      onTap: onTap,
      active: active,
      textColor: color,
      height: 37,
      fontSize: 11,
      warmStyle: false,
      raisedStyle: Platform.isWindows,
    );

    Widget row(List<Widget> keys) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: keys[i]),
          ],
        ],
      ),
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        row([
          key('CH ▼', r.channelDown),
          key('CH ▲', r.channelUp),
          key('MODE', r.cycleModulation),
          key('SCAN', r.toggleScan, active: r.scanning),
        ]),
        row([
          key('CH 9', r.channel9, color: CbColors.accentRed),
          key('CH 19', r.channel19),
          key('NB/ANL', r.toggleNb, active: r.noiseBlanker),
          key('ECHO', r.toggleEcho, active: r.echo),
        ]),
        row([
          key('BEEP', r.cycleBeep, active: r.beep),
          key('PAPAGEI', r.toggleParrot, active: r.parrot),
          key('SETUP', () => showSettings(context)),
          if (Platform.isWindows && onShowMap != null) key('MAP', onShowMap),
        ]),
        if (Platform.isWindows)
          row([
            key(
              'SSTV · CH 25',
              () => _openDigital(r, DigitalOverlayMode.sstv),
              active: _digitalOverlay == DigitalOverlayMode.sstv,
            ),
            key(
              'PKT · CH 24',
              () => _openDigital(r, DigitalOverlayMode.packet),
              active: _digitalOverlay == DigitalOverlayMode.packet,
            ),
          ]),
      ],
    );
  }

  Widget _desktopPtt(RadioController r) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => r.pttDown(),
    onTapUp: (_) => r.pttUp(),
    onTapCancel: r.pttUp,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Platform.isWindows ? 16 : 22),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: r.transmitting
              ? const [Color(0xFF8E2A2A), Color(0xFF5A1818)]
              : Platform.isWindows
              ? const [Color(0xFF62573A), Color(0xFF45402B), Color(0xFF2C2A20)]
              : const [Color(0xFFB8C0BE), Color(0xFF737D7B)],
        ),
        border: Border.all(
          color: Platform.isWindows
              ? const Color(0xFF24170F)
              : const Color(0xFF202526),
          width: 3,
        ),
        boxShadow: Platform.isWindows
            ? const [
                BoxShadow(
                  color: Color(0xB8000000),
                  offset: Offset(0, 4),
                  blurRadius: 5,
                ),
                BoxShadow(
                  color: Color(0x558A7250),
                  offset: Offset(0, -1),
                  blurRadius: 1,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'PTT',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
              color: Platform.isWindows
                  ? const Color(0xFFFFE2B2)
                  : const Color(0xFFF0F2F1),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            r.digitalTransmitActive
                ? 'DIGITALSENDUNG'
                : r.gatewayEnabled
                ? 'GATEWAY'
                : 'GEDRÜCKT HALTEN',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
              color: Color(0xFF353B3B),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _header(RadioController r) => Row(
    children: [
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CB-FUNK',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: CbColors.silverDark,
              ),
            ),
            Text(
              '80 Kanäle · FM/AM/USB/LSB',
              style: TextStyle(fontSize: 12, color: CbColors.textDim),
            ),
          ],
        ),
      ),
      Column(
        children: [
          IconButton(
            iconSize: 38,
            onPressed: r.togglePower,
            icon: Icon(
              Icons.power_settings_new,
              color: r.power ? CbColors.accentRed : CbColors.textDim,
            ),
            style: IconButton.styleFrom(
              side: BorderSide(
                color: r.power ? CbColors.accentRed : CbColors.textDim,
                width: 2,
              ),
            ),
          ),
          const Text(
            'POWER',
            style: TextStyle(fontSize: 10, color: CbColors.textDim),
          ),
        ],
      ),
    ],
  );

  Widget _knobs(
    RadioController r,
    double knobSize, {
    bool warmStyle = false,
    bool chromeStyle = false,
  }) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Knob(
        label: 'LAUTST.',
        value: r.volume,
        onChanged: r.setVolume,
        size: knobSize,
        warmStyle: warmStyle,
        chromeStyle: chromeStyle,
      ),
      Knob(
        label: 'SQUELCH',
        value: r.squelch,
        onChanged: r.setSquelch,
        size: knobSize,
        warmStyle: warmStyle,
        chromeStyle: chromeStyle,
      ),
      Knob(
        label: 'RF-GAIN',
        value: r.rfGain,
        onChanged: r.setRfGain,
        size: knobSize,
        warmStyle: warmStyle,
        chromeStyle: chromeStyle,
      ),
      Knob(
        label: 'CLARIFIER',
        value: r.clarifier,
        onChanged: r.setClarifier,
        enabled: r.clarifierActive,
        size: knobSize,
        warmStyle: warmStyle,
        chromeStyle: chromeStyle,
      ),
    ],
  );

  Widget _row(List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: children[i]),
        ],
      ],
    ),
  );

  Widget _keys(BuildContext context, RadioController r) => Column(
    children: [
      _row([
        RadioKey(label: 'CH ▼', onTap: r.channelDown),
        RadioKey(label: 'CH ▲', onTap: r.channelUp),
        RadioKey(label: 'MODE', onTap: r.cycleModulation),
      ]),
      _row([
        RadioKey(
          label: 'CH 9',
          onTap: r.channel9,
          textColor: CbColors.accentRed,
        ),
        RadioKey(label: 'CH 19', onTap: r.channel19),
        RadioKey(label: 'SCAN', onTap: r.toggleScan, active: r.scanning),
        RadioKey(label: 'PAPAGEI', onTap: r.toggleParrot, active: r.parrot),
      ]),
      _row([
        RadioKey(label: 'NB/ANL', onTap: r.toggleNb, active: r.noiseBlanker),
        RadioKey(label: 'ECHO', onTap: r.toggleEcho, active: r.echo),
        RadioKey(
          label: r.beepMode == 0 ? 'BEEP' : 'BEEP ${r.beepMode}',
          onTap: r.cycleBeep,
          active: r.beep,
        ),
        RadioKey(label: 'SETUP', onTap: () => showSettings(context)),
      ]),
    ],
  );

  Widget _status(RadioController r) {
    final online = r.mqtt.state == LinkState.online;
    final txt = !r.power
        ? 'Aus'
        : online
        ? (r.scanning && !r.audio.rxActive
              ? 'Suchlauf läuft …'
              : 'Online · ${r.stationsOnChannel} Station(en) auf Kanal ${r.channel}')
        : r.mqtt.state == LinkState.connecting
        ? 'Verbinde …'
        : 'Offline';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2024),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 12,
                color: online ? CbColors.online : CbColors.textDim,
              ),
              const SizedBox(width: 8),
              Text(txt, style: const TextStyle(color: CbColors.text)),
            ],
          ),
          const SizedBox(height: 6),
          ValueListenableBuilder<double>(
            valueListenable: r.sMeterListenable,
            builder: (context, _, __) => Text(
              r.statusDetail,
              style: const TextStyle(fontSize: 12, color: CbColors.textDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ptt(RadioController r) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => r.pttDown(),
    onTapUp: (_) => r.pttUp(),
    onTapCancel: r.pttUp,
    child: SizedBox(
      height: 164,
      width: double.infinity,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 130,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(60),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: r.transmitting
                  ? const [Color(0xFF8E2A2A), Color(0xFF5A1818)]
                  : const [CbColors.metal, CbColors.metalDark],
            ),
            border: Border.all(color: Colors.black, width: 3),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'PTT',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                ),
              ),
              Text(
                r.digitalTransmitActive
                    ? 'Digitalsignal wird übertragen'
                    : r.gatewayEnabled
                    ? 'Gateway aktiv – gesendet wird am Funkgerät'
                    : 'gedrückt halten zum Sprechen',
                style: const TextStyle(fontSize: 13, color: CbColors.textDim),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SpectrumAnalyzer extends StatefulWidget {
  const _SpectrumAnalyzer({required this.radio});
  final RadioController radio;

  @override
  State<_SpectrumAnalyzer> createState() => _SpectrumAnalyzerState();
}

class _SpectrumAnalyzerState extends State<_SpectrumAnalyzer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radio = widget.radio;
    final online = radio.mqtt.state == LinkState.online;
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 9,
                color: online ? CbColors.online : const Color(0xFF6F6254),
              ),
              const SizedBox(width: 6),
              Text(
                online ? 'ONLINE' : 'OFFLINE',
                style: const TextStyle(
                  color: Color(0xFFE9D9BD),
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 8),
              _spectrumFlag('TX', radio.transmitting, const Color(0xFFFF514A)),
              ValueListenableBuilder<double>(
                valueListenable: radio.sMeterListenable,
                builder: (context, _, _) => _spectrumFlag(
                  'RX',
                  !radio.transmitting && radio.rxIndicator,
                  const Color(0xFF55F28A),
                ),
              ),
              _spectrumFlag('SCAN', radio.scanning, const Color(0xFFFFD27F)),
              _spectrumFlag('PAP', radio.parrot, const Color(0xFFDC9BFF)),
              _spectrumFlag('NB', radio.noiseBlanker, const Color(0xFF66D8FF)),
              _spectrumFlag('ECHO', radio.echo, const Color(0xFFFFAA65)),
              _spectrumFlag('RB', radio.beep, const Color(0xFF83B8FF)),
              _spectrumFlag(
                'EXT',
                radio.externalMicActive,
                const Color(0xFF5AE0D1),
              ),
              _spectrumFlag(
                'GW',
                radio.gatewayEnabled,
                const Color(0xFF8FDB72),
              ),
              const Spacer(),
              const Text(
                'SPECTRUM · 1–80',
                style: TextStyle(
                  color: Color(0xFFFFDBA5),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Expanded(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final levels = radio.mqtt.spectrumLevels;
              final currentIndex = radio.channel - 1;
              if (currentIndex >= 0 && currentIndex < levels.length) {
                final localActivity = radio.transmitting || radio.audio.rxActive
                    ? radio.sMeter
                    : 0.0;
                levels[currentIndex] = math.max(
                  levels[currentIndex],
                  localActivity,
                );
              }
              return CustomPaint(
                painter: _SpectrumPainter(
                  levels: levels,
                  currentChannel: radio.channel,
                  phase: _pulse.value,
                ),
                size: Size.infinite,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _spectrumFlag(String label, bool active, Color color) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.22) : const Color(0x22111111),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: active
              ? color.withValues(alpha: 0.95)
              : const Color(0x334A514B),
          width: active ? 1 : 0.7,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.62),
                  blurRadius: 9,
                  spreadRadius: 0.4,
                ),
              ]
            : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? const Color(0xFFFFFFFF) : const Color(0xFF77756C),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
          shadows: active ? [Shadow(color: color, blurRadius: 7)] : const [],
        ),
      ),
    ),
  );
}

class _SpectrumPainter extends CustomPainter {
  const _SpectrumPainter({
    required this.levels,
    required this.currentChannel,
    required this.phase,
  });

  final List<double> levels;
  final int currentChannel;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(7),
    );
    canvas.drawRRect(
      bg,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF101817), Color(0xFF07100F)],
        ).createShader(Offset.zero & size),
    );

    const left = 25.0;
    const right = 8.0;
    const top = 7.0;
    const bottom = 20.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left + 1, size.width - right),
      math.max(top + 1, size.height - bottom),
    );
    final grid = Paint()
      ..color = const Color(0x553A7660)
      ..strokeWidth = 0.7;
    for (var row = 0; row <= 4; row++) {
      final y = plot.top + plot.height * row / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _drawLabel(
        canvas,
        '${-row * 30} dB',
        Offset(1, y - 5),
        8,
        const Color(0xFF71837A),
      );
    }
    for (var channel = 1; channel <= 80; channel += 10) {
      final x = plot.left + (channel - 1) / 80 * plot.width;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _drawLabel(
        canvas,
        '$channel',
        Offset(x - 4, plot.bottom + 4),
        8,
        const Color(0xFFB9C6B8),
      );
    }
    _drawLabel(
      canvas,
      '80',
      Offset(plot.right - 9, plot.bottom + 4),
      8,
      const Color(0xFFB9C6B8),
    );

    final channelWidth = plot.width / 80;
    for (var i = 0; i < 80; i++) {
      var level = i < levels.length
          ? levels[i].clamp(0.0, 1.0).toDouble()
          : 0.0;
      if (level > 0.02) {
        level = (level * (0.94 + 0.06 * math.sin(phase * math.pi * 2 + i)))
            .clamp(0.0, 1.0)
            .toDouble();
      }
      if (level <= 0.01) continue;
      final barHeight = plot.height * level;
      final bar = Rect.fromLTWH(
        plot.left + i * channelWidth + 0.6,
        plot.bottom - barHeight,
        math.max(1.0, channelWidth - 1.2),
        barHeight,
      );
      final color = level > 0.82
          ? const Color(0xFFFF5849)
          : level > 0.55
          ? const Color(0xFFFFC34D)
          : const Color(0xFF56D27C);
      canvas.drawRect(bar, Paint()..color = color.withValues(alpha: 0.9));
    }

    if (currentChannel >= 1 && currentChannel <= 80) {
      final x = plot.left + (currentChannel - 0.5) * channelWidth;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = const Color(0x99FFE19A)
          ..strokeWidth = 1,
      );
    }
    canvas.drawRRect(
      bg,
      Paint()
        ..color = const Color(0xFF17231E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.currentChannel != currentChannel ||
      oldDelegate.phase != phase ||
      !listEquals(oldDelegate.levels, levels);
}

class _WoodGrainPainter extends CustomPainter {
  const _WoodGrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    for (var line = 0; line < 44; line++) {
      final baseY = size.height * line / 43;
      final path = Path()..moveTo(0, baseY);
      for (var x = 36.0; x <= size.width + 36; x += 36) {
        final wave = math.sin(x / 94 + line * 0.63) * 2.4;
        path.lineTo(x, baseY + wave);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line % 4 == 0
              ? const Color(0x30723A1E)
              : const Color(0x1DFFD096)
          ..strokeWidth = line % 4 == 0 ? 1.5 : 0.8
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_WoodGrainPainter oldDelegate) => false;
}

/// Ziehleiste oben am Fenster: Windows verschiebt das Fenster selbst, genau
/// wie beim Ziehen an einer normalen Titelleiste.
class _DesktopDragRegion extends StatelessWidget {
  const _DesktopDragRegion();

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => unawaited(DesktopWindow.startDrag()),
    child: const MouseRegion(
      cursor: SystemMouseCursors.move,
      child: SizedBox.expand(),
    ),
  );
}
