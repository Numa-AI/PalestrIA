import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Media di un esercizio del catalogo: riproduce il **video** (autoplay, loop,
/// muto — come il `<video>` del web) se presente, altrimenti mostra l'immagine.
/// Durante l'init del video mostra l'immagine come placeholder; su errore video
/// resta l'immagine.
class ExerciseMediaView extends StatefulWidget {
  const ExerciseMediaView({
    super.key,
    this.videoUrl,
    this.imageUrl,
    this.height = 180,
    this.borderRadius = 12,
  });

  final String? videoUrl;
  final String? imageUrl;
  final double height;
  final double borderRadius;

  @override
  State<ExerciseMediaView> createState() => _ExerciseMediaViewState();
}

class _ExerciseMediaViewState extends State<ExerciseMediaView> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  @override
  void didUpdateWidget(ExerciseMediaView old) {
    super.didUpdateWidget(old);
    if (old.videoUrl != widget.videoUrl) {
      _controller?.dispose();
      _controller = null;
      _ready = false;
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    final url = widget.videoUrl;
    if (url == null || url.trim().isEmpty) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
      });
    } catch (_) {
      await controller.dispose(); // fallback: resta l'immagine
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.imageUrl != null && widget.imageUrl!.isNotEmpty;
    final showVideo = _ready && _controller != null;
    if (!showVideo && !hasImage) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: showVideo
            ? FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _controller!.value.size.width,
                  height: _controller!.value.size.height,
                  child: VideoPlayer(_controller!),
                ),
              )
            : CachedNetworkImage(
                imageUrl: widget.imageUrl!,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
      ),
    );
  }
}
