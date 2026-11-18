import 'dart:async';
import 'dart:convert';
import 'care_workspace.dart';
import 'assist_panel.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const teal = Color(0xff125e59);
const ink = Color(0xff162f35);
const alarm = Color(0xffa22f27);
const configuredApi = String.fromEnvironment('API_URL');
String get api => configuredApi.isNotEmpty
    ? configuredApi
    : kIsWeb
        ? Uri.base.origin
        : 'http://127.0.0.1:8000';
typedef Json = Map<String, dynamic>;

void main() => runApp(
      MaterialApp(
        title: 'NeuroBridge Communication Board',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: "BoardSans",
          colorSchemeSeed: teal,
          scaffoldBackgroundColor: const Color(0xfff5f6f1),
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: teal,
              minimumSize: const Size(56, 60),
              textStyle:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        home: const CareBoard(),
      ),
    );

class AccessExpired implements Exception {}

class CareBoard extends StatefulWidget {
  const CareBoard({super.key});
  @override
  State<CareBoard> createState() => _CareBoardState();
}

class _CareBoardState extends State<CareBoard> {
  final name = TextEditingController(),
      carer = TextEditingController(),
      keyField = TextEditingController();
  final speech = FlutterTts();
  late SharedPreferences prefs;
  Timer? timer;
  Json session = {}, board = {};
  final phone = TextEditingController(),
      otp = TextEditingController(),
      guardian = TextEditingController(),
      doctorKey = TextEditingController();
  bool minor = false;
  String challenge = '', phoneGrant = '', verification = '';
  Future<void> verifyPhone(bool submit) async {
    setState(() => busy = true);
    try {
      final r = await request(submit ? 'auth/verify-otp' : 'auth/otp',
          body: submit
              ? {'id': challenge, 'code': otp.text.trim()}
              : {'phone': phone.text.trim()});
      if (submit) {
        phoneGrant = r['grant'];
        verification = 'Phone verified.';
      } else {
        challenge = r['id'];
        verification = r['demo_code'] == null
            ? 'Code sent.'
            : 'Local demo code: ${r['demo_code']}';
      }
    } catch (e) {
      verification = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Json> get roster =>
      List<Json>.from(jsonDecode(prefs.getString('doctorRoster') ?? '[]'));
  Future<void> switchDoctor(String key) async {
    if (syncing || busy) {
      setState(() => feedback = 'Please retry after the current refresh.');
      return;
    }
    setState(() => busy = true);
    try {
      final data = await request('board', credential: key);
      if (data['role'] != 'doctor') {
        throw StateError('A doctor key is required.');
      }
      final next = {
        'name': data['name'],
        'role': 'doctor',
        'carer': data['carer'],
        'token': key
      };
      await prefs.setString('doctorRoster',
          jsonEncode([...roster.where((e) => e['token'] != key), next]));
      await prefs.setString('session', jsonEncode(next));
      if (mounted) {
        setState(() {
          session = next;
          board = data;
          inWorkspace = false;
          doctorKey.clear();
          feedback = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => feedback = 'Doctor access unavailable for this key.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool inWorkspace = false, assisted = false, safetyBusy = false;
  Json? localCheck;
  int safetyRevision = 0;
  final offlineCandidates = <String, Json>{};
  Timer? safetyTimer;
  String lastAlarm = '';
  Json? get currentCheck => localCheck ?? board['safety'];
  Json get timings =>
      board['preferences'] ??
      {'seconds': 15, 'scan_ms': 1500, 'dwell_ms': 1200};
  bool ready = false,
      showForm = false,
      join = false,
      consent = false,
      busy = false,
      syncing = false,
      online = false;
  String feedback = '', caption = '';
  final actions = <(String, IconData)>[
    ('I need water', Icons.water_drop_outlined),
    ('I want to eat', Icons.restaurant),
    ('I need the toilet', Icons.wc),
    ('I need a rest', Icons.bed_outlined),
    ('Yes', Icons.check_circle_outline),
    ('No', Icons.cancel_outlined),
    ('I am in pain', Icons.healing_outlined),
    ('I need my medicine', Icons.medication_outlined),
    ('Please call my family', Icons.people_outline),
  ];
  bool get patient => session['role'] == 'patient';
  String get token => session['token'] ?? '';
  String get prefix => 'queue/$token/';

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    try {
      final phrases = await rootBundle.loadString('assets/data/phrases.json');
      await prefs.setString('bundledPhrases', phrases);
    } catch (_) {
      /* A previously loaded dictionary remains available offline. */
    }
    session = jsonDecode(prefs.getString('session') ?? '{}');
    board = jsonDecode(prefs.getString('board/$token') ?? '{}');
    localCheck = jsonDecode(prefs.getString('localCheck/$token') ?? 'null');
    safetyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final c = currentCheck;
      if (!mounted || !patient || c == null || c['state'] != 'waiting') return;
      if (localCheck != null &&
          !DateTime.parse(c['deadline']).isAfter(DateTime.now())) {
        answerSafety('timeout');
      } else {
        setState(() {});
      }
    });
    caption = prefs.getString('caption/$token') ?? '';
    if (!mounted) return;
    setState(() => ready = true);
    await sync();
    if (!mounted) return;
    timer = Timer.periodic(const Duration(seconds: 3), (_) => sync());
  }

  @override
  void dispose() {
    safetyTimer?.cancel();
    timer?.cancel();
    for (final c in [phone, otp, guardian, doctorKey]) {
      c.dispose();
    }
    name.dispose();
    carer.dispose();
    keyField.dispose();
    speech.stop();
    super.dispose();
  }

  Future<Json> request(String path, {Json? body, String? credential}) async {
    final uri = Uri.parse('$api/v1/$path');
    final headers = {
      'Authorization': 'Bearer ${credential ?? token}',
      'Content-Type': 'application/json',
    };
    final res = await (body == null
            ? http.get(uri, headers: headers)
            : http.post(uri, headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode == 401) throw AccessExpired();
    if (res.statusCode >= 400) {
      final detail = jsonDecode(utf8.decode(res.bodyBytes))['detail'];
      throw StateError(
          detail is String ? detail : 'Please check the submitted values.');
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Json;
  }

  Future<Json> careRequest(String path, {Json? body}) async {
    final cached = prefs.getString('workspace/$token/$path');
    if (path == 'safety/preferences' && body != null) {
      final result = await request(path, body: body);
      board['preferences'] = result;
      await prefs.setString('board/$token', jsonEncode(board));
      return result;
    }
    if (patient && !online) {
      if (path.startsWith('care?') && cached != null) return jsonDecode(cached);
      final snapshot =
          jsonDecode(prefs.getString('workspace/$token/care?days=7') ?? 'null');
      if (path == 'care/samples' &&
          snapshot != null &&
          snapshot['settings']['consent'] == 1 &&
          snapshot['settings']['calibration'] != null) {
        final id = const Uuid().v4(), mode = body!['mode'];
        offlineCandidates[id] = {
          'id': id,
          'mode': mode,
          'started': DateTime.now().toUtc().toIso8601String()
        };
        return {
          'id': id,
          'confidence': 0.61,
          'signal': {
            if ((timings['stillness'] ?? 5) <= 5)
              'Fall detection': 'Possible fall',
            if ((timings['silence'] ?? 10) <= 10)
              'Eye movement': 'Unresponsive',
            'Head movement': 'Head shake'
          }[mode],
          'candidates': [
            ...snapshot['simulator'][mode],
            if (mode == 'Hand gesture') ...snapshot['gestures']
          ]
        };
      }
      if (!path.startsWith('care/samples/')) {
        throw StateError('Offline. This action needs a connection.');
      }
    }
    if (path.startsWith('care/samples/') && path.endsWith('/confirm')) {
      final id = path.split('/')[2], candidate = offlineCandidates[id];
      if (candidate != null) {
        final confirmed = DateTime.now().toUtc().toIso8601String();
        await prefs.setString(
            'observations/$token/$id',
            jsonEncode({
              ...candidate,
              'result': body!['result'],
              'confirmed': confirmed
            }));
        offlineCandidates.remove(id);
        return {'saved': true};
      }
    }
    final result = await request(path, body: body);
    if (patient && path.startsWith('care?')) {
      await prefs.setString('workspace/$token/$path', jsonEncode(result));
    }
    return result;
  }

  Future<void> enter() async {
    if (busy) return;
    setState(() {
      busy = true;
      feedback = '';
    });
    try {
      Json next;
      if (join) {
        final k = keyField.text.trim();
        final data = await request('board', credential: k);
        if (!['carer', 'doctor'].contains(data['role'])) {
          throw StateError('role');
        }
        next = {
          'role': data['role'],
          'token': k,
          'name': data['name'],
          'carer': data['carer'],
        };
      } else {
        final data = await request(
          'patients',
          body: {
            'name': name.text.trim(),
            'carer': carer.text.trim(),
            'consent': consent,
            'minor': minor,
            'guardian': guardian.text.trim(),
            if (phoneGrant.isNotEmpty) 'phone_grant': phoneGrant,
          },
        );
        next = {
          ...data,
          'role': 'patient',
          'name': name.text.trim(),
          'carer': carer.text.trim(),
        };
      }
      if (next['role'] == 'doctor') {
        await prefs.setString(
            'doctorRoster',
            jsonEncode(
                [...roster.where((e) => e['token'] != next['token']), next]));
      }
      await prefs.setString('session', jsonEncode(next));
      setState(() {
        caption = "";
        session = next;
        online = true;
      });
      await sync();
    } catch (_) {
      setState(
        () => feedback = join
            ? 'Could not connect. Check your pairing key and connection.'
            : 'Could not create the profile. Check your details and connection.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<String> get queued =>
      prefs.getKeys().where((k) => k.startsWith(prefix)).toList()..sort();
  Future<void> sync() async {
    if (token.isEmpty || syncing) return;
    syncing = true;
    try {
      for (final k in queued) {
        final entry = jsonDecode(prefs.getString(k)!);
        if (entry['operation'] == 'safetyDecision') {
          await request('safety/local-decisions', body: entry['decision']);
        } else {
          await request('events', body: entry);
        }
        await prefs.remove(k);
      }
      final revision = safetyRevision;
      final data = await request('board');
      for (final k in prefs
          .getKeys()
          .where((k) => k.startsWith('observations/$token/'))
          .toList()) {
        try {
          await request('care/offline-observations',
              body: jsonDecode(prefs.getString(k)!));
        } on StateError catch (e) {
          if (!e.message.toString().contains('consent')) rethrow;
        }
        await prefs.remove(k);
      }
      if (revision != safetyRevision) data['safety'] = board['safety'];
      final check = data['safety'];
      if (patient &&
          check != null &&
          ['timed out', 'help confirmed'].contains(check['state']) &&
          lastAlarm != check['id'] &&
          board['safety']?['state'] == 'waiting') {
        lastAlarm = check['id'];
        say('Help has been requested.');
        HapticFeedback.heavyImpact();
      }
      await prefs.setString('board/$token', jsonEncode(data));
      if (mounted) {
        setState(() {
          board = data;
          online = true;
        });
      }
    } on AccessExpired {
      await prefs.remove('board/$token');
      await prefs.remove('session');
      if (mounted) {
        setState(() {
          session = {};
          board = {};
          caption = '';
          inWorkspace = false;
          showForm = true;
          join = true;
          keyField.clear();
          feedback = 'Access expired. Request a new pairing key.';
        });
      }
    } catch (_) {
      if (mounted) setState(() => online = false);
    } finally {
      syncing = false;
    }
  }

  Future<void> say(String text) async {
    try {
      await speech.setLanguage('en-US');
      if (await speech.speak(text) == 0) throw StateError('tts');
    } catch (_) {
      if (mounted) {
        setState(() =>
            feedback = 'Speech is unavailable. You can still use the caption.');
      }
    }
  }

  Future<void> send(String text, {bool alert = false}) async {
    final id = const Uuid().v4(),
        time = DateTime.now().toUtc().toIso8601String();
    setState(() {
      caption = text;
      feedback = '';
    });
    unawaited(say(text));
    if (alert) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    }
    try {
      await prefs.setString(
        '$prefix$time/$id',
        jsonEncode({
          'id': id,
          'occurred_at': time,
          'kind': alert ? 'alert' : 'phrase',
          'text': text,
        }),
      );
      await prefs.setString('caption/$token', text);
      if (mounted) setState(() {});
      await sync();
    } catch (_) {
      if (mounted) {
        setState(() => feedback =
            'Could not save this message. Please ask someone nearby for help.');
      }
    }
  }

  Future<void> triggerSafety(String reason) async {
    if (safetyBusy) return;
    if (currentCheck?['state'] == 'waiting') {
      setState(() => inWorkspace = false);
      return;
    }
    safetyRevision++;
    setState(() => safetyBusy = true);
    final key = const Uuid().v4();
    try {
      if (!online) {
        localCheck = {
          'id': key,
          'reason': reason,
          'state': 'waiting',
          'deadline': DateTime.now()
              .toUtc()
              .add(Duration(seconds: timings['seconds']))
              .toIso8601String()
        };
        await prefs.setString('localCheck/$token', jsonEncode(localCheck));
      } else {
        board['safety'] =
            await request('safety/checks', body: {'id': key, 'reason': reason});
      }
      if (mounted) {
        setState(() => inWorkspace = false);
        say('Are you okay?');
      }
    } catch (_) {
      if (mounted) {
        setState(() => feedback =
            'Could not confirm check status. Check the board or use Call for help.');
      }
    } finally {
      safetyRevision++;
      if (mounted) setState(() => safetyBusy = false);
    }
  }

  Future<void> answerSafety(String answer) async {
    final c = currentCheck;
    if (safetyBusy || c == null || c['state'] != 'waiting') return;
    safetyRevision++;
    setState(() => safetyBusy = true);
    try {
      if (localCheck != null) {
        final expired = !DateTime.parse(c['deadline']).isAfter(DateTime.now());
        final needsHelp = expired || answer != 'safe';
        final queueKey = '$prefix${c['deadline']}/${c['id']}';
        if (!prefs.containsKey(queueKey)) {
          await prefs.setString(
              queueKey,
              jsonEncode({
                'operation': 'safetyDecision',
                'decision': {
                  'id': c['id'],
                  'reason': c['reason'],
                  'deadline': c['deadline'],
                  'decided': DateTime.now().toUtc().toIso8601String(),
                  'action': answer
                }
              }));
        }
        if (needsHelp) {
          say('Help requested locally. Waiting to send.');
          HapticFeedback.heavyImpact();
          SystemSound.play(SystemSoundType.alert);
        }
        await prefs.remove('localCheck/$token');
        localCheck = null;
        feedback = needsHelp
            ? 'Local help request queued.'
            : 'Safety check cancelled.';
        await sync();
      } else {
        board['safety'] =
            await request('safety/checks/${c['id']}', body: {'action': answer});
        await sync();
      }
    } catch (_) {
      feedback =
          'Response could not be delivered. Retry while the check is open.';
    } finally {
      safetyRevision++;
      if (mounted) setState(() => safetyBusy = false);
    }
  }

  Widget assist(List<AssistChoice> choices, String key) => AssistPanel(
      key: ValueKey(key),
      initialScan: prefs.getBool('scan/$token') ?? false,
      initialDwell: prefs.getBool('dwell/$token') ?? false,
      onMode: (a, b) {
        prefs.setBool('scan/$token', a);
        prefs.setBool('dwell/$token', b);
      },
      choices: choices,
      scanMs: timings['scan_ms'],
      dwellMs: timings['dwell_ms']);
  List<Widget> safetyPrompt() {
    final c = currentCheck!;
    final left =
        DateTime.parse(c['deadline']).difference(DateTime.now()).inSeconds;
    return [
      heading('Are you okay?'),
      Text("${c['reason']} · Simulated signal"),
      Text('Help will be requested in ${left < 0 ? 0 : left} seconds.'),
      assist([
        ('I am okay', () => answerSafety('safe')),
        ('Send help now', () => answerSafety('help'))
      ], 'check/${c['id']}')
    ];
  }

  Future<void> ack(String id, {String? outcome}) async {
    setState(() {
      busy = true;
      feedback = '';
    });
    try {
      await request(
          outcome == null ? 'alerts/$id/acknowledge' : 'care/alerts/$id/close',
          body: outcome == null ? {} : {'outcome': outcome});
      await sync();
    } catch (_) {
      setState(() => feedback =
          'Could not acknowledge the request. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget heading(String title) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          title,
          style: const TextStyle(
            color: ink,
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
  Widget action(
    String title,
    IconData icon,
    VoidCallback? tap, {
    Color? color,
  }) =>
      FilledButton.icon(
        onPressed: tap,
        style: color == null
            ? null
            : FilledButton.styleFrom(backgroundColor: color),
        icon: Icon(icon),
        label: Text(title, style: const TextStyle(fontFamily: 'BoardSans')),
      );
  Widget field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: c,
          maxLength: 60,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, counterText: ''),
        ),
      );
  List<Widget> setup() => [
        heading(join
            ? 'Connect to a patient’s board'
            : 'Create a communication profile'),
        Text(join
            ? 'Ask the person who set up the board for their care team pairing key.'
            : 'Use familiar names so the patient can see who is responding.'),
        const SizedBox(height: 24),
        if (join)
          field(keyField, 'Care team pairing key')
        else ...[
          field(name, 'Patient name'),
          field(carer, 'Caregiver name'),
          ExpansionTile(
              title: const Text('Phone and guardian details'),
              children: [
                if (phoneGrant.isEmpty) ...[
                  field(phone, 'Phone with country code'),
                  TextButton(
                      onPressed: busy ? null : () => verifyPhone(false),
                      child: const Text('Request verification code')),
                  if (challenge.isNotEmpty) ...[
                    field(otp, 'Verification code'),
                    TextButton(
                        onPressed: busy ? null : () => verifyPhone(true),
                        child: const Text('Verify phone'))
                  ],
                ],
                if (verification.isNotEmpty) Text(verification),
                SwitchListTile(
                    title: const Text('Guardian is enrolling a minor'),
                    value: minor,
                    onChanged: (v) => setState(() => minor = v)),
                if (minor) field(guardian, 'Consenting guardian name'),
              ]),
          Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                value: consent,
                onChanged: (v) => setState(() => consent = v ?? false),
                title: const Text(
                    'I agree to share my messages and help requests with this caregiver.'),
              )),
        ],
        action(
          join ? 'Connect to board' : 'Create profile',
          join ? Icons.link : Icons.person_add_alt,
          busy ||
                  (join
                      ? keyField.text.trim().isEmpty
                      : !consent ||
                          (minor && guardian.text.trim().isEmpty) ||
                          name.text.trim().isEmpty ||
                          carer.text.trim().isEmpty)
              ? null
              : enter,
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
          onPressed: busy
              ? null
              : () => setState(() {
                    join = !join;
                    feedback = '';
                  }),
          child: Text(
              join ? 'Back to profile setup' : 'Use a care team pairing key'),
        ),
      ];

  void openForm(bool asCarer) => setState(() {
        showForm = true;
        join = asCarer;
        feedback = '';
      });

  Widget entryCard() => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xffd6e2db))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(
              alignment: Alignment.centerLeft,
              child: CircleAvatar(
                  radius: 28,
                  backgroundColor: const Color(0xffe2efe8),
                  child:
                      Icon(Icons.people_alt_outlined, size: 30, color: teal))),
          heading('Connect with a caregiver'),
          const Text(
              'Create a profile to share messages and ask your caregiver for help.',
              style: TextStyle(fontSize: 16, height: 1.6)),
          const SizedBox(height: 22),
          action(
              'Set up my board', Icons.person_add_alt, () => openForm(false)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              onPressed: () => openForm(true),
              icon: const Icon(Icons.link),
              label: const Text('Pair with a care board'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(56, 56))),
        ]),
      );

  Widget landing() => LayoutBuilder(builder: (context, box) {
        final panel =
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          boardPanel(),
          const SizedBox(height: 12),
          heading('Choose a phrase'),
          phrases(),
        ]);
        if (box.maxWidth < 800) {
          return Column(
              children: [panel, const SizedBox(height: 20), entryCard()]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: panel),
          const SizedBox(width: 24),
          Expanded(child: entryCard()),
        ]);
      });

  Widget boardPanel() => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xff113c40), Color(0xff216760)],
              begin: Alignment.bottomLeft,
              end: Alignment.topRight),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.chat_bubble_outline, color: Colors.white),
                SizedBox(width: 10),
                Text('My message',
                    style: TextStyle(color: Colors.white, fontSize: 17)),
              ],
            ),
            const SizedBox(height: 14),
            Semantics(
              liveRegion: true,
              child: Text(
                caption.isEmpty ? 'I want to say…' : caption,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (caption.isEmpty)
              const Row(children: [
                Expanded(
                    child: Text('Tap a phrase to speak it aloud.',
                        style: TextStyle(color: Colors.white, fontSize: 16))),
                SoundWave(),
              ]),
            if (caption.isNotEmpty)
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(56, 56),
                ),
                onPressed: () => say(caption),
                icon: const Icon(Icons.volume_up),
                label: const Text('Speak again'),
              ),
          ],
        ),
      );
  Widget phrases() => LayoutBuilder(
        builder: (context, box) {
          final columns = MediaQuery.textScalerOf(context).scale(20) > 32 ||
                  box.maxWidth < 300
              ? 1
              : box.maxWidth >= 600
                  ? 3
                  : 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (index, item) in actions.indexed)
                SizedBox(
                  width: (box.maxWidth - (columns - 1) * 10) / columns,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const [
                        Color(0xffdfefec),
                        Color(0xfff9ead6),
                        Color(0xffe7e9f8),
                        Color(0xffe9e7f1),
                        Color(0xffe5efda),
                        Color(0xfff6e5df)
                      ][index % 6],
                      side: BorderSide.none,
                      foregroundColor: ink,
                      minimumSize: const Size(56, 100),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      if (token.isEmpty) {
                        setState(() {
                          caption = item.$1;
                          feedback = '';
                        });
                        say(item.$1);
                      } else {
                        send(item.$1);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        children: [
                          Icon(item.$2, size: 34, color: ink),
                          const SizedBox(height: 8),
                          Text(
                            item.$1,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  String clock(String iso) {
    final t = DateTime.parse(iso).toLocal();
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  List<Widget> dashboard() {
    final events = List<Json>.from(board['events'] ?? []),
        pending = List<Json>.from(board['pending'] ?? []);
    final lastAlert = events.where((e) => e['kind'] == 'alert').firstOrNull;
    return [
      heading(patient
          ? '${session['name']}’s board'
          : '${session['role'] == 'doctor' ? 'Doctor' : 'Caregiver'} view · ${session['name']}'),
      Text(online
          ? 'Connected · Updates every 3 seconds'
          : 'Offline · Showing saved activity'),
      for (final r in (board['due_reminders'] ?? []))
        ListTile(
            leading: const Icon(Icons.alarm),
            title: Text(r['body']),
            subtitle:
                const Text('Reminder due · Open Care team to mark complete.')),
      if (session['role'] == 'doctor')
        ExpansionTile(title: const Text('My patients'), children: [
          for (final entry in roster)
            ListTile(
                title: Text(entry['name']),
                selected: token == entry['token'],
                onTap: () => switchDoctor(entry['token'])),
          field(doctorKey, 'Additional patient doctor key'),
          TextButton(
              onPressed: () => switchDoctor(doctorKey.text.trim()),
              child: const Text('Link patient')),
        ]),
      if (!patient && board['device'] != null) ...[
        Text("Device last seen: ${clock(board['device']['seen'])}"),
        Text(
            "Battery: ${board['device']['battery'] ?? 'Unavailable'} · Last shared location: ${board['device']['lat'] ?? 'Not shared'} ${board['device']['lon'] ?? ''}"),
      ],
      if (patient && queued.isNotEmpty)
        Semantics(
          liveRegion: true,
          child: Text(
              'Waiting to send: ${queued.length}. Your caregiver has not received these yet.'),
        ),
      const SizedBox(height: 16),
      if (patient) ...[boardPanel(), heading('Everyday phrases'), phrases()],
      if (pending.isNotEmpty || lastAlert != null) ...[
        heading('Help requests'),
        for (final a in pending)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${clock(a['created'])} · Waiting for a caregiver',
                    style: const TextStyle(fontSize: 20, color: alarm),
                  ),
                  if (session['role'] == 'carer')
                    action(
                      'Acknowledge request',
                      Icons.volunteer_activism,
                      busy ? null : () => ack(a['id']),
                    ),
                ],
              ),
            ),
          ),
        for (final alert in board['open_alerts'] ?? [])
          Wrap(spacing: 8, children: [
            Text(clock(alert['created'])),
            if (patient)
              TextButton(
                  onPressed: busy
                      ? null
                      : () => ack(alert['id'], outcome: 'Cancelled'),
                  child: const Text('Cancel request')),
            if (session['role'] == 'carer') ...[
              if (alert['acknowledged'] != null)
                TextButton(
                    onPressed: busy
                        ? null
                        : () => ack(alert['id'], outcome: 'Resolved'),
                    child: const Text('Mark resolved')),
              TextButton(
                  onPressed: busy
                      ? null
                      : () => ack(alert['id'], outcome: 'False alarm'),
                  child: const Text('Mark false alarm')),
            ]
          ]),
        if (lastAlert?['outcome'] != null)
          Text('Request closed · ${lastAlert!['outcome']}'),
        if (lastAlert?['acknowledged'] != null)
          Semantics(
            liveRegion: true,
            child: Text(
              '${lastAlert!['who']} acknowledged · ${clock(lastAlert['acknowledged'])}',
            ),
          ),
      ],
      for (final d in (board['delivery'] ?? []).take(4))
        Text("${d['channel'] == 'push' ? 'Push' : 'SMS'} · ${d['state']}"),
      heading('Recent activity'),
      if (events.isEmpty) const Text('No messages yet.'),
      for (final e in events.take(12))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            e['kind'] == 'alert'
                ? Icons.notifications_active
                : Icons.chat_outlined,
          ),
          title: Text(e['text']),
          subtitle: Text(
            '${clock(e['created'])}${e['who'] == null ? '' : ' · ${e['who']} acknowledged'}',
          ),
        ),
      if (patient)
        ExpansionTile(
          title: const Text('Link a caregiver device'),
          children: [
            const Text(
                'On another device or browser, choose “Pair with a care board” and enter this key. Anyone with the key can see your messages and help requests.'),
            SelectableText(session['pairing_key']),
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: session['pairing_key']),
              ),
              child: const Text('Copy pairing key'),
            ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xfff5f6f1),
          actions: [
            if (ready && token.isEmpty && !showForm)
              TextButton.icon(
                  onPressed: () => openForm(false),
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Set up'),
                  style: TextButton.styleFrom(minimumSize: const Size(56, 56))),
          ],
          title: const Row(
            children: [
              Icon(Icons.forum_rounded, color: teal),
              SizedBox(width: 10),
              Text(
                'NeuroBridge',
                style: TextStyle(fontWeight: FontWeight.bold, color: ink),
              ),
            ],
          ),
        ),
        bottomNavigationBar: ready && patient
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: action(
                    'Call for help',
                    Icons.notifications_active_outlined,
                    () => send('I need help. Please come over.', alert: true),
                    color: alarm,
                  ),
                ),
              )
            : null,
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: token.isEmpty && !showForm ? 1120 : 800),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                      children: [
                        if (feedback.isNotEmpty)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              feedback,
                              style: const TextStyle(color: alarm),
                            ),
                          ),
                        if (patient && currentCheck?['state'] == 'waiting')
                          ...safetyPrompt()
                        else if (patient && assisted) ...[
                          heading('Assisted communication'),
                          assist([
                            for (final a in actions) (a.$1, () => send(a.$1)),
                            (
                              'Call for help',
                              () => send('I need help. Please come over.',
                                  alert: true)
                            ),
                            (
                              'Return to board',
                              () => setState(() => assisted = false)
                            )
                          ], 'board'),
                          if (caption.isNotEmpty) Text(caption)
                        ] else if (token.isNotEmpty && inWorkspace)
                          CareWorkspace(
                              request: careRequest,
                              safety: triggerSafety,
                              timings: timings,
                              express: (text) => send(text),
                              role: session['role'],
                              name: session['name'],
                              back: () => setState(() => inWorkspace = false))
                        else if (token.isNotEmpty) ...[
                          action('Care workspace', Icons.dashboard_outlined,
                              () => setState(() => inWorkspace = true)),
                          if (patient) ...[
                            action(
                                'Assisted communication',
                                Icons.accessibility_new,
                                () => setState(() => assisted = true)),
                            ExpansionTile(
                                title: const Text('Simulate safety signal'),
                                children: [
                                  for (final reason in [
                                    'Possible fall',
                                    'Unresponsive',
                                    'Emergency blink',
                                    'Head shake'
                                  ])
                                    TextButton(
                                        onPressed: safetyBusy
                                            ? null
                                            : () => triggerSafety(reason),
                                        child: Text(reason))
                                ]),
                            if (currentCheck != null)
                              Text(
                                  'Last safety check: ${currentCheck!['state']}'),
                          ],
                          ...dashboard(),
                        ] else if (showForm) ...[
                          Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => setState(() {
                                            showForm = false;
                                            feedback = '';
                                          }),
                                  icon: const Icon(Icons.arrow_back),
                                  label: const Text('Back to board'))),
                          Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24)),
                              child: Material(
                                  color: Colors.transparent,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: setup()))),
                        ] else ...[
                          heading('Communication board'),
                          const Padding(
                              padding: EdgeInsets.only(bottom: 20),
                              child: Text(
                                  'Try a phrase or connect with your caregiver.',
                                  style: TextStyle(fontSize: 17, color: ink))),
                          landing(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      );
}

class SoundWave extends StatelessWidget {
  const SoundWave({super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
          child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final h in const [8, 15, 28, 42, 24, 38, 17, 8])
            Container(
                width: 4,
                height: h.toDouble(),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                    color: const Color(0xffa4d9bd),
                    borderRadius: BorderRadius.circular(4)))
        ],
      ));
}
