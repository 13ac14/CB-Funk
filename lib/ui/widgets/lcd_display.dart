import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../../data/cb_channels.dart';
import '../../models/enums.dart';
import '../../state/radio_controller.dart';
import '../theme.dart';

/// Hauptdisplay: Kanal, Frequenz, Modulation (antippbar), S-Meter.
class LcdDisplay extends StatelessWidget {
  const LcdDisplay({
    super.key,
    required this.radio,
    this.compact = false,
    this.showFlags = true,
  });
  final RadioController radio;
  final bool compact;
  final bool showFlags;

  @override
  Widget build(BuildContext context) {
    final on = radio.power;
    final blue = on ? CbColors.displayBlue : CbColors.displayDim;

    return Container(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 16,
        compact ? 7 : 12,
        compact ? 12 : 16,
        compact ? 7 : 12,
      ),
      decoration: BoxDecoration(
        color: CbColors.displayBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black, width: 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showFlags)
            DefaultTextStyle(
              style: TextStyle(fontSize: compact ? 8 : 11, letterSpacing: 1.2),
              child: Wrap(
                spacing: 8,
                children: [
                  _flag('TX', radio.transmitting, on),
                  ValueListenableBuilder<double>(
                    valueListenable: radio.sMeterListenable,
                    builder: (context, _, _) => _flag(
                      'RX',
                      !radio.transmitting && radio.rxIndicator,
                      on,
                    ),
                  ),
                  _flag('SCAN', radio.scanning, on),
                  _flag('PAP', radio.parrot, on),
                  _flag('NB', radio.noiseBlanker, on),
                  _flag('ECHO', radio.echo, on),
                  _flag('RB', radio.beep, on),
                  _flag('EXT', radio.externalMicActive, on),
                  _flag('GW', radio.gatewayEnabled, on),
                ],
              ),
            ),
          if (showFlags) SizedBox(height: compact ? 3 : 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                on ? radio.channel.toString().padLeft(2, '0') : '--',
                style: TextStyle(
                  fontSize: compact ? 84 : 78,
                  fontWeight: FontWeight.w700,
                  color: blue,
                  height: 1,
                ),
              ),
              SizedBox(width: compact ? 10 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: radio.cycleModulation,
                      child: Text(
                        radio.modulation.label,
                        style: TextStyle(
                          fontSize: compact ? 32 : 30,
                          fontWeight: FontWeight.w700,
                          color: blue,
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 1 : 4),
                    Text(
                      on
                          ? CbChannels.frequencyLabel(radio.channel)
                          : '--.--- MHz',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: compact ? 38 : 20,
                        fontWeight: compact
                            ? FontWeight.w700
                            : FontWeight.normal,
                        letterSpacing: compact ? 0.35 : 0,
                        height: compact ? 1 : null,
                        color: blue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 3 : 8),
          ValueListenableBuilder<double>(
            valueListenable: radio.sMeterListenable,
            builder: (context, level, _) => SMeter(
              level: on ? level : 0,
              compact: compact,
              color: compact ? CbColors.displayBlue : CbColors.meterRed,
            ),
          ),
          if (defaultTargetPlatform == TargetPlatform.windows) ...[
            SizedBox(height: compact ? 2 : 5),
            Text(
              _speakerLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: blue,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _speakerLabel {
    if (radio.transmitting) {
      final own = radio.callSign.trim();
      return 'TX · ${own.isEmpty ? 'Eigene Station' : own}';
    }
    final remote = radio.mqtt.activeTalkerCallSign;
    if (remote != null) return 'RX · $remote';
    if (radio.audio.rxActive) return 'RX · Gegenstation';
    return 'Sprecher: —';
  }

  Widget _flag(String t, bool active, bool on) => Text(
    t,
    style: TextStyle(
      color: on && active ? CbColors.displayBlue : CbColors.displayDim,
    ),
  );
}

/// S-Meter: S1..S9 + 20/40 dB, Balken in hellem Rot.
class SMeter extends StatelessWidget {
  const SMeter({
    super.key,
    required this.level,
    this.compact = false,
    this.color = CbColors.meterRed,
  });
  final double level; // 0..1
  final bool compact;
  final Color color;

  static const int segments = 13;

  @override
  Widget build(BuildContext context) {
    final lit = (level * segments).round();
    const labels = ['1', '3', '5', '7', '9', '+20', '+40'];
    return Column(
      children: [
        Row(
          children: [
            Text(
              'S',
              style: TextStyle(
                color: CbColors.displayBlue,
                fontSize: compact ? 9 : 12,
              ),
            ),
            SizedBox(width: compact ? 5 : 8),
            Expanded(
              child: SizedBox(
                height: compact ? 17 : 22,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < segments; i++)
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          height: 8 + i * 1.1,
                          decoration: BoxDecoration(
                            color: i < lit ? color : CbColors.displayDim,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 0 : 2),
        Padding(
          padding: EdgeInsets.only(left: compact ? 14 : 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final l in labels)
                Text(
                  l,
                  style: TextStyle(
                    color: CbColors.displayBlue,
                    fontSize: compact ? 8 : 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
