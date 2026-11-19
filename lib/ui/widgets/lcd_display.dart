import 'package:flutter/material.dart';
import '../../data/cb_channels.dart';
import '../../models/enums.dart';
import '../../state/radio_controller.dart';
import '../theme.dart';

/// Hauptdisplay: Kanal, Frequenz, Modulation (antippbar), S-Meter.
class LcdDisplay extends StatelessWidget {
  const LcdDisplay({super.key, required this.radio});
  final RadioController radio;

  @override
  Widget build(BuildContext context) {
    final on = radio.power;
    final blue = on ? CbColors.displayBlue : CbColors.displayDim;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: CbColors.displayBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black, width: 4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DefaultTextStyle(
          style: const TextStyle(fontSize: 11, letterSpacing: 1.2),
          child: Wrap(spacing: 8, children: [
            _flag('TX', radio.transmitting, on),
            ValueListenableBuilder<double>(
              valueListenable: radio.sMeterListenable,
              builder: (context, level, _) =>
                  _flag('RX', !radio.transmitting && level > 0.05, on),
            ),
            _flag('SCAN', radio.scanning, on),
            _flag('PAP', radio.parrot, on),
            _flag('NB', radio.noiseBlanker, on),
            _flag('ECHO', radio.echo, on),
            _flag('RB', radio.beep, on),
            _flag('EXT', radio.externalMicActive, on),
            _flag('GW', radio.gatewayEnabled, on),
          ]),
        ),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text(
            on ? radio.channel.toString().padLeft(2, '0') : '--',
            style: TextStyle(
                fontSize: 78,
                fontWeight: FontWeight.w700,
                color: blue,
                height: 1),
          ),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(
                onTap: radio.cycleModulation,
                child: Text(radio.modulation.label,
                    style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: blue)),
              ),
              const SizedBox(height: 4),
              Text(on ? CbChannels.frequencyLabel(radio.channel) : '--.--- MHz',
                  style: TextStyle(fontSize: 20, color: blue)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        ValueListenableBuilder<double>(
          valueListenable: radio.sMeterListenable,
          builder: (context, level, _) => SMeter(level: on ? level : 0),
        ),
      ]),
    );
  }

  Widget _flag(String t, bool active, bool on) => Text(t,
      style: TextStyle(
          color: on && active ? CbColors.displayBlue : CbColors.displayDim));
}

/// S-Meter: S1..S9 + 20/40 dB, Balken in hellem Rot.
class SMeter extends StatelessWidget {
  const SMeter({super.key, required this.level});
  final double level; // 0..1

  static const int segments = 13;

  @override
  Widget build(BuildContext context) {
    final lit = (level * segments).round();
    const labels = ['1', '3', '5', '7', '9', '+20', '+40'];
    return Column(children: [
      Row(children: [
        const Text('S',
            style: TextStyle(color: CbColors.displayBlue, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 22,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var i = 0; i < segments; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    height: 8 + i * 1.1,
                    decoration: BoxDecoration(
                      color: i < lit ? CbColors.meterRed : CbColors.displayDim,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.only(left: 18),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final l in labels)
            Text(l,
                style:
                    const TextStyle(color: CbColors.displayBlue, fontSize: 11)),
        ]),
      ),
    ]);
  }
}
