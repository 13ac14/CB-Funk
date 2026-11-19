import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../platform/desktop_window.dart';
import '../services/mqtt_service.dart';
import '../state/radio_controller.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets/knob.dart';
import 'widgets/lcd_display.dart';
import 'widgets/radio_button.dart';

class RadioScreen extends StatelessWidget {
  const RadioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final r = context.watch<RadioController>();
    // Das Funkgeraet ist eine feste Gestaltung: Eine stark vergroesserte
    // System-Schrift (Android "Schriftgroesse") sprengt sonst Tasten und
    // Display. Der Einstellungsdialog behaelt die volle Vergroesserung.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Scaffold(
        body: Container(
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
                  if (contentWidth >= 800 &&
                      contentWidth > constraints.maxHeight) {
                    return _landscape(context, r, constraints);
                  }
                  final horizontalPadding =
                      (contentWidth * 0.018).clamp(6.0, 18.0);
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
                            horizontalPadding, 8, horizontalPadding, 8),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
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
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _landscape(
    BuildContext context,
    RadioController r,
    BoxConstraints constraints,
  ) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF545B5A), Color(0xFF343A3C)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF171A1B), width: 3),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 14,
              offset: Offset(0, 7),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, panelConstraints) {
            final sideWidth =
                (panelConstraints.maxWidth * 0.145).clamp(122.0, 170.0);
            const gap = 12.0;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: sideWidth, child: _desktopLeftPanel(r)),
                    const SizedBox(width: gap),
                    Expanded(child: _desktopCenterPanel(context, r)),
                    const SizedBox(width: gap),
                    SizedBox(width: sideWidth, child: _desktopRightPanel(r)),
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
                          onPressed: () => unawaited(DesktopWindow.minimize()),
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
      ),
    );
  }

  Widget _windowButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        style: IconButton.styleFrom(
          foregroundColor: const Color(0xFFE5E8E6),
          backgroundColor: const Color(0x55343A3C),
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
          const Text(
            'CB-FUNK',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
              color: Color(0xFFE5E8E6),
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
          Expanded(child: _speakerGrille()),
          const SizedBox(height: 8),
          IconButton(
            iconSize: 42,
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

  Widget _speakerGrille() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF202426),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black54, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(15, (index) {
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
          color: const Color(0xFF9AA09D),
          borderRadius: BorderRadius.circular(4),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              offset: Offset(0, 1),
              blurRadius: 1,
            ),
          ],
        ),
      );

  Widget _desktopCenterPanel(BuildContext context, RadioController r) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final knobSize =
              ((constraints.maxWidth * 0.47 - 28) / 4).clamp(64.0, 100.0);
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
                            size: (constraints.maxHeight * 0.20)
                                .clamp(68.0, 104.0),
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
                      child: _desktopCard(
                        child: _desktopKeys(context, r),
                      ),
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

  Widget _desktopRightPanel(RadioController r) => Column(
        children: [
          if (Platform.isWindows) const SizedBox(height: 24),
          SizedBox(
            height: 132,
            child: _desktopCard(
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
                    onChanged: (value) =>
                        r.setMicSensitivity(0.5 + value * 1.5),
                    size: 74,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(child: _desktopPtt(r)),
        ],
      );

  Widget _desktopCard({required Widget child}) => Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: const Color(0xFF414849),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF252A2B), width: 2),
        ),
        child: child,
      );

  Widget _desktopKeys(BuildContext context, RadioController r) {
    Widget key(
      String label,
      VoidCallback onTap, {
      bool active = false,
      Color? color,
    }) =>
        RadioKey(
          label: label,
          onTap: onTap,
          active: active,
          textColor: color,
          height: 37,
          fontSize: 11,
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
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: r.transmitting
                  ? const [Color(0xFF8E2A2A), Color(0xFF5A1818)]
                  : const [Color(0xFFB8C0BE), Color(0xFF737D7B)],
            ),
            border: Border.all(color: const Color(0xFF202526), width: 3),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'PTT',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                  color: Color(0xFFF0F2F1),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                r.gatewayEnabled ? 'GATEWAY' : 'GEDRÜCKT HALTEN',
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

  Widget _header(RadioController r) => Row(children: [
        const Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CB-FUNK',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: CbColors.silverDark)),
            Text('80 Kanäle · FM/AM/USB/LSB',
                style: TextStyle(fontSize: 12, color: CbColors.textDim)),
          ]),
        ),
        Column(children: [
          IconButton(
            iconSize: 38,
            onPressed: r.togglePower,
            icon: Icon(Icons.power_settings_new,
                color: r.power ? CbColors.accentRed : CbColors.textDim),
            style: IconButton.styleFrom(
              side: BorderSide(
                  color: r.power ? CbColors.accentRed : CbColors.textDim,
                  width: 2),
            ),
          ),
          const Text('POWER',
              style: TextStyle(fontSize: 10, color: CbColors.textDim)),
        ]),
      ]);

  Widget _knobs(RadioController r, double knobSize) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Knob(
              label: 'LAUTST.',
              value: r.volume,
              onChanged: r.setVolume,
              size: knobSize),
          Knob(
              label: 'SQUELCH',
              value: r.squelch,
              onChanged: r.setSquelch,
              size: knobSize),
          Knob(
              label: 'RF-GAIN',
              value: r.rfGain,
              onChanged: r.setRfGain,
              size: knobSize),
          Knob(
              label: 'CLARIFIER',
              value: r.clarifier,
              onChanged: r.setClarifier,
              enabled: r.clarifierActive,
              size: knobSize),
        ],
      );

  Widget _row(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: children[i]),
          ]
        ]),
      );

  Widget _keys(BuildContext context, RadioController r) => Column(children: [
        _row([
          RadioKey(label: 'CH ▼', onTap: r.channelDown),
          RadioKey(label: 'CH ▲', onTap: r.channelUp),
          RadioKey(label: 'MODE', onTap: r.cycleModulation),
        ]),
        _row([
          RadioKey(
              label: 'CH 9', onTap: r.channel9, textColor: CbColors.accentRed),
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
              active: r.beep),
          RadioKey(label: 'SETUP', onTap: () => showSettings(context)),
        ]),
      ]);

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
          borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.circle,
              size: 12, color: online ? CbColors.online : CbColors.textDim),
          const SizedBox(width: 8),
          Text(txt, style: const TextStyle(color: CbColors.text)),
        ]),
        const SizedBox(height: 6),
        ValueListenableBuilder<double>(
          valueListenable: r.sMeterListenable,
          builder: (context, _, __) => Text(
            r.statusDetail,
            style: const TextStyle(fontSize: 12, color: CbColors.textDim),
          ),
        ),
      ]),
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
                    const Text('PTT',
                        style: TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 4)),
                    Text(
                        r.gatewayEnabled
                            ? 'Gateway aktiv – gesendet wird am Funkgerät'
                            : 'gedrückt halten zum Sprechen',
                        style: const TextStyle(
                            fontSize: 13, color: CbColors.textDim)),
                  ]),
            ),
          ),
        ),
      );
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
