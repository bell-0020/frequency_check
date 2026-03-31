import 'package:flutter/material.dart';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:audio_streamer/audio_streamer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async' as async;
import 'package:firebase_core/firebase_core.dart';

typedef FrequencyAudioNative =
    ffi.Void Function(
      ffi.Pointer<ffi.Int16> inputData,
      ffi.Pointer<ffi.Float> outputData,
      ffi.Int32 n,
    );
typedef FrequencyAudio =
    void Function(
      ffi.Pointer<ffi.Int16> inputData,
      ffi.Pointer<ffi.Float> outputData,
      int n,
    );

final dylib = ffi.DynamicLibrary.open('libanalyzer.so');
final frequencyAudio = dylib
    .lookupFunction<FrequencyAudioNative, FrequencyAudio>('frequency_audio');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(MaterialApp(debugShowCheckedModeBanner: false, home: mainPage()));
}

class mainPage extends StatefulWidget {
  const mainPage({super.key});

  @override
  State<mainPage> createState() => _mainPageState();
}

class _mainPageState extends State<mainPage> {
  List<double> spectrumData = [];
  int? selectedHz;
  bool Overflow = false;
  DateTime? _lastCaptureTime;
  bool isRecording = false;
  int recordSeconds = 0;
  bool isSending = false;
  Position? fixedPosition;
  bool isPositionFounding = false;

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  void _startListening() async {
    if (await Permission.microphone.request().isGranted) {
      AudioStreamer().audioStream.listen((List<double> buffer) {
        bool overflowFound = false;
        final int16Buffer = Int16List.fromList(
          buffer.map((sample) {
            if (sample >= 0.99 || sample <= -0.99) overflowFound = true;
            return (sample * 32767).toInt();
          }).toList(),
        );

        setState(() {
          Overflow = overflowFound;
        });

        if (int16Buffer.length >= 2048) {
          analyzeRawData(int16Buffer.sublist(0, 2048));
        }
      });
    }
  }

  void analyzeRawData(Int16List rawSamples) {
    final int n = 2048;

    final inputPtr = calloc<ffi.Int16>(n);
    final outputPtr = calloc<ffi.Float>(n ~/ 2);

    inputPtr.asTypedList(n).setAll(0, rawSamples);
    frequencyAudio(inputPtr, outputPtr, n);

    final List<double> fftResult = outputPtr.asTypedList(n ~/ 2).toList();
    setState(() {
      this.spectrumData = fftResult;
    });

    final now = DateTime.now();
    if (isRecording &&
        !isSending &&
        (_lastCaptureTime == null ||
            now.difference(_lastCaptureTime!).inSeconds >= 1)) {
      _lastCaptureTime = now;
      _collectAndSend(rawSamples);
    }

    calloc.free(inputPtr);
    calloc.free(outputPtr);
  }

  void _startRecordingTimer() async {
    if (isRecording) return;

    setState(() {
      isPositionFounding = true;
    });

    Position? pos = await _determinePosition();

    if (pos == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("位置情報が取得できませんでした。GPSを確認してください。")));
      setState(() {
        isPositionFounding = false;
      });
      return;
    }

    setState(() {
      fixedPosition = pos;
      isPositionFounding = false;
      isRecording = true;
      recordSeconds = 30;
      _lastCaptureTime = null;
    });

    async.Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        if (recordSeconds > 0) {
          recordSeconds--;
        } else {
          isRecording = false;
          timer.cancel();
        }
      });
    });
  }

  List<Map<String, dynamic>> getFormattedData() {
    if (spectrumData.isEmpty) return [];

    List<Map<String, dynamic>> displayPoints = [];
    const double samplingRate = 44100;
    const int n = 2048;
    const double binHz = samplingRate / n;

    for (int hz = 0; hz <= 20000; hz += 100) {
      int index = (hz / binHz).round();

      if (index < spectrumData.length) {
        displayPoints.add({'hz': hz, 'value': spectrumData[index]});
      }
    }
    return displayPoints;
  }

  Future<Position?> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    return await Geolocator.getCurrentPosition();
  }

  Future<void> _collectAndSend(Int16List rawSamples) async {
    if (fixedPosition == null) return;

    try {
      isSending = true;

      Map<String, double> frequencyMap = {};
      final points = getFormattedData();
      for (var p in points) {
        frequencyMap[p['hz'].toString()] = p['value'];
      }

      await FirebaseFirestore.instance.collection('SurveyData').add({
        'timestamp': FieldValue.serverTimestamp(),
        'lat': fixedPosition?.latitude,
        'lng': fixedPosition?.longitude,
        'data': frequencyMap,
        'is_overflow': Overflow,
      });
    } finally {
      isSending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = getFormattedData();

    return Scaffold(
      appBar: AppBar(
        title: Text(Overflow ? "OVERFLOW検知" : "周波数測定中"),
        centerTitle: true,
        backgroundColor: Overflow ? Color.fromARGB(255, 228, 29, 14) : null,
        foregroundColor: Overflow ? Colors.white : null,
      ),
      body: ListView.builder(
        itemCount: points.length,
        itemBuilder: (context, index) {
          final point = points[index];
          final int hz = point['hz'];
          final double rawVal = point['value'];
          double filteredVal = rawVal > 100 ? rawVal : 0;
          double normalizedValue = math.log(filteredVal + 1.0) / 15.0;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 70,
                  child: Text("${hz}Hz", style: TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: Container(
                    height: 10,
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: FractionallySizedBox(
                      widthFactor: normalizedValue.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: (isRecording || isPositionFounding)
            ? null
            : _startRecordingTimer,
        label: isRecording
            ? Text("測定中…", style: TextStyle(color: Colors.white))
            : isPositionFounding
            ? Text("位置情報取得中", style: TextStyle(color: Colors.white))
            : Text("測定", style: TextStyle(color: Colors.black)),
        icon: isRecording
            ? CircleAvatar(
                radius: 12,
                backgroundColor: Colors.transparent,
                child: Text(
                  "$recordSeconds",
                  style: TextStyle(fontSize: 15, color: Colors.white),
                ),
              )
            : isPositionFounding
            ? null
            : Icon(Icons.play_arrow, color: Colors.black),
        backgroundColor: isRecording
            ? Colors.grey
            : isPositionFounding
            ? Colors.grey
            : Colors.red[100],
      ),
    );
  }
}
