import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:memex/data/services/avatar_media_service.dart';

/// Builds a DiceBear Notionists avatar URL from a seed string.
String dicebearUrl(String seed) => AvatarMediaService.diceBearUrl(seed);

/// Downloads and caches the avatar SVG for a given seed.
/// Returns the local file path, or null on failure.
Future<String?> cacheAvatarSvg(String seed) =>
    AvatarMediaService.cacheDiceBearSvg(seed);

/// Displays a DiceBear Notionists avatar as a circle.
///
/// [seed] is used to generate the avatar. If null, shows a placeholder icon.
/// Loads from local cache first, then fetches and stores the SVG if needed.
class DiceBearAvatar extends StatefulWidget {
  const DiceBearAvatar({
    super.key,
    required this.seed,
    this.size = 48,
    this.backgroundColor,
  });

  final String? seed;
  final double size;
  final Color? backgroundColor;

  @override
  State<DiceBearAvatar> createState() => _DiceBearAvatarState();
}

class _DiceBearAvatarState extends State<DiceBearAvatar> {
  Future<File?>? _avatarFileFuture;

  @override
  void initState() {
    super.initState();
    _avatarFileFuture = _futureForSeed(widget.seed);
  }

  @override
  void didUpdateWidget(covariant DiceBearAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seed != widget.seed) {
      _avatarFileFuture = _futureForSeed(widget.seed);
    }
  }

  Future<File?>? _futureForSeed(String? seed) {
    final cleanSeed = seed?.trim();
    if (cleanSeed == null || cleanSeed.isEmpty) return null;
    return AvatarMediaService.loadDiceBearSvg(cleanSeed);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seed == null || widget.seed!.isEmpty) {
      return _placeholder();
    }

    return ClipOval(
      child: Container(
        width: widget.size,
        height: widget.size,
        color: widget.backgroundColor ?? const Color(0xFFEEF2FF),
        child: FutureBuilder<File?>(
          future: _avatarFileFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _loadingIndicator();
            }

            if (snapshot.hasData && snapshot.data!.existsSync()) {
              try {
                return SvgPicture.file(
                  snapshot.data!,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _placeholder(),
                );
              } catch (_) {
                return _placeholder();
              }
            }
            return _placeholder();
          },
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? const Color(0xFFEEF2FF),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person,
        size: widget.size * 0.5,
        color: const Color(0xFF5B6CFF),
      ),
    );
  }

  Widget _loadingIndicator() {
    return Container(
      width: widget.size,
      height: widget.size,
      color: widget.backgroundColor ?? const Color(0xFFEEF2FF),
      child: Center(
        child: SizedBox(
          width: widget.size * 0.3,
          height: widget.size * 0.3,
          child: const CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF5B6CFF),
          ),
        ),
      ),
    );
  }
}
