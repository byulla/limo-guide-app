// lib/main.dart — 장애물 안내 앱 (목업 디자인 완전판)
// 화면: 메인(연결배지·위험카드·마지막발화·정지버튼) + 설정(거리·속도·주기·진동)
// 설정값은 실제 동작에 반영되고 기기에 저장됨
//
// 설치: flutter pub add flutter_tts vibration web_socket_channel shared_preferences

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ★ 서버 주소: 시뮬레이터=localhost, 실기기=맥/로봇 IP
const String serverUrl = 'ws://192.168.55.1:8765';

// ===== 색상 (목업 팔레트) =====
const cGreenBg = Color(0xFFEAF3DE);
const cGreenText = Color(0xFF3B6D11);
const cRedBg = Color(0xFFFCEBEB);
const cRedDark = Color(0xFF791F1F);
const cRedMid = Color(0xFFA32D2D);
const cGrayBg = Color(0xFFF3F2EC);
const cTextSec = Color(0xFF5F5E5A);
const cTextMut = Color(0xFF8A897F);
const cDark = Color(0xFF2C2C2A);

// ===== 설정 (저장/로드) =====
class Settings {
  double warnDistance = 1.5;   // 경고 시작 거리 (m)
  double speechRate = 1.0;     // 음성 속도 (배)
  int repeatGapSec = 3;        // 안내 반복 주기 (초)
  bool vibrate = true;         // 진동 알림
  double emergencyDistance = 0.5; // 긴급 정지 거리 (m)

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    warnDistance = p.getDouble('warnDistance') ?? 1.5;
    speechRate = p.getDouble('speechRate') ?? 1.0;
    repeatGapSec = p.getInt('repeatGapSec') ?? 3;
    vibrate = p.getBool('vibrate') ?? true;
    emergencyDistance = p.getDouble('emergencyDistance') ?? 0.5;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('warnDistance', warnDistance);
    await p.setDouble('speechRate', speechRate);
    await p.setInt('repeatGapSec', repeatGapSec);
    await p.setBool('vibrate', vibrate);
    await p.setDouble('emergencyDistance', emergencyDistance);
  }
}

final settings = Settings();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  runApp(const GuideApp());
}

class GuideApp extends StatelessWidget {
  const GuideApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '장애물 안내',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: Colors.white),
    home: const MainScreen(),
  );
}

// ================= 메인 화면 =================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final FlutterTts tts = FlutterTts();
  WebSocketChannel? channel;

  bool guiding = true;
  bool connected = false;
  Map<String, dynamic>? lastMsg;
  String lastSpoken = '';

  String _prevSentence = '';
  DateTime _prevTime = DateTime.fromMillisecondsSinceEpoch(0);

  static const typeKo = {
    'person': '사람', 'chair': '의자', 'box': '상자',
    'door': '문', 'obstacle': '장애물', 'stairs': '계단',
  };
  static const dirKo = {'front': '전방', 'left': '왼쪽', 'right': '오른쪽'};

  @override
  void initState() {
    super.initState();
    tts.setLanguage('ko-KR');
    _applySpeechRate();
    _connect();
  }

  void _applySpeechRate() {
    // flutter_tts는 0.5가 보통 속도 → 배율을 매핑
    tts.setSpeechRate(0.5 * settings.speechRate);
  }

  void _connect() {
    try {
      channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      channel!.stream.listen(
            (data) {
          if (!connected) setState(() => connected = true);
          _onMessage(jsonDecode(data as String) as Map<String, dynamic>);
        },
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
      );
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    if (connected) _speak('연결이 끊어져 정지했습니다.', urgent: true);
    setState(() => connected = false);
    Future.delayed(const Duration(seconds: 3), _connect);
  }

  void _onMessage(Map<String, dynamic> msg) {
    setState(() => lastMsg = msg);
    if (!guiding) return;

    final dist = (msg['distance'] as num?)?.toDouble() ?? 99.0;
    var urgency = msg['urgency'] as String? ?? 'info';

    // 설정값 반영: 거리 기준으로 로컬 판정 보정
    if (msg['type'] != 'none') {
      if (dist <= settings.emergencyDistance) {
        urgency = 'emergency';
      } else if (dist > settings.warnDistance && urgency == 'warn') {
        urgency = 'info'; // 경고 시작 거리 밖이면 조용한 안내로 강등
      }
    }
    if (urgency == 'safe') return;

    final type = typeKo[msg['type']] ?? '장애물';
    final dir = dirKo[msg['direction']] ?? '전방';
    final sentence = urgency == 'emergency'
        ? '정지하세요! $dir 바로 앞에 $type!'
        : '$dir ${dist.toStringAsFixed(1)}미터에 $type이 있습니다';

    _speak(sentence, urgent: urgency == 'emergency');

    if (settings.vibrate && urgency != 'info') {
      Vibration.hasVibrator().then((has) {
        if (has == true) {
          Vibration.vibrate(duration: urgency == 'emergency' ? 800 : 300);
        }
      });
    }
  }

  Future<void> _speak(String sentence, {bool urgent = false}) async {
    final now = DateTime.now();
    if (!urgent &&
        sentence == _prevSentence &&
        now.difference(_prevTime) < Duration(seconds: settings.repeatGapSec)) {
      return;
    }
    _prevSentence = sentence;
    _prevTime = now;
    if (urgent) await tts.stop();
    setState(() => lastSpoken = sentence);
    await tts.speak(sentence);
  }

  void _toggleGuiding() {
    setState(() => guiding = !guiding);
    tts.stop();
    tts.speak(guiding ? '안내를 시작합니다' : '안내를 정지합니다');
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    _applySpeechRate(); // 설정에서 돌아오면 즉시 반영
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final urgency = lastMsg?['urgency'] as String? ?? 'safe';
    final danger = urgency == 'warn' || urgency == 'emergency';
    final cardColor = danger ? cRedBg : cGreenBg;
    final mainColor = danger ? cRedDark : cGreenText;
    final subColor = danger ? cRedMid : cGreenText;

    return GestureDetector(
      onDoubleTap: _toggleGuiding,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: connected ? cGreenBg : cRedBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        connected ? '●  로봇 연결됨' : '●  연결 안 됨',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: connected ? cGreenText : cRedMid,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings, color: cTextSec, size: 26),
                      tooltip: '설정',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 34),
                  decoration: BoxDecoration(
                      color: cardColor, borderRadius: BorderRadius.circular(20)),
                  child: Column(children: [
                    Text(
                      lastMsg == null || lastMsg!['type'] == 'none'
                          ? '전방 안전'
                          : '↑  ${dirKo[lastMsg!['direction']] ?? '전방'}',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold, color: subColor),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      lastMsg == null || lastMsg!['type'] == 'none'
                          ? '—'
                          : '${(lastMsg!['distance'] as num).toStringAsFixed(1)} m',
                      style: TextStyle(
                          fontSize: 64, fontWeight: FontWeight.bold, color: mainColor),
                    ),
                    Text(
                      lastMsg == null || lastMsg!['type'] == 'none'
                          ? ''
                          : (typeKo[lastMsg!['type']] ?? '장애물'),
                      style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.bold, color: subColor),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: cGrayBg, borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('방금 안내한 음성',
                          style: TextStyle(
                              fontSize: 13,
                              color: cTextMut,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text('"$lastSpoken"',
                          style: const TextStyle(fontSize: 16, color: cTextSec)),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 66,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: guiding ? cDark : cGreenText,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _toggleGuiding,
                    child: Text(guiding ? '❚❚  안내 정지' : '▶  안내 시작',
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 10),
                const Center(
                  child: Text('화면 아무 곳이나 두 번 탭 = 시작/정지',
                      style: TextStyle(fontSize: 13, color: cTextMut)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    channel?.sink.close();
    tts.stop();
    super.dispose();
  }
}

// ================= 설정 화면 =================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Widget _divider() => const Divider(height: 28, color: Color(0xFFDBD9D0));

  Widget _row(String title, String value, {String? sub, Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 17)),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(sub,
                  style: const TextStyle(fontSize: 12, color: cTextMut)),
            ),
        ]),
        Text(value,
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: valueColor ?? Colors.black)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('설정', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _row('경고 시작 거리', '${settings.warnDistance.toStringAsFixed(1)} m',
              sub: '이 거리 안에 장애물이 들어오면 안내'),
          Slider(
            value: settings.warnDistance,
            min: 0.5, max: 3.0, divisions: 5,
            activeColor: cDark,
            onChanged: (v) => setState(() => settings.warnDistance = v),
            onChangeEnd: (_) => settings.save(),
          ),
          _divider(),
          _row('음성 속도', '${settings.speechRate.toStringAsFixed(2)}배'),
          Slider(
            value: settings.speechRate,
            min: 0.5, max: 2.0, divisions: 6,
            activeColor: cDark,
            onChanged: (v) => setState(() => settings.speechRate = v),
            onChangeEnd: (_) => settings.save(),
          ),
          _divider(),
          _row('안내 반복 주기', '${settings.repeatGapSec}초',
              sub: '같은 장애물 재안내 간격'),
          Slider(
            value: settings.repeatGapSec.toDouble(),
            min: 1, max: 10, divisions: 9,
            activeColor: cDark,
            onChanged: (v) =>
                setState(() => settings.repeatGapSec = v.round()),
            onChangeEnd: (_) => settings.save(),
          ),
          _divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('진동 알림', style: TextStyle(fontSize: 17)),
                  SizedBox(height: 3),
                  Text('음성과 함께 진동',
                      style: TextStyle(fontSize: 12, color: cTextMut)),
                ],
              ),
              Switch(
                value: settings.vibrate,
                activeColor: cGreenText,
                onChanged: (v) {
                  setState(() => settings.vibrate = v);
                  settings.save();
                },
              ),
            ],
          ),
          _divider(),
          _row('긴급 정지 거리',
              '${settings.emergencyDistance.toStringAsFixed(1)} m',
              sub: '이 거리 안이면 즉시 반복 경고', valueColor: cRedMid),
          Slider(
            value: settings.emergencyDistance,
            min: 0.3, max: 1.0, divisions: 7,
            activeColor: cRedMid,
            onChanged: (v) => setState(() => settings.emergencyDistance = v),
            onChangeEnd: (_) => settings.save(),
          ),
        ],
      ),
    );
  }
}