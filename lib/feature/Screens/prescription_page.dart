import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart' hide Ink;
import 'package:priscription_app/core/network/api_service.dart';
import 'package:scribble/scribble.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

// ─── Models ────────────────────────────────────────────────────────────────

class Patient {
  final int id;
  final String uhid;
  final String patientCode;
  final String fullName;
  final String age;
  final String gender;
  final String dob;
  final String mobile;

  const Patient({
    required this.id,
    required this.uhid,
    required this.patientCode,
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
      patientCode: j['patient_code'] ?? j['uhid'] ?? '',
      fullName: parts.join(' '),
      age: (j['age'] ?? '').toString(),
      gender: gender,
      dob: j['dob'] ?? '',
      mobile: j['mobile'] ?? '',
    );
  }
}

class DoctorData {
  final String fullName;
  final String qualifications;

  DoctorData({required this.fullName, required this.qualifications});

  factory DoctorData.fromJson(Map<String, dynamic> json) {
    return DoctorData(
      fullName: json['doctor_name'] ?? '',
      qualifications: json['qualification'] ?? '',
    );
  }
}

class MedicineItem {
  String sr, name, dose, meal, duration;

  MedicineItem({
    required this.sr,
    required this.name,
    this.dose = '',
    this.meal = '',
    this.duration = '',
  });
}

class MedicineSuggestion {
  final int id;
  final String name;

  MedicineSuggestion({required this.id, required this.name});

  factory MedicineSuggestion.fromJson(Map<String, dynamic> j) {
    return MedicineSuggestion(
      id: j['id'] ?? 0,
      name: j['medicine_name'] ?? j['name'] ?? '',
    );
  }
}

// ─── NEW: Symptom & Diagnosis tag models ───────────────────────────────────

class SymptomTag {
  final int? id;
  final String name;
  SymptomTag({this.id, required this.name});
}

class DiagnosisTag {
  final int? id;
  final String name;
  DiagnosisTag({this.id, required this.name});
}

// ─── Widget ─────────────────────────────────────────────────────────────────

class PrescriptionPage extends StatefulWidget {
  const PrescriptionPage({super.key});

  @override
  State<PrescriptionPage> createState() => _PrescriptionPageState();
}

class _PrescriptionPageState extends State<PrescriptionPage> {
  // ── Controllers & notifiers ──────────────────────────────────────────────
  final ScribbleNotifier _notifier = ScribbleNotifier();
  final TextEditingController _keyboardController = TextEditingController();

  // ── Storage ──────────────────────────────────────────────────────────────
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  // ── ML Kit & Speech ──────────────────────────────────────────────────────
  late DigitalInkRecognizer _recognizer;
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _spokenText = '';
  Timer? _debounce;
  bool _isModelLoaded = false;
  bool _isRecognizing = false;
  bool _isSaving = false;

  // ── Doctor ───────────────────────────────────────────────────────────────
  DoctorData? doctorData;
  bool _loadingDoctor = true;

  // ── Patient search overlay ───────────────────────────────────────────────
  final _patientLayerLink = LayerLink();
  OverlayEntry? _patientOverlayEntry;
  String _searchQuery = '';
  List<Patient> _suggestions = [];
  bool _isSearching = false;
  bool _showSuggestions = false;

  // ── Medicine overlay ─────────────────────────────────────────────────────
  final _medicineLayerLinks = <int, LayerLink>{};
  OverlayEntry? _medicineOverlayEntry;
  int? _activeMedicineRow;
  String _medicineSearchQuery = '';
  List<MedicineSuggestion> _medicineSuggestions = [];
  bool _isSearchingMedicine = false;
  Timer? _medicineDebounce;

  // ── Patient fields ───────────────────────────────────────────────────────
  String patientName = '';
  String patientAge = '';
  String patientGender = '';
  String date = '';
  String patientUhid = '';
  String patientCode = '';
  int patientId = 0;

  // ── Symptoms ─────────────────────────────────────────────────────────────
  List<SymptomTag> _selectedSymptoms = [];
  final _symptomLayerLink = LayerLink();
  OverlayEntry? _symptomOverlayEntry;
  String _symptomQuery = '';
  List<SymptomTag> _symptomSuggestions = [];
  bool _isSearchingSymptom = false;
  bool _isSavingSymptom = false;
  Timer? _symptomDebounce;

  static const List<String> _commonSymptoms = [
    'Fever', 'Cough', 'Cold', 'Headache', 'Fatigue', 'Nausea',
    'Vomiting', 'Diarrhoea', 'Constipation', 'Chest Pain',
    'Shortness of Breath', 'Body Ache', 'Sore Throat', 'Dizziness',
    'Loss of Appetite', 'Abdominal Pain', 'Back Pain', 'Joint Pain',
    'Skin Rash', 'Itching', 'Swelling', 'Burning Urination',
  ];

  // ── Diagnosis ────────────────────────────────────────────────────────────
  List<DiagnosisTag> _selectedDiagnosis = [];
  final _diagnosisLayerLink = LayerLink();
  OverlayEntry? _diagnosisOverlayEntry;
  String _diagnosisQuery = '';
  List<DiagnosisTag> _diagnosisSuggestions = [];
  bool _isSearchingDiagnosis = false;
  bool _isSavingDiagnosis = false;
  Timer? _diagnosisDebounce;

  static const List<String> _commonDiagnoses = [
    'Viral Fever', 'URI', 'Hypertension', 'Type 2 Diabetes',
    'Asthma', 'GERD', 'Bronchitis', 'Pneumonia', 'UTI',
    'Anaemia', 'Hypothyroidism', 'Migraine', 'Dengue',
    'Malaria', 'Typhoid', 'COVID-19', 'Sinusitis', 'Arthritis',
    'Eczema', 'Dermatitis', 'Peptic Ulcer', 'IBS',
  ];

  // ── Medicine table ───────────────────────────────────────────────────────
  List<MedicineItem> medicines = [];
  String activeField = 'medicine';
  String selectedColumn = 'name';
  int? editingRowIndex;

  // ── Common medicines list ─────────────────────────────────────────────────
  static const List<String> _commonMedicines = [
    "Paracetamol 500mg", "Diclofenac 50mg", "Aceclofenac 100mg",
    "Aspirin 75mg", "Amoxicillin 500mg", "Azithromycin 500mg",
    "Cefixime 200mg", "Ciprofloxacin 500mg", "Metronidazole 400mg",
    "Cetirizine 10mg", "Levocetirizine 5mg", "Montelukast 10mg",
    "Hydroxyzine 25mg", "Pantoprazole 40mg", "Omeprazole 20mg",
    "Rabeprazole 20mg", "Antacid Syrup", "Domperidone 10mg",
    "Metformin 500mg", "Glimepiride 2mg", "Insulin Regular",
    "Voglibose 0.3mg", "Teneligliptin 20mg", "Amlodipine 5mg",
    "Telmisartan 40mg", "Losartan 50mg", "Atenolol 50mg",
    "Ambroxol Syrup", "Calcium Tablet", "Vitamin C Tablet",
    "Vitamin D3 Sachet", "Iron Tablet", "Multivitamin Capsule",
    "ORS Powder", "Zinc Tablet", "Soframycin Cream",
  ];

  // ── Dose aliases ──────────────────────────────────────────────────────────
  static const Map<String, String> _doseAliases = {
    '1-0-0-0': '1-0-0-0', '0-1-0-0': '0-1-0-0', '0-0-1-0': '0-0-1-0',
    '0-0-0-1': '0-0-0-1', '1-1-0-0': '1-1-0-0', '1-0-1-0': '1-0-1-0',
    '1-0-0-1': '1-0-0-1', '0-1-1-0': '0-1-1-0', '0-1-0-1': '0-1-0-1',
    '0-0-1-1': '0-0-1-1', '1-1-1-0': '1-1-1-0', '1-1-0-1': '1-1-0-1',
    '1-0-1-1': '1-0-1-1', '0-1-1-1': '0-1-1-1', '1-1-1-1': '1-1-1-1',
  };

  static const Map<String, String> _mealAliases = {
    'before meal': 'Before meal', 'before meals': 'Before meal',
    'empty stomach': 'Before meal', 'after meal': 'After meal',
    'after meals': 'After meal', 'with meal': 'With meal',
    'with meals': 'With meal',
  };

  static final List<RegExp> _dosePatterns = [
    RegExp(r'\b([01]-[01]-[01]-[01])\b', caseSensitive: false),
  ];

  static final RegExp _durationPattern = RegExp(
    r'\b(\d+)\s*(day|days|week|weeks|month|months)\b',
    caseSensitive: false,
  );

  static const List<String> _doseOptions = [
    '1-0-0-0', '0-1-0-0', '0-0-1-0', '0-0-0-1',
    '1-1-0-0', '1-0-1-0', '1-0-0-1', '0-1-1-0',
    '0-1-0-1', '0-0-1-1', '1-1-1-0', '1-1-0-1',
    '1-0-1-1', '0-1-1-1', '1-1-1-1',
  ];

  static const List<String> _mealOptions = [
    'Before meal', 'After meal', 'With meal',
  ];

  static const List<String> _durationOptions = [
    '1 day', '5 days', '7 days', '15 days', '30 days',
  ];

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadDoctorDetails();
    _loadModel();
    _notifier.addListener(_onDrawChanged);
    _speech = stt.SpeechToText();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _medicineDebounce?.cancel();
    _symptomDebounce?.cancel();
    _diagnosisDebounce?.cancel();
    _notifier.removeListener(_onDrawChanged);
    _keyboardController.dispose();
    if (_isModelLoaded) _recognizer.close();
    _removePatientOverlay();
    _removeMedicineOverlay();
    _removeSymptomOverlay();
    _removeDiagnosisOverlay();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Auth headers
  // ─────────────────────────────────────────────────────────────────────────

  static Future<Map<String, String>> _headers() async {
    final token = await _storage.read(key: 'access_token');
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      if (token != null) "Authorization": "Bearer $token",
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Doctor
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadDoctorDetails() async {
    try {
      final response = await http.get(
        Uri.parse('https://hms.yourhrms.in/api/doctor/DOC001/'),
        headers: await _headers(),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          doctorData = DoctorData.fromJson(data);
          _loadingDoctor = false;
        });
      } else {
        setState(() => _loadingDoctor = false);
      }
    } catch (e) {
      debugPrint("Doctor API Error: $e");
      setState(() => _loadingDoctor = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ML Kit model
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadModel() async {
    try {
      final manager = DigitalInkRecognizerModelManager();
      final isDownloaded = await manager.isModelDownloaded('en-US');
      if (!isDownloaded) await manager.downloadModel('en-US');
      _recognizer = mlkit.DigitalInkRecognizer(languageCode: 'en-US');
      if (mounted) setState(() => _isModelLoaded = true);
    } catch (e) {
      debugPrint("Model load failed: $e");
      if (mounted) setState(() => _isModelLoaded = true);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Patient overlay
  // ─────────────────────────────────────────────────────────────────────────

  void _showPatientOverlay() {
    _removePatientOverlay();
    final overlay = Overlay.of(context);
    _patientOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: 346,
        child: CompositedTransformFollower(
          link: _patientLayerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 52),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: _buildPatientSuggestionList(),
          ),
        ),
      ),
    );
    overlay.insert(_patientOverlayEntry!);
  }

  void _removePatientOverlay() {
    _patientOverlayEntry?.remove();
    _patientOverlayEntry = null;
  }

  Widget _buildPatientSuggestionList() {
    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_suggestions.isEmpty && _searchQuery.isNotEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.separated(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
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
              backgroundColor: p.gender == 'Female' ? Colors.pink.shade100 : Colors.blue.shade100,
              child: Text(
                p.fullName.isNotEmpty ? p.fullName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: p.gender == 'Female' ? Colors.pink.shade700 : Colors.blue.shade700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.fullName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text('${p.uhid}  •  ${p.age} yrs  •  ${p.gender}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            Text(p.mobile, style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Symptom overlay
  // ─────────────────────────────────────────────────────────────────────────

  void _showSymptomOverlay() {
    _removeSymptomOverlay();
    _symptomSuggestions = _commonSymptoms.map((n) => SymptomTag(name: n)).toList();
    final overlay = Overlay.of(context);
    _symptomOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: 320,
        child: CompositedTransformFollower(
          link: _symptomLayerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 40),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: _buildTagOverlayContent(
              query: _symptomQuery,
              suggestions: _symptomSuggestions,
              isSearching: _isSearchingSymptom,
              isSaving: _isSavingSymptom,
              onQueryChanged: (val) {
                _symptomQuery = val;
                _symptomDebounce?.cancel();
                _symptomDebounce = Timer(
                  const Duration(milliseconds: 400),
                  () => _fetchSymptomSuggestions(val),
                );
                _symptomOverlayEntry?.markNeedsBuild();
              },
              onSelect: _onSymptomSelected,
              onCustomAdd: () => _addCustomSymptom(_symptomQuery),
              hintText: 'Search or type symptom...',
              accentColor: Colors.orange.shade700,
            ),
          ),
        ),
      ),
    );
    overlay.insert(_symptomOverlayEntry!);
  }

  void _removeSymptomOverlay() {
    _symptomOverlayEntry?.remove();
    _symptomOverlayEntry = null;
  }

  Future<void> _fetchSymptomSuggestions(String query) async {
    if (query.trim().isEmpty) {
      _symptomSuggestions = _commonSymptoms.map((n) => SymptomTag(name: n)).toList();
      _isSearchingSymptom = false;
      _symptomOverlayEntry?.markNeedsBuild();
      return;
    }
    _isSearchingSymptom = true;
    _symptomOverlayEntry?.markNeedsBuild();
    try {
      final uri = Uri.parse(
          'https://hms.yourhrms.in/api/master-symptoms/?search=${Uri.encodeComponent(query)}');
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List items = data is List ? data : (data['results'] ?? []);
        _symptomSuggestions = items
            .map((j) => SymptomTag(id: j['id'], name: j['symptom_name'] ?? j['name'] ?? ''))
            .where((s) => s.name.isNotEmpty)
            .toList();
        if (_symptomSuggestions.isEmpty) {
          _symptomSuggestions = _commonSymptoms
              .where((n) => n.toLowerCase().contains(query.toLowerCase()))
              .map((n) => SymptomTag(name: n))
              .toList();
        }
      } else {
        _symptomSuggestions = _commonSymptoms
            .where((n) => n.toLowerCase().contains(query.toLowerCase()))
            .map((n) => SymptomTag(name: n))
            .toList();
      }
    } catch (_) {
      _symptomSuggestions = _commonSymptoms
          .where((n) => n.toLowerCase().contains(query.toLowerCase()))
          .map((n) => SymptomTag(name: n))
          .toList();
    }
    _isSearchingSymptom = false;
    _symptomOverlayEntry?.markNeedsBuild();
  }

  Future<void> _onSymptomSelected(String name) async {
    if (_selectedSymptoms.any((s) => s.name.toLowerCase() == name.toLowerCase())) {
      _removeSymptomOverlay();
      return;
    }
    setState(() => _isSavingSymptom = true);
    _symptomOverlayEntry?.markNeedsBuild();
    try {
      final response = await http.post(
        Uri.parse('https://hms.yourhrms.in/api/master-symptoms/create/'),
        headers: await _headers(),
        body: jsonEncode({'symptom_name': name}),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final tag = SymptomTag(id: data['id'], name: data['symptom_name'] ?? name);
        setState(() => _selectedSymptoms.add(tag));
      } else {
        // Still add locally even if API returns conflict/existing
        setState(() => _selectedSymptoms.add(SymptomTag(name: name)));
      }
    } catch (_) {
      setState(() => _selectedSymptoms.add(SymptomTag(name: name)));
    }
    setState(() => _isSavingSymptom = false);
    _symptomQuery = '';
    _removeSymptomOverlay();
  }

  Future<void> _addCustomSymptom(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _onSymptomSelected(trimmed);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Diagnosis overlay
  // ─────────────────────────────────────────────────────────────────────────

  void _showDiagnosisOverlay() {
    _removeDiagnosisOverlay();
    _diagnosisSuggestions = _commonDiagnoses.map((n) => DiagnosisTag(name: n)).toList();
    final overlay = Overlay.of(context);
    _diagnosisOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: 320,
        child: CompositedTransformFollower(
          link: _diagnosisLayerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 40),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: _buildTagOverlayContent(
              query: _diagnosisQuery,
              suggestions: _diagnosisSuggestions,
              isSearching: _isSearchingDiagnosis,
              isSaving: _isSavingDiagnosis,
              onQueryChanged: (val) {
                _diagnosisQuery = val;
                _diagnosisDebounce?.cancel();
                _diagnosisDebounce = Timer(
                  const Duration(milliseconds: 400),
                  () => _fetchDiagnosisSuggestions(val),
                );
                _diagnosisOverlayEntry?.markNeedsBuild();
              },
              onSelect: _onDiagnosisSelected,
              onCustomAdd: () => _addCustomDiagnosis(_diagnosisQuery),
              hintText: 'Search or type diagnosis...',
              accentColor: Colors.purple.shade600,
            ),
          ),
        ),
      ),
    );
    overlay.insert(_diagnosisOverlayEntry!);
  }

  void _removeDiagnosisOverlay() {
    _diagnosisOverlayEntry?.remove();
    _diagnosisOverlayEntry = null;
  }

  Future<void> _fetchDiagnosisSuggestions(String query) async {
    if (query.trim().isEmpty) {
      _diagnosisSuggestions = _commonDiagnoses.map((n) => DiagnosisTag(name: n)).toList();
      _isSearchingDiagnosis = false;
      _diagnosisOverlayEntry?.markNeedsBuild();
      return;
    }
    _isSearchingDiagnosis = true;
    _diagnosisOverlayEntry?.markNeedsBuild();
    try {
      final uri = Uri.parse(
          'https://hms.yourhrms.in/api/master-diagnosis/?search=${Uri.encodeComponent(query)}');
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List items = data is List ? data : (data['results'] ?? []);
        _diagnosisSuggestions = items
            .map((j) => DiagnosisTag(id: j['id'], name: j['diagnosis_name'] ?? j['name'] ?? ''))
            .where((d) => d.name.isNotEmpty)
            .toList();
        if (_diagnosisSuggestions.isEmpty) {
          _diagnosisSuggestions = _commonDiagnoses
              .where((n) => n.toLowerCase().contains(query.toLowerCase()))
              .map((n) => DiagnosisTag(name: n))
              .toList();
        }
      } else {
        _diagnosisSuggestions = _commonDiagnoses
            .where((n) => n.toLowerCase().contains(query.toLowerCase()))
            .map((n) => DiagnosisTag(name: n))
            .toList();
      }
    } catch (_) {
      _diagnosisSuggestions = _commonDiagnoses
          .where((n) => n.toLowerCase().contains(query.toLowerCase()))
          .map((n) => DiagnosisTag(name: n))
          .toList();
    }
    _isSearchingDiagnosis = false;
    _diagnosisOverlayEntry?.markNeedsBuild();
  }

  Future<void> _onDiagnosisSelected(String name) async {
    if (_selectedDiagnosis.any((d) => d.name.toLowerCase() == name.toLowerCase())) {
      _removeDiagnosisOverlay();
      return;
    }
    setState(() => _isSavingDiagnosis = true);
    _diagnosisOverlayEntry?.markNeedsBuild();
    try {
      final response = await http.post(
        Uri.parse('https://hms.yourhrms.in/api/master-diagnosis/create/'),
        headers: await _headers(),
        body: jsonEncode({'diagnosis_name': name}),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final tag = DiagnosisTag(id: data['id'], name: data['diagnosis_name'] ?? name);
        setState(() => _selectedDiagnosis.add(tag));
      } else {
        setState(() => _selectedDiagnosis.add(DiagnosisTag(name: name)));
      }
    } catch (_) {
      setState(() => _selectedDiagnosis.add(DiagnosisTag(name: name)));
    }
    setState(() => _isSavingDiagnosis = false);
    _diagnosisQuery = '';
    _removeDiagnosisOverlay();
  }

  Future<void> _addCustomDiagnosis(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _onDiagnosisSelected(trimmed);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Shared tag overlay content builder
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildTagOverlayContent({
    required String query,
    required List suggestions,
    required bool isSearching,
    required bool isSaving,
    required void Function(String) onQueryChanged,
    required Future<void> Function(String) onSelect,
    required Future<void> Function() onCustomAdd,
    required String hintText,
    required Color accentColor,
  }) {
    return StatefulBuilder(
      builder: (ctx, setOverlayState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                autofocus: true,
                controller: TextEditingController(text: query)
                  ..selection = TextSelection.collapsed(offset: query.length),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: const TextStyle(fontSize: 12, color: Colors.black38),
                  prefixIcon: const Icon(Icons.search, size: 16, color: Colors.grey),
                  suffixIcon: query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 14, color: Colors.black45),
                          onPressed: () {
                            onQueryChanged('');
                            setOverlayState(() {});
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.black26, width: 1)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: accentColor, width: 1.5)),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (val) {
                  onQueryChanged(val);
                  setOverlayState(() {});
                },
              ),
            ),
            if (query.isNotEmpty) ...[
              InkWell(
                onTap: onCustomAdd,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.add_circle_outline, size: 16, color: accentColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Add "$query"',
                          style: TextStyle(fontSize: 12, color: accentColor, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isSaving) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.black12),
            ],
            if (isSearching)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: suggestions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('No results found', style: TextStyle(fontSize: 12, color: Colors.black38)),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
                        itemBuilder: (_, i) {
                          final name = (suggestions[i] as dynamic).name as String;
                          return InkWell(
                            onTap: () => onSelect(name),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              child: Row(
                                children: [
                                  Icon(Icons.label_outline, size: 14, color: accentColor),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
          ],
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Medicine overlay
  // ─────────────────────────────────────────────────────────────────────────

  LayerLink _getMedicineLinkForRow(int index) {
    _medicineLayerLinks[index] ??= LayerLink();
    return _medicineLayerLinks[index]!;
  }

  void _showMedicineOverlay(int rowIndex) {
    _removeMedicineOverlay();
    _activeMedicineRow = rowIndex;
    _medicineSearchQuery = medicines[rowIndex].name;

    final overlay = Overlay.of(context);
    _medicineOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: 260,
        child: CompositedTransformFollower(
          link: _getMedicineLinkForRow(rowIndex),
          showWhenUnlinked: false,
          offset: const Offset(0, 36),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            child: _buildMedicineOverlayContent(rowIndex),
          ),
        ),
      ),
    );
    overlay.insert(_medicineOverlayEntry!);

    _medicineSuggestions = _commonMedicines.map((n) => MedicineSuggestion(id: 0, name: n)).toList();
    _medicineOverlayEntry?.markNeedsBuild();
  }

  void _removeMedicineOverlay() {
    _medicineOverlayEntry?.remove();
    _medicineOverlayEntry = null;
    _activeMedicineRow = null;
  }

  Widget _buildMedicineOverlayContent(int rowIndex) {
    return StatefulBuilder(
      builder: (ctx, setOverlayState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                autofocus: true,
                controller: TextEditingController(text: _medicineSearchQuery)
                  ..selection = TextSelection.collapsed(offset: _medicineSearchQuery.length),
                decoration: InputDecoration(
                  hintText: 'Search medicine...',
                  hintStyle: const TextStyle(fontSize: 12, color: Colors.black38),
                  prefixIcon: const Icon(Icons.search, size: 16, color: Colors.grey),
                  suffixIcon: _medicineSearchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 14, color: Colors.black45),
                          onPressed: () {
                            setOverlayState(() => _medicineSearchQuery = '');
                            _medicineSuggestions = _commonMedicines
                                .map((n) => MedicineSuggestion(id: 0, name: n))
                                .toList();
                            _medicineOverlayEntry?.markNeedsBuild();
                          },
                        )
                      : null,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.black26, width: 1)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Colors.teal, width: 1.5)),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (val) {
                  setOverlayState(() => _medicineSearchQuery = val);
                  _medicineDebounce?.cancel();
                  _medicineDebounce = Timer(
                      const Duration(milliseconds: 400),
                      () => _fetchMedicineSuggestions(val));
                },
              ),
            ),
            const Divider(height: 1, color: Colors.black12),
            if (_isSearchingMedicine)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: _medicineSuggestions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('No medicines found', style: TextStyle(fontSize: 12, color: Colors.black38)),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: _medicineSuggestions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.black12),
                        itemBuilder: (_, i) {
                          final med = _medicineSuggestions[i];
                          return InkWell(
                            onTap: () {
                              setState(() => medicines[rowIndex].name = med.name);
                              _removeMedicineOverlay();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.medication_outlined, size: 16, color: Colors.teal),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(med.name, style: const TextStyle(fontSize: 13))),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _fetchMedicineSuggestions(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _medicineSuggestions = _commonMedicines.map((n) => MedicineSuggestion(id: 0, name: n)).toList();
        _isSearchingMedicine = false;
      });
      _medicineOverlayEntry?.markNeedsBuild();
      return;
    }
    setState(() => _isSearchingMedicine = true);
    _medicineOverlayEntry?.markNeedsBuild();
    try {
      final uri = Uri.parse(
          'https://hms.yourhrms.in/api/medicines/?search=${Uri.encodeComponent(query)}');
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List items = data is List ? data : (data['results'] ?? []);
        _medicineSuggestions = items.map((j) => MedicineSuggestion.fromJson(j)).toList();
        if (_medicineSuggestions.isEmpty) {
          _medicineSuggestions = _commonMedicines
              .where((n) => n.toLowerCase().contains(query.toLowerCase()))
              .map((n) => MedicineSuggestion(id: 0, name: n))
              .toList();
        }
      } else {
        _medicineSuggestions = _commonMedicines
            .where((n) => n.toLowerCase().contains(query.toLowerCase()))
            .map((n) => MedicineSuggestion(id: 0, name: n))
            .toList();
      }
    } catch (_) {
      _medicineSuggestions = _commonMedicines
          .where((n) => n.toLowerCase().contains(query.toLowerCase()))
          .map((n) => MedicineSuggestion(id: 0, name: n))
          .toList();
    }
    setState(() => _isSearchingMedicine = false);
    _medicineOverlayEntry?.markNeedsBuild();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Voice
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startListening() async {
    bool available = await _speech.initialize(
      onError: (error) {
        setState(() { _isListening = false; _spokenText = ''; });
        _showSnack('🎤 Voice error: ${error.errorMsg}', Colors.red);
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') setState(() => _isListening = false);
      },
    );
    if (available) {
      setState(() { _isListening = true; _spokenText = ''; });
      _speech.listen(
        onResult: (result) {
          setState(() => _spokenText = result.recognizedWords);
          if (result.finalResult) {
            _assignText(_spokenText);
            setState(() { _isListening = false; _spokenText = ''; });
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        localeId: 'en_IN',
      );
    } else {
      _showSnack('🎤 Microphone not available', Colors.red);
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() { _isListening = false; _spokenText = ''; });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Patient search
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _searchPatients(String query) async {
    if (query.trim().isEmpty) {
      setState(() { _suggestions = []; _isSearching = false; });
      _patientOverlayEntry?.markNeedsBuild();
      return;
    }
    setState(() => _isSearching = true);
    _patientOverlayEntry?.markNeedsBuild();
    try {
      final results = await PatientApiService.searchPatients(query);
      _suggestions = results;
    } catch (e) {
      debugPrint('❌ Search error: $e');
      _suggestions = [];
    }
    setState(() => _isSearching = false);
    _patientOverlayEntry?.markNeedsBuild();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Drawing / recognition
  // ─────────────────────────────────────────────────────────────────────────

  void _onDrawChanged() {
    if (!_isModelLoaded || _isRecognizing) return;
    _debounce?.cancel();
    final lines = _notifier.currentSketch.lines;
    if (lines.isEmpty) return;
    final totalPoints = lines.fold<int>(0, (sum, l) => sum + l.points.length);
    if (totalPoints < 5) return;
    _debounce = Timer(const Duration(milliseconds: 800), _recognizeText);
  }

  Future<void> _recognizeText() async {
    if (_isRecognizing) return;
    final lines = _notifier.currentSketch.lines;
    if (lines.isEmpty) return;
    setState(() => _isRecognizing = true);
    try {
      final ink = mlkit.Ink();
      int time = 0;
      for (final line in lines) {
        final stroke = mlkit.Stroke();
        for (final pt in line.points) {
          time += 10;
          stroke.points.add(mlkit.StrokePoint(x: pt.x, y: pt.y, t: time));
        }
        ink.strokes.add(stroke);
      }
      final candidates = await _recognizer.recognize(ink);
      if (candidates.isNotEmpty) {
        final text = _pickBest(candidates);
        if (text.trim().isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 100));
          _assignText(text);
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      debugPrint('Recognition error: $e');
    } finally {
      if (mounted) setState(() => _isRecognizing = false);
      await Future.delayed(const Duration(milliseconds: 1500));
      _notifier.clear();
    }
  }

  String _pickBest(List<RecognitionCandidate> c) {
    if (activeField == 'medicine' && selectedColumn == 'dose') {
      for (final item in c) {
        if (_extractDose(item.text) != null) return item.text.trim();
      }
    }
    if (activeField == 'medicine' && selectedColumn == 'meal') {
      for (final item in c) {
        if (_normalizeMeal(item.text).isNotEmpty) return item.text.trim();
      }
    }
    return c.first.text.trim();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Text helpers
  // ─────────────────────────────────────────────────────────────────────────

  String _clean(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '').trim();

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

  String _normalizeMeal(String text) {
    final lower = text.toLowerCase();
    for (final entry in _mealAliases.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return '';
  }

  String _doseToFrequency(String dose) {
    if (dose.isEmpty) return '';
    final parts = dose.split('-');
    const labels = ['M', 'A', 'E', 'N'];
    final active = <String>[];
    for (int i = 0; i < parts.length && i < labels.length; i++) {
      if ((int.tryParse(parts[i]) ?? 0) > 0) active.add(labels[i]);
    }
    return active.join('-');
  }

  int _durationToDays(String duration) {
    if (duration.isEmpty) return 0;
    final lower = duration.toLowerCase();
    final numMatch = RegExp(r'\d+').firstMatch(lower);
    if (numMatch == null) return 0;
    final num = int.tryParse(numMatch.group(0)!) ?? 0;
    if (lower.contains('month')) return num * 30;
    if (lower.contains('week')) return num * 7;
    return num;
  }

  ({String name, String dose, String meal, String duration}) _splitMedicineDose(String raw) {
    String remaining = raw;
    String dose = '';
    String meal = '';
    String duration = '';

    for (final p in _dosePatterns) {
      final m = p.firstMatch(remaining);
      if (m != null) {
        dose = _extractDose(m.group(0)!) ?? '';
        remaining = remaining.substring(0, m.start) + remaining.substring(m.end);
        break;
      }
    }

    final lower = remaining.toLowerCase();
    for (final entry in _mealAliases.entries) {
      if (lower.contains(entry.key)) {
        meal = entry.value;
        final idx = lower.indexOf(entry.key);
        remaining = remaining.substring(0, idx) + remaining.substring(idx + entry.key.length);
        break;
      }
    }

    final durMatch = _durationPattern.firstMatch(remaining);
    if (durMatch != null) {
      duration = durMatch.group(0)!.trim();
      remaining = remaining.substring(0, durMatch.start) + remaining.substring(durMatch.end);
    }

    return (name: _clean(remaining), dose: dose, meal: meal, duration: duration);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Assign recognized / typed text
  // ─────────────────────────────────────────────────────────────────────────

  void _assignText(String text) {
    if (activeField == 'symptom') {
      _onSymptomSelected(text.trim());
      return;
    }
    if (activeField == 'diagnosis') {
      _onDiagnosisSelected(text.trim());
      return;
    }
    if (activeField != 'medicine') {
      switch (activeField) {
        case 'name':
          final q = text.trim();
          setState(() => _searchQuery = q);
          _searchPatients(q);
          _showSnack('🔍 Searching: $q', Colors.teal);
          break;
        case 'age':
          setState(() => patientAge = text.replaceAll(RegExp(r'[^0-9]'), ''));
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

  void _updateMedicine(String text) {
    final row = medicines[editingRowIndex!];
    setState(() {
      switch (selectedColumn) {
        case 'name':
          row.name = _clean(text);
          _medicineSearchQuery = _clean(text);
          break;
        case 'dose':
          row.dose = _extractDose(text) ?? text.toUpperCase();
          break;
        case 'meal':
          row.meal = _normalizeMeal(text);
          break;
        case 'duration':
          final m = _durationPattern.firstMatch(text);
          row.duration = m != null ? m.group(0)!.trim() : text.trim();
          break;
      }
      editingRowIndex = null;
    });
    _showSnack('✏️ Updated', Colors.orange);
  }

  void _addMedicine(String text) {
    if (selectedColumn == 'dose') {
      final idx = medicines.lastIndexWhere((m) => m.dose.isEmpty);
      if (idx != -1) setState(() => medicines[idx].dose = _extractDose(text) ?? text);
      return;
    }
    if (selectedColumn == 'meal') {
      final idx = medicines.lastIndexWhere((m) => m.meal.isEmpty);
      if (idx != -1) setState(() => medicines[idx].meal = _normalizeMeal(text));
      return;
    }
    if (selectedColumn == 'duration') {
      final idx = medicines.lastIndexWhere((m) => m.duration.isEmpty);
      if (idx != -1) {
        final m = _durationPattern.firstMatch(text);
        setState(() => medicines[idx].duration = m != null ? m.group(0)!.trim() : text.trim());
      }
      return;
    }
    final data = _splitMedicineDose(text);
    if (data.name.isEmpty) return;
    setState(() {
      medicines.add(MedicineItem(
        sr: '${medicines.length + 1}',
        name: data.name,
        dose: data.dose,
        meal: data.meal,
        duration: data.duration,
      ));
    });
    _showSnack('✅ Medicine added', Colors.green);
  }

  String _normalizeGender(String text) {
    final t = text.toLowerCase();
    if (t.contains('female') || t == 'f') return 'Female';
    if (t.contains('male') || t == 'm') return 'Male';
    return patientGender;
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1), backgroundColor: color),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Patient selection / clear
  // ─────────────────────────────────────────────────────────────────────────

  void _onPatientSelected(Patient p) {
    setState(() {
      patientId = p.id;
      patientName = p.fullName;
      patientAge = p.age;
      patientGender = p.gender;
      date = p.dob;
      patientUhid = p.uhid;
      patientCode = p.patientCode;
      _searchQuery = p.fullName;
      _showSuggestions = false;
      _suggestions = [];
    });
    _keyboardController.clear();
    _removePatientOverlay();
    _showSnack('👤 ${p.fullName} loaded', Colors.blue);
  }

  void _clearPatient() {
    setState(() {
      patientId = 0;
      patientCode = '';
      patientName = '';
      patientAge = '';
      patientGender = '';
      date = '';
      patientUhid = '';
      _searchQuery = '';
      _suggestions = [];
      _showSuggestions = false;
    });
    _keyboardController.clear();
    _removePatientOverlay();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Field activation
  // ─────────────────────────────────────────────────────────────────────────

  void _activateNameField() {
    setState(() {
      activeField = 'name';
      _showSuggestions = true;
      editingRowIndex = null;
    });
    _keyboardController.text = _searchQuery;
    _keyboardController.selection =
        TextSelection.fromPosition(TextPosition(offset: _searchQuery.length));
    _showPatientOverlay();
  }

  void _selectColumn(String col) {
    setState(() {
      activeField = 'medicine';
      selectedColumn = col;
      editingRowIndex = null;
    });
    _removeMedicineOverlay();
  }

  void _selectCell(int row, String col) {
    setState(() {
      activeField = 'medicine';
      selectedColumn = col;
      editingRowIndex = row;
      _showSuggestions = false;
    });
    if (col == 'name') {
      _showMedicineOverlay(row);
    } else {
      _removeMedicineOverlay();
    }
    final item = medicines[row];
    final existing = switch (col) {
      'name' => item.name,
      'dose' => item.dose,
      'meal' => item.meal,
      'duration' => item.duration,
      _ => '',
    };
    _keyboardController.text = existing;
    _keyboardController.selection =
        TextSelection.fromPosition(TextPosition(offset: existing.length));
  }

  void _setPatientField(String field) {
    setState(() {
      activeField = field;
      _showSuggestions = false;
      editingRowIndex = null;
    });
    _removeMedicineOverlay();
    _removeSymptomOverlay();
    _removeDiagnosisOverlay();
  }

  void _activateSymptomField() {
    setState(() {
      activeField = 'symptom';
      editingRowIndex = null;
      _showSuggestions = false;
    });
    _removeMedicineOverlay();
    _removePatientOverlay();
    _removeDiagnosisOverlay();
    _symptomQuery = '';
    _showSymptomOverlay();
    _keyboardController.clear();
  }

  void _activateDiagnosisField() {
    setState(() {
      activeField = 'diagnosis';
      editingRowIndex = null;
      _showSuggestions = false;
    });
    _removeMedicineOverlay();
    _removePatientOverlay();
    _removeSymptomOverlay();
    _diagnosisQuery = '';
    _showDiagnosisOverlay();
    _keyboardController.clear();
  }

  void _deleteMedicine(int index) {
    setState(() {
      medicines.removeAt(index);
      for (int i = 0; i < medicines.length; i++) medicines[i].sr = '${i + 1}';
      _medicineLayerLinks.remove(index);
    });
    _removeMedicineOverlay();
  }

  void _clearAll() {
    _clearPatient();
    setState(() {
      medicines.clear();
      _selectedSymptoms.clear();
      _selectedDiagnosis.clear();
      activeField = 'medicine';
      selectedColumn = 'name';
      editingRowIndex = null;
      _medicineLayerLinks.clear();
    });
    _removeMedicineOverlay();
    _removeSymptomOverlay();
    _removeDiagnosisOverlay();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Save / Cancel
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _savePrescription() async {
    if (medicines.isEmpty) {
      _showSnack('⚠️ No medicines to save', Colors.orange);
      return;
    }
    if (patientUhid.isEmpty) {
      _showSnack('⚠️ Please select a patient first', Colors.orange);
      return;
    }
    setState(() => _isSaving = true);
    try {
      final headers = await _headers();
      final medicinesList = medicines.map((m) => {
        "medicine_name": m.name,
        "frequency": _doseToFrequency(m.dose),
        "meal_timing": m.meal,
        "duration_days": _durationToDays(m.duration),
        "duration": "${_durationToDays(m.duration)} Days",
      }).toList();

      final requestBody = {
        "patient_code": patientCode,
        "appointment_code": "",
        "doctor_code": "DOC001",
        "prescription_date": DateTime.now().toIso8601String().substring(0, 10),
        "medicines": medicinesList,
        if (_selectedSymptoms.isNotEmpty)
          "symptoms": _selectedSymptoms.map((s) => s.name).toList(),
        if (_selectedDiagnosis.isNotEmpty)
          "diagnosis": _selectedDiagnosis.map((d) => d.name).toList(),
      };

      final response = await http.post(
        Uri.parse('https://hms.yourhrms.in/api/prescriptions/create/'),
        headers: headers,
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        _showSnack(
          '✅ Prescription saved (${medicines.length} medicine${medicines.length > 1 ? 's' : ''})',
          Colors.green,
        );
      } else {
        String errorMessage = 'Save failed';
        try {
          final errorData = jsonDecode(response.body);
          errorMessage = errorData['detail'] ?? errorData['message'] ?? errorData['error'] ?? 'Save failed (${response.statusCode})';
        } catch (_) {
          errorMessage = 'Save failed (${response.statusCode})';
        }
        _showSnack('❌ $errorMessage', Colors.red);
      }
    } catch (e) {
      _showSnack('❌ Network error: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _cancelPrescription() {
    _clearAll();
    _showSnack('🚫 Prescription cancelled', Colors.grey);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFF2F2F2),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: const Color(0xFFF2F2F2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(height: 1, thickness: 1, color: Colors.black12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    const Text('℞', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black, height: 1.1)),
                    const Spacer(),
                    SizedBox(
                      width: 100, height: 40,
                      child: ElevatedButton(
                        onPressed: (medicines.isNotEmpty && patientUhid.isNotEmpty && !_isSaving)
                            ? _savePrescription
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          disabledForegroundColor: Colors.grey.shade500,
                          elevation: 2,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: _isSaving
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Save', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 100, height: 40,
                      child: ElevatedButton(
                        onPressed: _cancelPrescription,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text('Cancel', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
              _buildDrawArea(),
            ],
          ),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(),
                      _buildPatientInfo(),
                      _buildTableHeader(),
                      _buildMedicineList(),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Header
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: _loadingDoctor
                ? const SizedBox(height: 40, child: Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator(strokeWidth: 2)))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(doctorData?.fullName ?? 'Doctor',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(doctorData?.qualifications ?? '',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Patient info  (now includes Symptoms & Diagnosis below DOB)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPatientInfo() {
    final isNameActive = activeField == 'name';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Name search ──────────────────────────────────────────────────
          CompositedTransformTarget(
            link: _patientLayerLink,
            child: GestureDetector(
              onTap: _activateNameField,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: isNameActive ? Colors.teal : Colors.black38, width: isNameActive ? 2.0 : 1.0),
                  borderRadius: BorderRadius.circular(6),
                  color: Colors.white,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _searchQuery.isNotEmpty ? _searchQuery : patientName.isNotEmpty ? patientName : 'Patient Name / UHID / Mobile',
                        style: TextStyle(fontSize: 14, color: (_searchQuery.isEmpty && patientName.isEmpty) ? Colors.black38 : Colors.black87),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (patientUhid.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(4)),
                        child: Text(patientUhid, style: const TextStyle(fontSize: 10, color: Colors.blue)),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(onTap: _clearPatient, child: const Icon(Icons.close, size: 16, color: Colors.black45)),
                    ] else
                      GestureDetector(
                        onTap: isNameActive ? _clearPatient : _activateNameField,
                        child: Icon(isNameActive ? Icons.close : Icons.person_search, size: 20, color: isNameActive ? Colors.red : Colors.grey),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // ── Age / Gender / DOB ───────────────────────────────────────────
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _patientField('Age', patientAge, 'age'),
              _patientField('Gender', patientGender, 'gender'),
              _patientField('DOB', date, 'date'),
            ],
          ),
          const SizedBox(height: 10),

          // ── Symptoms ─────────────────────────────────────────────────────
          _buildTagSection(
            label: 'Symptoms',
            icon: Icons.sick_outlined,
            accentColor: Colors.orange.shade700,
            isActive: activeField == 'symptom',
            tags: _selectedSymptoms.map((s) => s.name).toList(),
            layerLink: _symptomLayerLink,
            onActivate: _activateSymptomField,
            onRemove: (i) => setState(() => _selectedSymptoms.removeAt(i)),
            isSaving: _isSavingSymptom,
          ),
          const SizedBox(height: 8),

          // ── Diagnosis ────────────────────────────────────────────────────
          _buildTagSection(
            label: 'Diagnosis',
            icon: Icons.local_hospital_outlined,
            accentColor: Colors.purple.shade600,
            isActive: activeField == 'diagnosis',
            tags: _selectedDiagnosis.map((d) => d.name).toList(),
            layerLink: _diagnosisLayerLink,
            onActivate: _activateDiagnosisField,
            onRemove: (i) => setState(() => _selectedDiagnosis.removeAt(i)),
            isSaving: _isSavingDiagnosis,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Reusable tag section (Symptoms / Diagnosis)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildTagSection({
    required String label,
    required IconData icon,
    required Color accentColor,
    required bool isActive,
    required List<String> tags,
    required LayerLink layerLink,
    required VoidCallback onActivate,
    required void Function(int) onRemove,
    required bool isSaving,
  }) {
    return CompositedTransformTarget(
      link: layerLink,
      child: GestureDetector(
        onTap: onActivate,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: isActive ? accentColor : Colors.black26, width: isActive ? 2 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Label row
              Row(
                children: [
                  Icon(icon, size: 13, color: accentColor),
                  const SizedBox(width: 4),
                  Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: accentColor)),
                  const Spacer(),
                  if (isSaving)
                    SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: accentColor))
                  else
                    Icon(Icons.add, size: 16, color: accentColor),
                ],
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 6),
                // Chip wrap
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: List.generate(tags.length, (i) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.10),
                        border: Border.all(color: accentColor.withOpacity(0.35)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(tags[i], style: TextStyle(fontSize: 11, color: accentColor, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => onRemove(i),
                            child: Icon(Icons.close, size: 12, color: accentColor),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Tap to add $label...',
                    style: TextStyle(fontSize: 12, color: Colors.black38),
                  ),
                ),
            ],
          ),
        ),
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
          color: active ? Colors.blue : Colors.black87,
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Table header
  // ─────────────────────────────────────────────────────────────────────────

  static const double _wSr       = 32;
  static const double _wDose     = 72;
  static const double _wMeal     = 80;
  static const double _wDuration = 70;
  static const double _wDelete   = 36;

  Widget _buildTableHeader() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.blue.shade100,
      child: Row(
        children: [
          const SizedBox(
            width: _wSr,
            child: Padding(padding: EdgeInsets.all(8), child: Text('Sr', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
          ),
          Expanded(child: _headerCell('Medicine', 'name')),
          SizedBox(width: _wDose,     child: _headerCell('Dose',     'dose')),
          SizedBox(width: _wMeal,     child: _headerCell('Meal',     'meal')),
          SizedBox(width: _wDuration, child: _headerCell('Duration', 'duration')),
          const SizedBox(width: _wDelete),
        ],
      ),
    );
  }

  Widget _headerCell(String text, String col) {
    final selected = activeField == 'medicine' && selectedColumn == col;
    return GestureDetector(
      onTap: () => _selectColumn(col),
      child: Container(
        padding: const EdgeInsets.all(8),
        color: selected ? Colors.blue.shade200 : null,
        child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: selected ? Colors.blue.shade800 : Colors.black87)),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Medicine list
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildMedicineList() {
    if (medicines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('No medicines added yet.', style: TextStyle(color: Colors.black38))),
      );
    }
    return Column(children: List.generate(medicines.length, _buildRow));
  }

  Widget _buildRow(int index) {
    final item = medicines[index];
    final selected = editingRowIndex == index;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? Colors.blue.shade50 : Colors.white,
        border: Border.all(color: selected ? Colors.blue : Colors.black12),
        borderRadius: BorderRadius.circular(2),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 32,
              child: Align(alignment: Alignment.topCenter, child: Padding(padding: const EdgeInsets.all(8), child: Text(item.sr, style: const TextStyle(fontSize: 12)))),
            ),
            Expanded(
              child: CompositedTransformTarget(
                link: _getMedicineLinkForRow(index),
                child: GestureDetector(
                  onTap: () => _selectCell(index, 'name'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            item.name.isEmpty ? '—' : item.name,
                            style: TextStyle(fontSize: 12, color: item.name.isEmpty ? Colors.black38 : Colors.black87),
                            softWrap: true,
                            overflow: TextOverflow.visible,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (_activeMedicineRow == index) {
                              _removeMedicineOverlay();
                            } else {
                              _selectCell(index, 'name');
                            }
                          },
                          child: Icon(_activeMedicineRow == index ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 16, color: Colors.teal),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: _wDose,
              child: GestureDetector(
                onTap: () => _selectCell(index, 'dose'),
                child: _buildDropdownCell(item.dose, _doseOptions, '—', (val) => setState(() => medicines[index].dose = val)),
              ),
            ),
            SizedBox(
              width: _wMeal,
              child: GestureDetector(
                onTap: () => _selectCell(index, 'meal'),
                child: _buildDropdownCell(item.meal, _mealOptions, '—', (val) => setState(() => medicines[index].meal = val)),
              ),
            ),
            SizedBox(
              width: _wDuration,
              child: GestureDetector(
                onTap: () => _selectCell(index, 'duration'),
                child: _buildDropdownCell(item.duration, _durationOptions, '—', (val) => setState(() => medicines[index].duration = val)),
              ),
            ),
            SizedBox(
              width: _wDelete,
              child: Align(
                alignment: Alignment.topCenter,
                child: IconButton(
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => _deleteMedicine(index),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Draw area
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDrawArea() {
    final isName = activeField == 'name';
    final borderColor = isName
        ? Colors.teal
        : activeField == 'symptom'
            ? Colors.orange.shade700
            : activeField == 'diagnosis'
                ? Colors.purple.shade600
                : activeField == 'medicine'
                    ? Colors.blue
                    : Colors.purple;

    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Column(
      mainAxisSize: MainAxisSize.min,
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
                  style: TextStyle(fontSize: 11, color: borderColor, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: _isListening ? _stopListening : _startListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _isListening ? Colors.red : Colors.blue,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: _isListening
                        ? [BoxShadow(color: Colors.red.withOpacity(0.4), blurRadius: 8, spreadRadius: 2)]
                        : [],
                  ),
                  child: Icon(_isListening ? Icons.mic : Icons.mic_none, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 180,
          margin: EdgeInsets.only(left: 10, right: 10, bottom: bottomPadding + 8),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                ClipRect(child: Scribble(notifier: _notifier, drawPen: true)),
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: TextField(
                    controller: _keyboardController,
                    decoration: InputDecoration(
                      hintText: _activeFieldHint(),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.9),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send, size: 18),
                        onPressed: () {
                          final val = _keyboardController.text.trim();
                          if (val.isEmpty) return;
                          _assignText(val);
                          _keyboardController.clear();
                          FocusScope.of(context).unfocus();
                        },
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (val) {
                      if (val.trim().isEmpty) return;
                      _assignText(val.trim());
                      _keyboardController.clear();
                    },
                  ),
                ),
                if (_isRecognizing || _isListening)
                  Container(
                    color: Colors.white60,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isRecognizing) const CircularProgressIndicator(),
                          if (_isListening) ...[
                            const Icon(Icons.mic, color: Colors.red, size: 40),
                            const SizedBox(height: 8),
                            Text(
                              _spokenText.isEmpty ? 'Listening...' : _spokenText,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            Text(_activeFieldHint(), style: const TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Label helpers  (extended for symptom / diagnosis)
  // ─────────────────────────────────────────────────────────────────────────

  String _activeFieldHint() {
    switch (activeField) {
      case 'name':       return 'Say patient name, UHID, or mobile number';
      case 'age':        return 'Say the patient\'s age (e.g. "25")';
      case 'gender':     return 'Say "Male" or "Female"';
      case 'date':       return 'Say date of birth (e.g. "12 March 1990")';
      case 'symptom':    return 'Say symptom (e.g. "Fever", "Cough")';
      case 'diagnosis':  return 'Say diagnosis (e.g. "Viral Fever", "UTI")';
      case 'medicine':
        switch (selectedColumn) {
          case 'dose':     return 'Say dose (e.g. "OD", "BD", "1-1-1")';
          case 'meal':     return 'Say "Before meal", "After meal", or "With meal"';
          case 'duration': return 'Say duration (e.g. "5 days", "2 weeks")';
          default:         return 'Say medicine name';
        }
      default: return '';
    }
  }

  String _activeFieldLabel() {
    switch (activeField) {
      case 'name':
        return _searchQuery.isEmpty ? '✍️  Write patient name / UHID / mobile' : '✍️  Searching for "$_searchQuery" …';
      case 'age':       return '✍️  Writing → Age';
      case 'gender':    return '✍️  Writing → Gender';
      case 'date':      return '✍️  Writing → DOB';
      case 'symptom':   return '✍️  Writing → Symptom';
      case 'diagnosis': return '✍️  Writing → Diagnosis';
      case 'medicine':
        final col = switch (selectedColumn) {
          'name'     => 'Medicine Name',
          'dose'     => 'Dose',
          'meal'     => 'Meal Timing',
          'duration' => 'Duration',
          _          => selectedColumn,
        };
        return editingRowIndex != null
            ? '✍️  Editing row ${editingRowIndex! + 1} → $col'
            : '✍️  Writing → $col';
      default: return '';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Reusable cell widgets
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildDropdownCell(String value, List<String> options, String placeholder, void Function(String) onSelected) {
    return PopupMenuButton<String>(
      onSelected: onSelected,
      constraints: const BoxConstraints(maxHeight: 200, minWidth: 140),
      itemBuilder: (_) => options.map((o) => PopupMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 12)))).toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value.isEmpty ? placeholder : value,
                style: TextStyle(fontSize: 12, color: value.isEmpty ? Colors.black38 : Colors.black87),
                softWrap: true,
                overflow: TextOverflow.visible,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: Colors.black45),
          ],
        ),
      ),
    );
  }
}