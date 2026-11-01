import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Steps for joining the car's Wi-Fi, shown until video starts or on request.
class ConnectGuide extends StatelessWidget {
  const ConnectGuide({
    super.key,
    required this.onOpenSettings,
    this.onClose,
    this.platform,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback? onClose;

  /// Overrides the detected platform. Used when rendering screenshots.
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final isIos = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
    return ColoredBox(
      color: const Color(0xFF12161C),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Connect to your car',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.wifi),
                    label: Text(isIos ? 'Open Settings' : 'Open Wi-Fi settings'),
                  ),
                  if (onClose != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: onClose,
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _Steps(isIos: isIos)),
                      const SizedBox(width: 32),
                      Expanded(child: _Troubleshooting(isIos: isIos)),
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
}

class _Steps extends StatelessWidget {
  const _Steps({required this.isIos});

  final bool isIos;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Step(1, 'Turn on the car and wait a few seconds.'),
        _Step(
          2,
          isIos
              ? 'In Settings, tap Wi-Fi and choose the new network that appears when the car is on.'
              : 'In Wi-Fi settings, choose the new network that appears when the car is on.',
        ),
        _Step(
          3,
          isIos
              ? 'Come back here and tap Allow if asked about Local Network.'
              : 'If Android warns there is no internet, choose to stay connected.',
        ),
        const _Step(4, 'Video starts by itself. There is nothing else to press.'),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: Colors.blueAccent,
            child: Text(
              '$number',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Troubleshooting extends StatelessWidget {
  const _Troubleshooting({required this.isIos});

  static const _tipStyle = TextStyle(
    color: Colors.white70,
    fontSize: 14,
    height: 1.35,
  );

  final bool isIos;

  @override
  Widget build(BuildContext context) {
    final tips = [
      'Close the car maker\'s app, and disconnect any other phone from the car.',
      'Turn off any VPN.',
      if (isIos)
        'Check Settings > Privacy & Security > Local Network, and turn on Car Cam.'
      else
        'Turn off mobile data for a moment, then try again.',
      'Move closer to the car. Walls and distance weaken its Wi-Fi.',
      'Still stuck? Turn the car off and on, then rejoin its Wi-Fi.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'No video?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        for (final tip in tips)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ', style: _tipStyle),
                Expanded(child: Text(tip, style: _tipStyle)),
              ],
            ),
          ),
      ],
    );
  }
}
