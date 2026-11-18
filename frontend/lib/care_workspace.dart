import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'device_tools.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/widgets.dart' as pdf;
import 'package:printing/printing.dart';

typedef CareRequest = Future<Map<String, dynamic>> Function(String path,
    {Map<String, dynamic>? body});

class CareWorkspace extends StatefulWidget {
  final CareRequest request;
  final String role, name;
  final VoidCallback back;
  final Map<String, dynamic> timings;
  final Future<void> Function(String) safety;
  final Future<void> Function(String) express;
  const CareWorkspace(
      {super.key,
      required this.request,
      required this.timings,
      required this.safety,
      required this.role,
      required this.name,
      required this.express,
      required this.back});
  @override
  State<CareWorkspace> createState() => _CareWorkspaceState();
}

class _CareWorkspaceState extends State<CareWorkspace> {
  Map<String, dynamic>? data, sample;
  String target = 'Spanish', translation = '';
  final source = TextEditingController(text: 'I need water');
  String confirmedPhrase = '';
  String section = 'Progress', mode = 'Lip reading', message = '', keyText = '';
  int days = 7;
  bool busy = false;
  final history = TextEditingController(),
      contact = TextEditingController(),
      draft = TextEditingController(),
      correction = TextEditingController();
  late int seconds, scanMs, dwellMs, silence, stillness;
  late double confidence;
  final details = {
    for (final key in [
      'age',
      'disability',
      'blood_group',
      'hospital',
      'guardian'
    ])
      key: TextEditingController()
  };
  static const labels = {
    'age': 'Age',
    'disability': 'Communication or mobility needs',
    'blood_group': 'Blood group',
    'hospital': 'Hospital or clinic',
    'guardian': 'Consenting guardian name'
  };
  bool consent = false;
  bool get patient => widget.role == 'patient';
  bool get doctor => widget.role == 'doctor';
  @override
  void initState() {
    super.initState();
    confidence = (widget.timings["confidence"] ?? 0.7).toDouble();
    silence = widget.timings["silence"] ?? 10;
    stillness = widget.timings["stillness"] ?? 5;
    seconds = widget.timings["seconds"];
    scanMs = widget.timings["scan_ms"];
    dwellMs = widget.timings["dwell_ms"];
    reload(initial: true);
  }

  @override
  void dispose() {
    for (final c in [
      history,
      contact,
      draft,
      correction,
      source,
      ...details.values
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool initial = false}) async {
    final next = await widget.request('care?days=$days');
    if (!mounted) return;
    setState(() {
      data = next;
      if (initial) {
        for (final e in details.entries) {
          e.value.text = next['settings'][e.key]?.toString() ?? '';
        }
        history.text = next['settings']['history'];
        contact.text = next['settings']['contact'];
        consent = next['settings']['consent'] == 1;
      }
    });
  }

  Future<void> perform(Future<void> Function() job) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await job();
    } catch (e) {
      if (mounted) {
        setState(() => message = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reload({bool initial = false}) =>
      perform(() => load(initial: initial));
  Future<void> save(String path, Map<String, dynamic> body,
          {String success = 'Saved.'}) =>
      perform(() async {
        await widget.request('care/$path', body: body);
        await load();
        if (mounted) setState(() => message = success);
      });
  Widget button(String label, Future<void> Function() tap) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OutlinedButton(
          onPressed: busy ? null : tap,
          style: OutlinedButton.styleFrom(minimumSize: const Size(56, 56)),
          child: Text(label)));
  Widget title(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge));
  Widget field(TextEditingController c, String label,
          {int limit = 500}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextField(
              controller: c,
              enabled: !busy,
              maxLength: limit,
              decoration: InputDecoration(labelText: label)));
  String date(String? iso) => iso == null
      ? 'Not recorded'
      : DateTime.parse(iso).toLocal().toString().split('.').first;
  List<dynamic> get observations => data!['observations'];
  List<dynamic> get entries => data!['entries'];
  Future<void> exportReport() => perform(() async {
        final snapshot = await widget.request('care/report?days=$days');
        final report = pdf.Document();
        report.addPage(pdf.MultiPage(
            build: (_) => [
                  pdf.Header(text: 'NeuroBridge progress report'),
                  pdf.Text('Patient: ${widget.name}'),
                  pdf.Text(
                      'Last $days days | Generated ${date(DateTime.now().toIso8601String())}'),
                  pdf.Paragraph(
                      text:
                          'Messages: ${snapshot['totals']['phrase'] ?? 0}   Help requests: ${snapshot['totals']['alert'] ?? 0}   Confirmed demo samples: ${snapshot['confirmed']}'),
                  pdf.Text(
                      'Weekly baseline: ${snapshot['baseline'] ?? 'Not recorded'}'),
                  pdf.Header(text: 'Therapy notes'),
                  for (final e in snapshot['notes'])
                    pdf.Paragraph(text: '${date(e['created'])}  ${e['body']}'),
                ]));
        await Printing.sharePdf(
            bytes: await report.save(), filename: 'neurobridge-progress.pdf');
      });

  List<Widget> progress() {
    final totals = data!['totals'],
        baseline = data!['settings']['baseline'],
        count = totals['phrase'] ?? 0;
    return [
      title('Communication progress'),
      Wrap(spacing: 8, children: [
        for (final d in [1, 7, 30])
          ChoiceChip(
              label: Text('$d days'),
              selected: d == days,
              onSelected: busy
                  ? null
                  : (_) => perform(() async {
                        setState(() => days = d);
                        await load();
                      }))
      ]),
      ListTile(
          leading: const Icon(Icons.chat_outlined),
          title: const Text('Messages expressed'),
          trailing: Text('$count')),
      ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Help requests'),
          trailing: Text('${totals['alert'] ?? 0}')),
      ListTile(
          leading: const Icon(Icons.science_outlined),
          title: const Text('Confirmed demo samples'),
          trailing: Text('${data!['confirmed']}')),
      title('Weekly baseline'),
      Text(baseline == null
          ? 'No baseline recorded.'
          : '$baseline messages · ${date(data!['settings']['baseline_at'])}'),
      if (baseline != null && days == 7)
        Text('Change from baseline: ${count - baseline} messages'),
      if (patient)
        button(
            baseline == null
                ? 'Record weekly baseline'
                : 'Update weekly baseline',
            () => save('baseline', {})),
      if (doctor) button('Export PDF report', exportReport),
      title('Period comparison'),
      for (final period in ['previous', 'current']) ...[
        Text(period == 'previous'
            ? 'Previous $days days'
            : 'Current $days days'),
        Text(
            'Confirmed simulation attempts: ${data!['analysis'][period]['confirmed']} / ${data!['analysis'][period]['attempts']}'),
        Text(
            'Mean confirmation time: ${(data!['analysis'][period]['seconds'] as num?)?.toStringAsFixed(1) ?? 'No data'} seconds'),
      ],
      title('Therapy comparison'),
      if (doctor)
        button('Set therapy start to now', () => save('therapy-start', {})),
      if (data!['analysis']['therapy'] == null)
        const Text('No therapy start has been recorded.')
      else ...[
        Text('Started: ${date(data!['analysis']['therapy']['started'])}'),
        for (final side in ['before', 'after'])
          Text(
              "${side == 'before' ? 'Before' : 'After'} therapy: ${data!['analysis']['therapy'][side]['confirmed']} confirmed / ${data!['analysis']['therapy'][side]['attempts']} simulated attempts")
      ],
      title('Hourly mood summary'),
      if (data!['analysis']['moods'].isEmpty)
        const Text('No confirmed mood samples.'),
      for (final m in data!['analysis']['moods'])
        Text("${m['hour']} UTC · ${m['result']} · ${m['samples']}"),
      title('Observation timeline'),
      if (observations.isEmpty)
        const Text('No demo observations in this period.'),
      for (final r in observations)
        ListTile(
            title: Text(
                '${r['mode']} · ${r['result'] ?? 'Awaiting confirmation'}'),
            subtitle: Text('Simulation · ${date(r['created'])}'))
    ];
  }

  List<Widget> recognition() => [
        title('Recognition simulator'),
        const PreviewPane(),
        const Text(
            'Run a sample to preview candidate labels. The optional camera preview stays on this device.'),
        if (data!['settings']['consent'] != 1)
          const Text('Enable simulation in Profile before calibrating.'),
        button('Run demo calibration',
            () => save('calibrate', {}, success: 'Demo calibration recorded.')),
        Text('Last calibration: ${date(data!['settings']['calibration'])}'),
        Wrap(spacing: 6, children: [
          for (final m in data!['modes'])
            ChoiceChip(
                label: Text(m),
                selected: m == mode,
                onSelected: busy
                    ? null
                    : (_) => setState(() {
                          mode = m;
                          sample = null;
                          correction.clear();
                        }))
        ]),
        button(
            'Run sample',
            () => perform(() async {
                  final next = await widget
                      .request('care/samples', body: {'mode': mode});
                  if (next['signal'] != null) {
                    await widget.safety(next['signal']);
                    return;
                  }
                  if (mounted) setState(() => sample = next);
                })),
        if (mode == 'Hand gesture' && sample == null) ...[
          title('Gesture library'),
          Text(['Yes', 'No', ...data!['gestures']].join(' · ')),
          field(correction, 'Custom gesture meaning', limit: 160),
          button('Add gesture meaning',
              () => save('gestures', {'result': correction.text.trim()})),
        ],
        if (confirmedPhrase.isNotEmpty)
          button(
              'Speak and share: $confirmedPhrase',
              () => perform(() async {
                    await widget.express(confirmedPhrase);
                    if (mounted) setState(() => confirmedPhrase = '');
                  })),
        if (sample != null) ...[
          title((sample!['confidence'] ?? 0.61) < confidence
              ? 'Low confidence · Confirm or correct'
              : 'Review the candidate'),
          Text(
              'Demo confidence: ${((sample!['confidence'] ?? 0.61) * 100).round()}%. Please confirm a label.'),
          for (final t in sample!['candidates']) button(t, () => confirm(t)),
          field(correction, 'Corrected label'),
          button('Save correction', () => confirm(correction.text.trim()))
        ]
      ];
  Future<void> confirm(String text) => perform(() async {
        if (text.isEmpty) throw StateError('Enter a label first.');
        await widget.request('care/samples/${sample!['id']}/confirm',
            body: {'result': text});
        if (mounted) {
          setState(() {
            confirmedPhrase = ['Lip reading', 'Hand gesture'].contains(mode) &&
                    text.length <= 160
                ? text
                : '';
            sample = null;
            correction.clear();
            message = 'Confirmed in the observation timeline.';
          });
        }
        if (['Emergency blink', 'Head shake'].contains(text)) {
          await widget.safety(text);
          return;
        }
        await load();
      });

  List<Widget> languageTools() => [
        title('Phrase translation'),
        const Text(
            'Try a cached phrase such as “I need water”, “Yes” or “No”.'),
        field(source, 'Source phrase'),
        Wrap(spacing: 8, children: [
          for (final lang in [
            'English',
            'Hindi',
            'Punjabi',
            'Tamil',
            'Spanish',
            'French',
            'Arabic',
            'Japanese',
            'Chinese'
          ])
            ChoiceChip(
                label: Text(lang),
                selected: target == lang,
                onSelected: busy
                    ? null
                    : (_) => setState(() {
                          target = lang;
                          translation = '';
                        }))
        ]),
        button(
            'Translate phrase',
            () => perform(() async {
                  final prefs = await SharedPreferences.getInstance();
                  final cache = jsonDecode(prefs.getString('bundledPhrases') ??
                      await rootBundle.loadString('assets/data/phrases.json'));
                  final result = {
                    'translated': cache[source.text.trim()]?[target]
                  };
                  if (mounted) {
                    setState(() => translation = result['translated'] ??
                        'No cached translation available.');
                  }
                })),
        if (translation.isNotEmpty)
          Semantics(
              liveRegion: true,
              child: Text(translation,
                  style: Theme.of(context).textTheme.headlineSmall)),
        if (patient && data != null) ...[
          title('Personalized model preview'),
          for (final v in data!['versions'] ?? [])
            Text(
                "Version ${v['version']} · First candidate accepted in ${v['accepted']} of ${v['samples']} confirmed samples"),
          const Text(
              'Create a demo version from confirmed samples. Model training is simulated.'),
          if (data!['model'] != null)
            Text(
                'Demo version ${data!['model']['version']} · ${data!['model']['samples']} confirmed samples'),
          button(
              'Create demo version',
              () => save('personalize', {},
                  success: 'Demo model version created.'))
        ]
      ];

  List<Widget> profile() => [
        title('Care profile'),
        if (patient) ...[
          ExpansionTile(
              title: const Text('Safety and access timing'),
              children: [
                Text(
                    'Low-confidence threshold: ${(confidence * 100).round()}%'),
                Slider(
                    value: confidence,
                    min: 0.5,
                    max: 1,
                    divisions: 10,
                    onChanged: (v) => setState(() => confidence = v)),
                Text('Unresponsive duration: $silence seconds'),
                Slider(
                    value: silence.toDouble(),
                    min: 2,
                    max: 60,
                    divisions: 58,
                    onChanged: (v) => setState(() => silence = v.round())),
                Text('Fall stillness duration: $stillness seconds'),
                Slider(
                    value: stillness.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    onChanged: (v) => setState(() => stillness = v.round())),
                Text('Response window: $seconds seconds'),
                Slider(
                    value: seconds.toDouble(),
                    min: 5,
                    max: 300,
                    divisions: 59,
                    onChanged: (v) => setState(() => seconds = v.round())),
                Text('Scan interval: $scanMs ms'),
                Slider(
                    value: scanMs.toDouble(),
                    min: 500,
                    max: 10000,
                    divisions: 38,
                    onChanged: (v) => setState(() => scanMs = v.round())),
                Text('Dwell interval: $dwellMs ms'),
                Slider(
                    value: dwellMs.toDouble(),
                    min: 500,
                    max: 5000,
                    divisions: 45,
                    onChanged: (v) => setState(() => dwellMs = v.round())),
                button(
                    'Save timing',
                    () => perform(() async {
                          await widget.request('safety/preferences', body: {
                            'seconds': seconds,
                            'silence': silence,
                            'confidence': confidence,
                            'stillness': stillness,
                            'scan_ms': scanMs,
                            'dwell_ms': dwellMs
                          });
                          if (mounted) {
                            setState(() => message = 'Timing saved.');
                          }
                        })),
              ]),
          ExpansionTile(title: const Text('Device sharing'), children: [
            button(
                'Share battery and location',
                () => perform(() async {
                      await widget.request('device',
                          body: await readDevice(true));
                      if (mounted) {
                        setState(() => message = 'Device status shared.');
                      }
                    })),
            button(
                'Remove shared location',
                () => perform(() async {
                      await widget.request('device',
                          body: await readDevice(false));
                      if (mounted) {
                        setState(() => message = 'Location removed.');
                      }
                    })),
          ]),
        ],
        if (patient) ...[
          ExpansionTile(
              title: const Text('Personal and medical details'),
              children: [
                for (final e in details.entries)
                  field(e.value, labels[e.key]!,
                      limit: e.key == 'age'
                          ? 3
                          : e.key == 'blood_group'
                              ? 12
                              : e.key == 'guardian'
                                  ? 80
                                  : 160),
                field(history, 'Medical history'),
                field(contact, 'Emergency contact', limit: 160)
              ]),
          SwitchListTile(
              title: const Text('Allow recognition simulation'),
              value: consent,
              onChanged: busy ? null : (v) => setState(() => consent = v)),
          button(
              'Save profile',
              () => save('settings', {
                    for (final e in details.entries)
                      e.key: e.key == 'age'
                          ? (e.value.text.trim().isEmpty
                              ? null
                              : int.tryParse(e.value.text.trim()) ?? -1)
                          : e.value.text.trim(),
                    'history': history.text,
                    'contact': contact.text,
                    'consent': consent
                  })),
          title('Doctor access'),
          const Text(
              'Share a doctor key to allow this patient’s history, therapy notes and reports to be accessed. Creating a new key replaces the previous one.'),
          button(
              'Create doctor pairing key',
              () => perform(() async {
                    final r = await widget.request('care/doctor-key', body: {});
                    if (mounted) setState(() => keyText = r['key']);
                    await load();
                  })),
          if (keyText.isNotEmpty) SelectableText(keyText),
          if (data!['settings']['doctor_linked'] == 1)
            button(
                'Revoke doctor access',
                () => perform(() async {
                      await widget.request('care/revoke-doctor', body: {});
                      if (mounted) setState(() => keyText = '');
                      await load();
                    })),
        ] else ...[
          for (final e in details.entries)
            if (e.value.text.isNotEmpty)
              Text('${labels[e.key]}: ${e.value.text}'),
          const Text('Medical history'),
          Text(history.text.isEmpty ? 'Not provided' : history.text),
          title('Emergency contact'),
          Text(contact.text.isEmpty ? 'Not provided' : contact.text)
        ]
      ];

  Future<void> addEntry(String kind) async {
    final text = draft.text.trim();
    if (text.isEmpty) {
      setState(() => message = 'Enter a message first.');
      return;
    }
    DateTime? due;
    if (kind == 'reminder') {
      final now = DateTime.now();
      final day = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: now,
          lastDate: DateTime(now.year + 2));
      if (day == null || !mounted) return;
      final time =
          await showTimePicker(context: context, initialTime: TimeOfDay.now());
      if (time == null || !mounted) return;
      due = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    }
    await perform(() async {
      await widget.request('care/entries', body: {
        'kind': kind,
        'text': text,
        if (due != null) 'due': due.toUtc().toIso8601String()
      });
      if (mounted) {
        draft.clear();
      }
      await load();
      if (mounted) setState(() => message = 'Saved.');
    });
  }

  List<Widget> careTeam() => [
        title('Care team'),
        field(draft, 'Message or reminder'),
        Wrap(spacing: 8, children: [
          if (!patient) button('Reply to patient', () => addEntry('reply')),
          if (doctor) button('Save therapy note', () => addEntry('note')),
          button('Schedule reminder', () => addEntry('reminder'))
        ]),
        title('Scheduled reminders'),
        if (data!['reminders'].isEmpty) const Text('No scheduled reminders.'),
        for (final r in data!['reminders'])
          ListTile(
              title: Text(r['body']),
              subtitle: Text(date(r['due'])),
              trailing: IconButton(
                  tooltip: 'Mark complete',
                  onPressed: busy
                      ? null
                      : () => save('reminders/${r['id']}/complete', {}),
                  icon: const Icon(Icons.check))),
        title('Team updates'),
        if (entries.isEmpty) const Text('No team updates in this period.'),
        for (final e in entries)
          ListTile(
              title: Text(e['body']),
              subtitle: Text(
                  '${e['kind'] == 'note' ? 'Therapy note' : 'Reply'} · ${date(e['created'])}'))
      ];

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: widget.back,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Communication board'))),
        Text('${widget.name} · Care workspace',
            style: Theme.of(context).textTheme.headlineSmall),
        Wrap(spacing: 8, children: [
          for (final s in [
            'Progress',
            if (patient) 'Recognition',
            'Profile',
            'Care team',
            'Language'
          ])
            ChoiceChip(
                label: Text(s),
                selected: section == s,
                onSelected: busy
                    ? null
                    : (_) => setState(() {
                          section = s;
                          message = '';
                        }))
        ]),
        if (busy) const LinearProgressIndicator(),
        if (message.isNotEmpty)
          Semantics(liveRegion: true, child: Text(message)),
        if (patient &&
            data != null &&
            (data!['settings']['calibration'] == null ||
                data!['settings']['baseline'] == null))
          ExpansionTile(title: const Text('Finish initial setup'), children: [
            ListTile(
                title: const Text('Set up recognition consent'),
                onTap: () => setState(() => section = 'Profile')),
            ListTile(
                title: const Text('Calibrate the simulator'),
                onTap: () => setState(() => section = 'Recognition')),
            ListTile(
                title: const Text('Record the initial baseline'),
                onTap: () => setState(() => section = 'Progress')),
          ]),
        if (data != null || section == 'Language')
          ...switch (section) {
            'Recognition' => recognition(),
            'Profile' => profile(),
            'Care team' => careTeam(),
            'Language' => languageTools(),
            _ => progress()
          },
        button('Refresh workspace', () => reload(initial: data == null)),
      ]);
}
