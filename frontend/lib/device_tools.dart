import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';

Future<Map<String, dynamic>> readDevice(bool location) async {
  int? level;
  try {
    final v = await Battery().batteryLevel;
    if (v >= 0 && v <= 100) level = v;
  } catch (_) {}
  Position? point;
  if (location) {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission was declined.');
    }
    point = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(timeLimit: Duration(seconds: 15)));
  }
  return {'battery': level, 'lat': point?.latitude, 'lon': point?.longitude};
}

class PreviewPane extends StatefulWidget {
  const PreviewPane({super.key});
  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> with WidgetsBindingObserver {
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      generation++;
      final previous = camera;
      if (previous != null) {
        setState(() => camera = null);
        previous.dispose();
      }
    }
  }

  CameraController? camera;
  String status = '';
  bool opening = false;
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    camera?.dispose();
    super.dispose();
  }

  Future<void> toggle() async {
    if (camera != null) {
      final old = camera;
      setState(() => camera = null);
      await old?.dispose();
      return;
    }
    setState(() {
      opening = true;
      status = '';
    });
    final attempt = generation;
    CameraController? next;
    try {
      final devices = await availableCameras();
      if (devices.isEmpty) throw StateError('No camera');
      final device = devices
              .where((e) => e.lensDirection == CameraLensDirection.front)
              .firstOrNull ??
          devices.first;
      next =
          CameraController(device, ResolutionPreset.medium, enableAudio: false);
      await next.initialize();
      if (mounted && generation == attempt) {
        setState(() => camera = next);
      } else {
        await next.dispose();
      }
    } catch (_) {
      await next?.dispose();
      if (mounted) {
        setState(() => status = 'Camera unavailable. Simulation still works.');
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        OutlinedButton(
            onPressed: opening ? null : toggle,
            child: Text(camera == null
                ? 'Open local camera preview'
                : 'Close camera preview')),
        if (camera != null)
          AspectRatio(
              aspectRatio: camera!.value.aspectRatio,
              child: CameraPreview(camera!)),
        if (status.isNotEmpty) Text(status),
      ]);
}
