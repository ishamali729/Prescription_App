import 'dart:async';
import 'package:flutter/material.dart' hide Ink;
import 'package:priscription_app/core/network/api_service.dart';
import 'package:scribble/scribble.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

class Patient {
  final int id;
  final String uhid;
  final String fullName;
  final String age;
  final String gender;
  final String dob;
  final String mobile;

  const Patient({
    required this.id,
    required this.uhid,
    required this.fullName,
    required this.age,
    required this.gender,
    required this.dob,
    required this.mobile,
  });

  factory Patient.fromJson(Map<String, dynamic> j) {
    final parts = [
      j['patient_first_name'] ?? '',
      j['patient_middle_name'] ?? '',
      j['patient_last_name'] ?? '',
    ].where((s) => (s as String).trim().isNotEmpty).toList();

    final genderCode = j['gender'];
    final gender = genderCode == 1
        ? 'Male'
        : genderCode == 2
            ? 'Female'
            : 'Other';

    return Patient(
      id: j['id'] ?? 0,
      uhid: j['uhid'] ?? '',
      fullName: parts.join(' '),
      age: (j['age'] ?? '').toString(),
      gender: gender,
      dob: j['dob'] ?? '',
      mobile: j['mobile'] ?? '',
    );
  }
}

class MedicineItem {
  String sr, name, dose;
  MedicineItem({required this.sr, required this.name, this.dose = ''});
}

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class PrescriptionPage extends StatefulWidget {
  const PrescriptionPage({super.key});

  @override
  State<PrescriptionPage> createState() => _PrescriptionPageState();
}

class _PrescriptionPageState extends State<PrescriptionPage> {
  // ── Handwriting ───────────────────────────────────────────
  final _notifier = ScribbleNotifier();
  late DigitalInkRecognizer _recognizer;
  Timer? _debounce;
  bool _isModelLoaded = false;
  bool _isRecognizing = false;

  // ── Patient search overlay ────────────────────────────────
  // We use a LayerLink + CompositedTransformFollower so the overlay
  // always appears directly below the search display box.
  final _layerLink      = LayerLink();
  OverlayEntry? _overlayEntry;

  // Search state — driven entirely by handwriting, no keyboard
  String            _searchQuery    = '';
  List<Patient>     _suggestions    = [];
  bool              _isSearching    = false;
  bool              _showSuggestions = false;

  // ── Patient data ──────────────────────────────────────────
  List<MedicineItem> medicines = [];

  String patientName   = '';
  String patientAge    = '';
  String patientGender = '';
  String date          = '';
  String patientUhid   = '';

  // ── Active field routing ──────────────────────────────────
  String activeField    = 'medicine';
  String selectedColumn = 'name';
  int?   editingRowIndex;

  // ── Dose helpers ──────────────────────────────────────────
  static const Map<String, String> _doseAliases = {
    '1-1-1': '1-1-1', '1-0-1': '1-0-1', '0-1-0': '0-1-0',
    '1-0-0': '1-0-0', '0-0-1': '0-0-1', '0-1-1': '0-1-1',
    '1-1-0': '1-1-0',
    'od': 'OD',   'bd': 'BD',    'tds': 'TDS', 'tid': 'TDS',
    'qid': 'QID', 'sos': 'SOS',  'prn': 'SOS', 'hs': 'HS',
    'once': 'OD', 'twice': 'BD', 'thrice': 'TDS',
    'daily': 'OD','night': 'HS', 'bedtime': 'HS',
  };

  static final List<RegExp> _dosePatterns = [
    RegExp(r'\b([01]-[01]-[01])\b',                        caseSensitive: false),
    RegExp(r'\b(OD|BD|TDS|TID|QID|SOS|PRN|HS)\b',         caseSensitive: false),
    RegExp(r'\b(once|twice|thrice|daily|night|bedtime)\b', caseSensitive: false),
  ];

  // ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadModel();
    _notifier.addListener(_onDrawChanged);
  }

  Future<void> _loadModel() async {
    final manager = DigitalInkRecognizerModelManager();
    await manager.downloadModel('en');
    _recognizer = DigitalInkRecognizer(languageCode: 'en');
    setState(() => _isModelLoaded = true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _notifier.removeListener(_onDrawChanged);
    _recognizer.close();
    _removeOverlay();
    super.dispose();
  }

  // ── Overlay management ────────────────────────────────────

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: 346, // matches the search box width (370 - 12*2 padding)
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 52), // drop below the search box
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: _buildSuggestionList(),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildSuggestionList() {
    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          _searchQuery.isEmpty
              ? 'Write on the pad to search patients'
              : 'No patients found for "$_searchQuery"',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.separated(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, color: Colors.black12),
        itemBuilder: (_, i) => _buildSuggestionTile(_suggestions[i]),
      ),
    );
  }

  Widget _buildSuggestionTile(Patient p) {
    return InkWell(
      onTap: () => _onPatientSelected(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: p.gender == 'Female'
                  ? Colors.pink.shade100
                  : Colors.blue.shade100,
              child: Text(
                p.fullName.isNotEmpty ? p.fullName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: p.gender == 'Female'
                      ? Colors.pink.shade700
                      : Colors.blue.shade700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.fullName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(
                    '${p.uhid}  •  ${p.age} yrs  •  ${p.gender}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Text(p.mobile,
                style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ),
      ),
    );
  }

  // ── Patient search (called after handwriting recognised) ──

  Future<void> _searchPatients(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _isSearching  = false;
      });
      _overlayEntry?.markNeedsBuild();
      return;
    }

    setState(() => _isSearching = true);
    _overlayEntry?.markNeedsBuild();

    try {
      final results = await PatientApiService.searchPatients(query);
      _suggestions = results;
    } catch (_) {
      _suggestions = [];
    }

    setState(() => _isSearching = false);
    _overlayEntry?.markNeedsBuild();
  }

  // ── Handwriting recognition ───────────────────────────────

  void _onDrawChanged() {
    if (!_isModelLoaded) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () async {
      if (_notifier.currentSketch.lines.isNotEmpty) await _recognizeText();
    });
  }

  Future<void> _recognizeText() async {
    if (_isRecognizing) return;
    final lines = _notifier.currentSketch.lines;
    if (lines.isEmpty) return;

    setState(() => _isRecognizing = true);

    try {
      final ink = Ink();
      int time = 0;
      for (final line in lines) {
        final stroke = Stroke();
        for (final pt in line.points) {
          time += 10;
          stroke.points.add(StrokePoint(x: pt.x, y: pt.y, t: time));
        }
        ink.strokes.add(stroke);
      }

      final candidates = await _recognizer.recognize(ink);
      if (candidates.isNotEmpty) {
        final text = _pickBest(candidates);
        if (text.isNotEmpty) _assignText(text);
      }
      _notifier.clear();
    } catch (e) {
      debugPrint('Recognition error: $e');
    }

    setState(() => _isRecognizing = false);
  }

  String _pickBest(List<RecognitionCandidate> c) {
    if (activeField == 'medicine' && selectedColumn == 'dose') {
      for (final item in c) {
        if (_extractDose(item.text) != null) return item.text.trim();
      }
    }
    return c.first.text.trim();
  }

  // ── Text helpers ──────────────────────────────────────────

  String _clean(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '').trim();

  String? _extractDose(String text) {
    for (final p in _dosePatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final raw = m.group(0)!.toLowerCase();
        return _doseAliases[raw] ?? raw.toUpperCase();
      }
    }
    return null;
  }

  ({String name, String dose}) _splitMedicineDose(String raw) {
    for (final p in _dosePatterns) {
      final m = p.firstMatch(raw);
      if (m != null) {
        final dose = _extractDose(m.group(0)!) ?? '';
        return (name: _clean(raw.substring(0, m.start)), dose: dose);
      }
    }
    return (name: _clean(raw), dose: '');
  }

  // ── Assign recognised text → correct field ─────────────────

  void _assignText(String text) {
    if (activeField != 'medicine') {
      switch (activeField) {

        case 'name':
          final q = text.trim();
          setState(() => _searchQuery = q);
          // Trigger API search and refresh overlay
          _searchPatients(q);
          _showSnack('🔍 Searching: $q', Colors.teal);
          break;

        case 'age':
          setState(() =>
              patientAge = text.replaceAll(RegExp(r'[^0-9]'), ''));
          break;

        case 'gender':
          setState(() => patientGender = _normalizeGender(text));
          break;

        case 'date':
          setState(() => date = text.replaceAll(RegExp(r'[/.]'), '-'));
          break;
      }
      return;
    }

    if (editingRowIndex != null) {
      _updateMedicine(text);
      return;
    }
    _addMedicine(text);
  }

  // ── Medicine helpers ──────────────────────────────────────

  void _updateMedicine(String text) {
    final row = medicines[editingRowIndex!];
    setState(() {
      switch (selectedColumn) {
        case 'name':
          row.name = _clean(text);
          break;
        case 'dose':
          row.dose = _extractDose(text) ?? text.toUpperCase();
          break;
        default:
          final data = _splitMedicineDose(text);
          row.name = data.name;
          row.dose = data.dose;
      }
      editingRowIndex = null;
    });
    _showSnack('✏️ Updated', Colors.orange);
  }

  void _addMedicine(String text) {
    if (selectedColumn == 'dose') {
      final idx = medicines.lastIndexWhere((m) => m.dose.isEmpty);
      if (idx != -1) {
        setState(() =>
            medicines[idx].dose = _extractDose(text) ?? text);
      }
      return;
    }

    final data = _splitMedicineDose(text);
    if (data.name.isEmpty) return;

    setState(() {
      medicines.add(MedicineItem(
        sr:   '${medicines.length + 1}',
        name: data.name,
        dose: selectedColumn == 'name' ? '' : data.dose,
      ));
    });
    _showSnack('✅ Medicine added', Colors.green);
  }

  String _normalizeGender(String text) {
    final t = text.toLowerCase();
    if (t.contains('female') || t == 'f') return 'Female';
    if (t.contains('male')   || t == 'm') return 'Male';
    return patientGender;
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 1),
      backgroundColor: color,
    ));
  }

  // ── Patient selected from overlay ─────────────────────────

  void _onPatientSelected(Patient p) {
    setState(() {
      patientName    = p.fullName;
      patientAge     = p.age;
      patientGender  = p.gender;
      date           = p.dob;
      patientUhid    = p.uhid;
      _searchQuery   = p.fullName;
      _showSuggestions = false;
    });
    _removeOverlay();
    _showSnack('👤 ${p.fullName} loaded', Colors.blue);
  }

  void _clearPatient() {
    setState(() {
      patientName = patientAge = patientGender = date = patientUhid = '';
      _searchQuery = '';
      _suggestions = [];
      _showSuggestions = false;
    });
    _removeOverlay();
  }

  // ── Field activation ──────────────────────────────────────

  void _activateNameField() {
    setState(() {
      activeField      = 'name';
      _showSuggestions = true;
      editingRowIndex  = null;
    });
    _notifier.clear();
    // Show overlay immediately (empty state = "write to search")
    _showOverlay();
  }

  void _selectColumn(String col) {
    setState(() {
      activeField     = 'medicine';
      selectedColumn  = col;
      editingRowIndex = null;
      _showSuggestions = false;
    });
    _removeOverlay();
    _notifier.clear();
  }

  void _selectCell(int row, String col) {
    setState(() {
      activeField     = 'medicine';
      selectedColumn  = col;
      editingRowIndex = row;
      _showSuggestions = false;
    });
    _removeOverlay();
    _notifier.clear();
  }

  void _setPatientField(String field) {
    setState(() {
      activeField      = field;
      _showSuggestions = false;
      editingRowIndex  = null;
    });
    _removeOverlay();
    _notifier.clear();
  }

  void _deleteMedicine(int index) {
    setState(() {
      medicines.removeAt(index);
      for (int i = 0; i < medicines.length; i++) medicines[i].sr = '${i + 1}';
    });
  }

  void _clearAll() {
    _notifier.clear();
    _clearPatient();
    setState(() {
      medicines.clear();
      activeField     = 'medicine';
      selectedColumn  = 'name';
      editingRowIndex = null;
    });
  }

  // ─────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      resizeToAvoidBottomInset: false, // keyboard never appears anyway
      body: SafeArea(
        child: Center(
          child: Container(
            width: 370,
            height: 820,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 10),
              ],
            ),
            child: Column(
              children: [
                _buildHeader(),
                _buildPatientInfo(),
                _buildRxSymbol(),
                _buildDrawArea(),
                const SizedBox(height: 4),
                _buildTableHeader(),
                _buildMedicineList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Dr. John Smith',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text('MBBS, General Physician',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
          const Spacer(),
          if (!_isModelLoaded)
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: _clearAll,
          ),
        ],
      ),
    );
  }

  // ── Patient info ──────────────────────────────────────────

  Widget _buildPatientInfo() {
    final isNameActive = activeField == 'name';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Patient search box (NO TextField, NO keyboard) ──
          CompositedTransformTarget(
            link: _layerLink,
            child: GestureDetector(
              // Tap → activate handwriting-to-search mode + show overlay
              onTap: _activateNameField,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isNameActive ? Colors.teal : Colors.black38,
                    width: isNameActive ? 2.0 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(6),
                  color: Colors.white,
                ),
                child: Row(
                  children: [
                    // Display the current search query or placeholder
                    Expanded(
                      child: Text(
                        _searchQuery.isNotEmpty
                            ? _searchQuery
                            : patientName.isNotEmpty
                                ? patientName
                                : 'Patient Name / UHID / Mobile',
                        style: TextStyle(
                          fontSize: 14,
                          color: (_searchQuery.isEmpty &&
                                  patientName.isEmpty)
                              ? Colors.black38
                              : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                    // UHID badge when a patient is selected
                    if (patientUhid.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(patientUhid,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.blue)),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: _clearPatient,
                        child: const Icon(Icons.close,
                            size: 16, color: Colors.black45),
                      ),
                    ] else
                      Icon(
                        isNameActive
                            ? Icons.draw_outlined
                            : Icons.person_search,
                        size: 20,
                        color: isNameActive ? Colors.teal : Colors.grey,
                      ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ── Age / Gender / DOB ────────────────────────────
          Row(
            children: [
              _patientField('Age',    patientAge,    'age'),
              const SizedBox(width: 12),
              _patientField('Gender', patientGender, 'gender'),
              const SizedBox(width: 12),
              _patientField('DOB',    date,          'date'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _patientField(String label, String value, String field) {
    final active = activeField == field;
    return GestureDetector(
      onTap: () => _setPatientField(field),
      child: Text(
        '$label: ${value.isEmpty ? '______' : value}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
          color:      active ? Colors.blue : Colors.black87,
        ),
      ),
    );
  }

  // ── ℞ symbol ──────────────────────────────────────────────

  Widget _buildRxSymbol() => const Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 16),
          child: Text('℞',
              style: TextStyle(
                  fontSize: 40, fontWeight: FontWeight.bold)),
        ),
      );

  // ── Handwriting pad ───────────────────────────────────────

  Widget _buildDrawArea() {
    final isName = activeField == 'name';
    final borderColor = isName
        ? Colors.teal
        : activeField == 'medicine'
            ? Colors.blue
            : Colors.purple;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
          child: Row(
            children: [
              Icon(Icons.draw_outlined, size: 13, color: borderColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _activeFieldLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    color: borderColor,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 180,
          margin: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            children: [
              Scribble(notifier: _notifier),
              if (_isRecognizing)
                Container(
                  color: Colors.white60,
                  child: const Center(
                      child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _activeFieldLabel() {
    switch (activeField) {
      case 'name':
        return _searchQuery.isEmpty
            ? '✍️  Write patient name / UHID / mobile'
            : '✍️  Searching for "$_searchQuery" …';
      case 'age':    return '✍️  Writing → Age';
      case 'gender': return '✍️  Writing → Gender';
      case 'date':   return '✍️  Writing → DOB';
      case 'medicine':
        return editingRowIndex != null
            ? '✍️  Editing row ${editingRowIndex! + 1} → '
              '${selectedColumn == 'name' ? 'Medicine Name' : 'Dose'}'
            : '✍️  Writing → '
              '${selectedColumn == 'name' ? 'Medicine Name' : 'Dose'}';
      default: return '';
    }
  }

  // ── Medicine table ────────────────────────────────────────

  Widget _buildTableHeader() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.grey.shade200,
      child: Row(
        children: [
          const SizedBox(
            width: 40,
            child: Padding(
                padding: EdgeInsets.all(10), child: Text('Sr')),
          ),
          _headerCell('Medicine', 'name', 5),
          _headerCell('Dose',     'dose', 3),
          const SizedBox(width: 32),
        ],
      ),
    );
  }

  Widget _headerCell(String text, String col, int flex) {
    final selected =
        activeField == 'medicine' && selectedColumn == col;
    return Expanded(
      flex: flex,
      child: GestureDetector(
        onTap: () => _selectColumn(col),
        child: Container(
          padding: const EdgeInsets.all(10),
          color: selected ? Colors.blue.shade100 : null,
          child: Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: selected ? Colors.blue : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMedicineList() {
    if (medicines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No medicines added yet.',
            style: TextStyle(color: Colors.black38)),
      );
    }
    return Expanded(
      child: ListView.builder(
        itemCount: medicines.length,
        itemBuilder: (_, i) => _buildRow(i),
      ),
    );
  }

  Widget _buildRow(int index) {
    final item     = medicines[index];
    final selected = editingRowIndex == index;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? Colors.blue.shade50 : Colors.white,
        border: Border.all(
            color: selected ? Colors.blue : Colors.black12),
      ),
      child: Row(
        children: [
          _cell(item.sr, width: 40),
          Expanded(
            flex: 5,
            child: GestureDetector(
              onTap: () => _selectCell(index, 'name'),
              child: _cell(item.name),
            ),
          ),
          Expanded(
            flex: 3,
            child: GestureDetector(
              onTap: () => _selectCell(index, 'dose'),
              child: _cell(item.dose.isEmpty ? '—' : item.dose),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => _deleteMedicine(index),
          ),
        ],
      ),
    );
  }

  Widget _cell(String text, {double? width}) {
    final child = Padding(
      padding: const EdgeInsets.all(10),
      child: Text(text.isEmpty ? '—' : text),
    );
    return width == null
        ? child
        : SizedBox(width: width, child: child);
  }
}