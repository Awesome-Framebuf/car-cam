import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The video picture with its capture buttons. Holds no logic of its own.
class CameraView extends StatelessWidget {
  const CameraView({
    super.key,
    required this.image,
    required this.isLive,
    required this.statusText,
    required this.isRecording,
    required this.recordingElapsed,
    required this.isFlashing,
    required this.onTakePhoto,
    required this.onToggleRecording,
    required this.onHelp,
    this.onToggleFullScreen,
    this.isFullScreen = false,
  });

  final ui.Image? image;
  final bool isLive;
  final String statusText;
  final bool isRecording;
  final Duration recordingElapsed;
  final bool isFlashing;
  final VoidCallback onTakePhoto;
  final VoidCallback onToggleRecording;
  final VoidCallback onHelp;

  /// Desktop only. When set, shows a full-screen button and lets a double
  /// click on the video toggle full screen. In full screen the buttons are
  /// hidden and only the video (and the recording badge) shows.
  final VoidCallback? onToggleFullScreen;
  final bool isFullScreen;

  @override
  Widget build(BuildContext context) {
    final picture = image;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          key: const ValueKey('camera-video'),
          behavior: HitTestBehavior.opaque,
          onDoubleTap: onToggleFullScreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (picture != null)
                RawImage(
                  image: picture,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.low,
                ),
            ],
          ),
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: isFlashing ? 0.7 : 0,
            duration: const Duration(milliseconds: 80),
            child: const ColoredBox(color: Colors.white),
          ),
        ),
        if (!isLive)
          IgnorePointer(child: Center(child: _StatusChip(statusText))),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                if (!isFullScreen)
                  Align(
                    alignment: Alignment.topLeft,
                    child: _RoundButton(
                      icon: Icons.help_outline,
                      tooltip: 'How to connect',
                      size: 44,
                      onPressed: onHelp,
                    ),
                  ),
                if (isRecording)
                  Align(
                    alignment: Alignment.topCenter,
                    child: _RecordingBadge(recordingElapsed),
                  ),
                if (onToggleFullScreen != null && !isFullScreen)
                  Align(
                    alignment: Alignment.topRight,
                    child: _RoundButton(
                      icon: Icons.fullscreen,
                      tooltip:
                          'Full screen (double-click the video; Esc to leave)',
                      size: 44,
                      onPressed: onToggleFullScreen,
                    ),
                  ),
                if (!isFullScreen)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RoundButton(
                          icon: Icons.photo_camera,
                          tooltip: 'Take photo',
                          size: 68,
                          onPressed: isLive ? onTakePhoto : null,
                        ),
                        const SizedBox(height: 20),
                        _RoundButton(
                          icon: isRecording ? Icons.stop : Icons.videocam,
                          tooltip: isRecording
                              ? 'Stop recording'
                              : 'Record video',
                          size: 68,
                          color: isRecording ? Colors.red : null,
                          onPressed: isLive || isRecording
                              ? onToggleRecording
                              : null,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        enabled: enabled,
        child: Material(
          color: color ?? Colors.black.withValues(alpha: enabled ? 0.55 : 0.25),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Icon(
                icon,
                size: size * 0.5,
                color: enabled ? Colors.white : Colors.white38,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge(this.elapsed);

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.circle, color: Colors.red, size: 14),
            const SizedBox(width: 8),
            Text(
              '$minutes:$seconds',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
    );
  }
}
