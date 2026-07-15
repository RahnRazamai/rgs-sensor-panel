import 'package:flutter/material.dart';

import 'rgs_windows_media.dart';

class RgsMusicPlayerWidget extends StatelessWidget {
  const RgsMusicPlayerWidget({
    super.key,
    required this.snapshot,
    required this.accent,
    this.busy = false,
    this.onPrevious,
    this.onTogglePlayPause,
    this.onNext,
  });

  final RgsMediaSnapshot snapshot;
  final Color accent;
  final bool busy;
  final VoidCallback? onPrevious;
  final VoidCallback? onTogglePlayPause;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    if (snapshot.sessionState == RgsMediaSessionState.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: accent,
                backgroundColor: const Color(0xFF101010),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Finding media',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              snapshot.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFBABAB7),
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    if (!snapshot.hasSession) {
      final unavailable =
          snapshot.sessionState == RgsMediaSessionState.unavailable;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              unavailable ? Icons.music_off_rounded : Icons.music_note_rounded,
              color: accent,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              unavailable ? 'Media controls unavailable' : 'Nothing playing',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              snapshot.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFBABAB7),
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    final title = snapshot.title.isEmpty ? 'Unknown title' : snapshot.title;
    final byline = _byline(snapshot);
    final progress = snapshot.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(
          byline,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFBABAB7), fontSize: 12),
        ),
        const Spacer(),
        if (progress != null) ...[
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            color: accent,
            backgroundColor: const Color(0xFF101010),
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                _formatDuration(snapshot.position),
                style: const TextStyle(
                  color: Color(0xFF858585),
                  fontSize: 9,
                ),
              ),
              const Spacer(),
              Text(
                _formatDuration(snapshot.duration),
                style: const TextStyle(
                  color: Color(0xFF858585),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _MediaButton(
              icon: Icons.skip_previous_rounded,
              tooltip: 'Previous track',
              onPressed: !busy && snapshot.canPrevious ? onPrevious : null,
            ),
            const SizedBox(width: 12),
            _MediaButton(
              icon: snapshot.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: snapshot.isPlaying ? 'Pause' : 'Play',
              accent: accent,
              prominent: true,
              onPressed: !busy && snapshot.canTogglePlayPause
                  ? onTogglePlayPause
                  : null,
            ),
            const SizedBox(width: 12),
            _MediaButton(
              icon: Icons.skip_next_rounded,
              tooltip: 'Next track',
              onPressed: !busy && snapshot.canNext ? onNext : null,
            ),
          ],
        ),
      ],
    );
  }

  static String _byline(RgsMediaSnapshot snapshot) {
    if (snapshot.artist.isNotEmpty && snapshot.album.isNotEmpty) {
      return '${snapshot.artist}  •  ${snapshot.album}';
    }
    if (snapshot.artist.isNotEmpty) {
      return snapshot.artist;
    }
    if (snapshot.album.isNotEmpty) {
      return snapshot.album;
    }
    if (snapshot.source.isNotEmpty) {
      return snapshot.source;
    }
    return 'Active Windows media session';
  }

  static String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _MediaButton extends StatelessWidget {
  const _MediaButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.accent,
    this.prominent = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? accent;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final size = prominent ? 42.0 : 36.0;
    return IconButton(
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      tooltip: tooltip,
      onPressed: onPressed,
      style: prominent
          ? IconButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: const Color(0xFF101010),
              disabledBackgroundColor: const Color(0xFF343434),
              disabledForegroundColor: const Color(0xFF858585),
            )
          : null,
      icon: Icon(icon, size: prominent ? 26 : 24),
    );
  }
}
