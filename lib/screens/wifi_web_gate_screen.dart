import 'package:flutter/material.dart';

import '../theme.dart';

/// Web gate for the WiFi instrument: shown instead of the instrument
/// on web, where there is no WiFi scanning interface for the app to
/// use. An explicit dead end, not a live-looking screen and not the
/// old grey screen.
class WifiWebGateScreen extends StatelessWidget {
  const WifiWebGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WIFI')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          OutridePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text('WIFI SCANNING',
                          style: OutrideType.section(),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const Spacer(),
                    const OutrideChip(
                        label: 'NOT ON WEB', color: OutrideColors.amber),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'WiFi scanning is not available on web',
                  style: OutrideType.rowValue(OutrideColors.onDark)
                      .copyWith(fontSize: 15),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wi-Fi vision runs on Android — the web has no WiFi '
                  'scanning interface for the app to use, so this '
                  'instrument is gated off here instead of showing a '
                  'live-looking screen. Nothing is scanning. The Beam '
                  'picture is unaffected: WiFi only ever adds to it, it '
                  'never vetoes it.',
                  style: OutrideType.section(11).copyWith(height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
