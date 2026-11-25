// 循环视频壁纸的画面层:静音、无限循环,按「填满 / 居中」摆放,再按 alignX/alignY
// 平移。视频自己会动,烘不出静态图,所以这一层直接叠在 AppBackdrop 的渐变上。
//
// 控制器放在 [VideoWallpaperHandle] 里而不是 widget 的 State 里:同一画面要画两
// 次——整屏一层,聊天列表淡出的那条带子里再画一层(见 BackdropVeil)——两次都用
// 同一个控制器的纹理,所以只解码一遍。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../wallpaper/live_wallpaper.dart';

/// Owns the one [VideoPlayerController] of a looping wallpaper: it opens as soon
/// as it is made, plays without sound, and pauses while the app is in the
/// background.
class VideoWallpaperHandle extends ChangeNotifier with WidgetsBindingObserver {
  VideoWallpaperHandle(this.wallpaper) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(open());
  }

  VideoWallpaper wallpaper;

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _disposed = false;

  /// The controller to paint, once the file has been opened and sized.
  VideoPlayerController? get controller => _ready ? _controller : null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !_ready) return;
    switch (state) {
      case AppLifecycleState.resumed:
        controller.play();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        controller.pause();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  Future<void> open() async {
    final controller = VideoPlayerController.file(File(wallpaper.path));
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (error) {
      // 坏文件 / 播放器不认的编码:不播就是了,AppBackdrop 的渐变还在下面。
      debugPrint('video wallpaper: $error');
      return;
    }
    if (_disposed || _controller != controller) {
      await controller.dispose();
      return;
    }
    _ready = true;
    notifyListeners();
  }
}

class VideoWallpaperView extends StatelessWidget {
  const VideoWallpaperView({super.key, required this.handle});

  final VideoWallpaperHandle handle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: handle,
      builder: (context, _) {
        final controller = handle.controller;
        if (controller == null) return const SizedBox.expand();
        final size = controller.value.size;
        if (size.isEmpty) return const SizedBox.expand();
        final wallpaper = handle.wallpaper;
        return ClipRect(
          child: FittedBox(
            fit: wallpaper.fit == VideoFit.fill ? BoxFit.cover : BoxFit.contain,
            alignment: Alignment(wallpaper.alignX, wallpaper.alignY),
            child: SizedBox(width: size.width, height: size.height, child: VideoPlayer(controller)),
          ),
        );
      },
    );
  }
}
