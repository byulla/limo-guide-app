// lib/main.dart — 장애물 안내 앱 (목업 디자인 완전판)
// 화면: 메인(연결배지·위험카드·마지막발화·정지버튼) + 설정(거리·속도·주기·진동)
// 설정값은 실제 동작에 반영되고 기기에 저장됨
//
// [2026-07-28 수정] 재연결 폭발 버그 수정:
//   - onError/onDone 양쪽에서 재연결을 예약해 시도가 2배씩 불어나던 문제 → onDone에서만 처리
//   - 재연결 타이머 단일화(_reconnectTimer)로 중복 예약 원천 차단
//   - channel.ready로 연결 성공을 즉시 감지 (첫 메시지 전에도 초록 배지)
//   - dispose 시 타이머 정리
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
const String serverUrl = 'ws://10.115.30.103:8765';

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
  double warnDistance = 1.0;   // 경고 시작 거리 (m)
  double speechRate = 1.0;     // 음성 속도 (배)
  int repeatGapSec = 3;        // 안내 반복 주기 (초)
  bool vibrate = true;         // 진동 알림
  double emergencyDistance = 0.5; // 긴급 정지 거리 (m)

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    warnDistance = p.getDouble('warnDistance') ?? 1.0;
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

  // [수정] 재연결 타이머 단일화 — 이미 예약돼 있으면 새로 예약하지 않음
  Timer? _reconnectTimer;

  static const typeKo = {
    'person': '사람', 'chair': '의자', 'box': '상자',
    'door': '문', 'obstacle': '장애물', 'stairs': '계단',
  };
  // YOLO 클래스명 → 한국어 (융합 서버의 label 필드용)
  static const labelKo = {
    'person': '사람', 'backpack': '가방', 'chair': '의자',
    'suitcase': '캐리어', 'potted plant': '화분', 'tv': '모니터',
    'bench': '벤치', 'couch': '소파',
  };
  static const dirKo = {'front': '전방', 'left': '왼쪽', 'right': '오른쪽'};

  // 받침 유무에 따라 이/가 선택 (사람이 / 의자가)
  static String josa(String w) {
    if (w.isEmpty) return '이';
    final c = w.codeUnitAt(w.length - 1);
    if (c < 0xAC00 || c > 0xD7A3) return '이';
    return (c - 0xAC00) % 28 == 0 ? '가' : '이';
  }

  @override
  void initState() {
    super.initState();
    tts.setLanguage('ko-KR');
    _applySpeechRate();
    // TTS 예열을 백그라운드로 — 실패/지연해도 앱 시작을 막지 않음
    Future(() => _warmUpTts()).timeout(
      const Duration(seconds: 3),
      onTimeout: () => tts.setVolume(1.0),
    ).catchError((_) => tts.setVolume(1.0));
    _connect();
  }

  // 앱 시작 시 TTS 엔진 예열: 무음 발화로 iOS 오디오 세션을 미리 활성화해
  // 실제 안내 시 발화 시작 지연(300~500ms)을 줄인다.
  Future<void> _warmUpTts() async {
    try {
      await tts.awaitSpeakCompletion(false); // speak가 발화 끝을 기다리지 않게
      await tts.setSharedInstance(true);
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [IosTextToSpeechAudioCategoryOptions.mixWithOthers],
      );
      await tts.setVolume(0.0); // 무음으로
      await tts.speak('안내 준비'); // 엔진 첫 시동 (들리지 않음)
      await Future.delayed(const Duration(milliseconds: 600));
      await tts.stop();
      await tts.setVolume(1.0); // 볼륨 복원
    } catch (_) {
      await tts.setVolume(1.0); // 어떤 경우에도 볼륨은 복원
    }
  }

  void _applySpeechRate() {
    // flutter_tts는 0.5가 보통 속도 → 배율을 매핑
    tts.setSpeechRate(0.5 * settings.speechRate);
  }

  // [수정] 연결 로직 전면 교체
  void _connect() { print("### 연결 시도: $serverUrl");
  _reconnectTimer?.cancel();
  try {
    final ch = WebSocketChannel.connect(Uri.parse(serverUrl));
    channel = ch;

    // 연결 성공을 즉시 감지 (첫 메시지 오기 전에도 배지 초록)
    ch.ready.then((_) {
      if (mounted) setState(() => connected = true);
    }).catchError((e) { print("### ready 실패: $e");
      // 접속 실패 — 재연결은 onDone에서 한 번만 예약되므로 여기선 아무것도 안 함
    });

    ch.stream.listen(
          (data) {
        if (!connected && mounted) setState(() => connected = true);
        _onMessage(jsonDecode(data as String) as Map<String, dynamic>);
      },
      // [수정] 핵심: 재연결 예약은 onDone에서만!
      // (에러가 나면 스트림이 닫히면서 onDone도 불리므로,
      //  onError에서도 예약하면 시도가 2배씩 불어나 포트 고갈 폭발이 남)
      onDone: _onDisconnected,
      onError: (e) { print("### 스트림 에러: $e"); },
      cancelOnError: false,
    );
  } catch (_) {
    _scheduleReconnect();
  }
  }

  void _onDisconnected() { print("### 연결 끊김/실패");
  if (connected) _speak('연결이 끊어져 정지했습니다.', urgent: true);
  if (mounted) setState(() => connected = false);
  _scheduleReconnect();
  }

  // [수정] 중복 예약 방지 가드 — 3초에 딱 한 번만 재시도
  void _scheduleReconnect() {
    if (!mounted) return;
    if (_reconnectTimer?.isActive ?? false) return; // 이미 예약됨 → 무시
    _reconnectTimer = Timer(const Duration(seconds: 3), _connect);
  }

  // 직전 발화 내용 기억 (변화 감지용)
  String _prevType = '';
  String _prevDir = '';
  double _prevDist = 99.0;

  void _onMessage(Map<String, dynamic> msg) {
    if (!guiding) return;

    final dist = (msg['distance'] as num?)?.toDouble() ?? 99.0;
    var urgency = msg['urgency'] as String? ?? 'info';

    // 설정값 반영: 거리 기준으로 로컬 판정
    if (msg['type'] != 'none') {
      if (dist <= settings.emergencyDistance) {
        urgency = 'emergency';
      } else if (dist > settings.warnDistance) {
        urgency = 'safe'; // 경고 거리 밖 = 화면·음성 모두 안전 (통일)
      }
    }

    // ── 안전: 화면을 안전 상태로, 음성 없음 ──
    if (urgency == 'safe' || msg['type'] == 'none') {
      _prevType = '';
      _prevDir = '';
      _prevDist = 99.0;
      setState(() => lastMsg = {'type': 'none'});
      return;
    }

    final label = msg['label'] as String? ?? '';
    final type = labelKo[label] ?? typeKo[msg['type']] ?? '장애물';
    final dir = dirKo[msg['direction']] ?? '전방';

    // ── 발화 조건: 내용 변화(물체/방향/거리 0.3m) 또는 반복 주기 경과 ──
    final changed = type != _prevType ||
        dir != _prevDir ||
        (dist - _prevDist).abs() >= 0.3;
    final gapOver = DateTime.now().difference(_prevTime) >
        Duration(seconds: settings.repeatGapSec);
    if (!changed && !gapOver && urgency != 'emergency') {
      return; // 화면도 음성도 그대로 유지 (마지막 발화 상태 고정)
    }

    final sentence = urgency == 'emergency'
        ? '정지! $dir $type!'
        : '$dir ${dist.toStringAsFixed(1)}미터 $type';

    _prevType = type;
    _prevDir = dir;
    _prevDist = dist;

    // ── 화면 갱신과 발화를 반드시 같은 순간, 같은 내용으로 ──
    setState(() {
      lastMsg = msg;
      lastSpoken = sentence;
    });
    _speakNow(sentence);

    if (settings.vibrate) {
      Vibration.hasVibrator().then((has) {
        if (has == true) {
          Vibration.vibrate(duration: urgency == 'emergency' ? 800 : 300);
        }
      });
    }
  }

  // 낡은 발화를 끊고 최신 정보를 즉시 말함 (시간차 최소화)
  Future<void> _speakNow(String sentence) async {
    _prevTime = DateTime.now();
    await tts.stop();
    await tts.speak(sentence);
  }

  Future<void> _speak(String sentence, {bool urgent = false}) async {
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
                          : (labelKo[lastMsg!['label'] ?? ''] ?? typeKo[lastMsg!['type']] ?? '장애물'),
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
    _reconnectTimer?.cancel(); // [수정] 타이머 정리
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