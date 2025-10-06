import 'dart:async';
import 'dart:convert';
import 'dart:html' as html; // Web-only: CSV, localStorage, file picker, webhook
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ============================
// QUICK CONFIG (SMS placeholders)
// ============================
const String smsWebhookUrl = '';     // your Cloud Function/Server that calls Twilio (optional)
const String smsApiKey = '';         // optional header

const String defaultAdminPin = '202020';
const String defaultRaffleTitle = 'Gala Fresh Farms Raffle'; ///titulo de la app
const String defaultConsentText =
    'By signing up for Weekly Deals texts from Gala Fresh Farms, you agree to receive promotional marketing text messages such as Weekly Deals sent to your number via autodialer. Consent is not a condition of any purchase. Message frequency varies. Unsubscribe at any time by replying STOP. Message & data rates may apply. Terms and Privacy Policy at ShopGalaFresh.com';
const bool kShowSplashGuides = true; // pon true para ver guías


void main() {
  runApp(const RaffleApp());
}

class RaffleApp extends StatelessWidget {
  const RaffleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gala Fresh Farms Raffle',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const RootPage(),
    );
  }
}

class Customer {
  final String firstName;
  final String lastName;
  final String email; // optional
  final String mobile; // digits only
  final String address;
  final String city;
  final String state;
  final String zipCode;
  final bool consentYes;
  final bool consentPrivacy;
  final String ticket;
  final DateTime createdAt;
  bool alreadyWon;

  Customer({
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.mobile,
    required this.address,
    required this.city,
    required this.state,
    required this.zipCode,
    required this.consentYes,
    required this.consentPrivacy,
    required this.ticket,
    required this.createdAt,
    this.alreadyWon = false,
  });
}

enum RaffleState { registrationOpen, registrationClosed, drawingInProgress, drawingFinished }

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  // Data
  final List<Customer> _customers = [];
  final List<Customer> _participantsSnapshot = []; // frozen when drawing starts
  final List<Customer> _winners = [];
  int _sequence = 1;
  final Random _rng = Random();

  // Raffle state
  RaffleState _state = RaffleState.registrationOpen;
  DateTime _raffleDate = DateTime.now().add(const Duration(days: 7));
  DateTime? _closedAt;
  DateTime? _startedAt;
  DateTime? _finishedAt;
  bool _raffleExported = false;

  // UI & settings
  int _currentIndex = 3; // 0 = Registration, 1 = Admin, 2 = Live, 3 = Splash
  bool _csvCooldown = false;
  Customer? _lastPublicWinner;

  // Editable settings (persisted)
  String _adminPin = defaultAdminPin;
  String _raffleTitle = defaultRaffleTitle;
  String _consentText = defaultConsentText;

  // Splash image (data URL)
  String? _splashImageDataUrl;

  @override
  void initState() {
    super.initState();
    _loadPersistedSettings();
  }

  void _loadPersistedSettings() {
    final ls = html.window.localStorage;
    final p = ls['admin_pin'];
    final t = ls['raffle_title'];
    final c = ls['consent_text'];
    final s = ls['splash_image'];
    if (p != null && p.isNotEmpty) _adminPin = p;
    if (t != null && t.isNotEmpty) _raffleTitle = t;
    if (c != null && c.isNotEmpty) _consentText = c;
    if (s != null && s.isNotEmpty) _splashImageDataUrl = s;
  }

  Future<void> _updateSettingsWithPin(BuildContext ctx,
      {String? newTitle, String? newPin, String? newConsentText}) async {
    final ok = await _askPin();
    if (!ok) return;
    setState(() {
      if (newTitle != null && newTitle.trim().isNotEmpty) {
        _raffleTitle = newTitle.trim();
        html.window.localStorage['raffle_title'] = _raffleTitle;
      }
      if (newPin != null && newPin.trim().isNotEmpty) {
        _adminPin = newPin.trim();
        html.window.localStorage['admin_pin'] = _adminPin;
      }
      if (newConsentText != null && newConsentText.trim().isNotEmpty) {
        _consentText = newConsentText.trim();
        html.window.localStorage['consent_text'] = _consentText;
      }
    });
    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  // ============================
  // Splash helpers
  // ============================
  Future<void> _changeSplashImageWithPin() async {
    final ok = await _askPin();
    if (!ok) return;

    final input = html.FileUploadInputElement()..accept = 'image/*';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null) return;

    final reader = html.FileReader();
    final completer = Completer<String>();
    reader.onLoad.listen((_) => completer.complete(reader.result as String));
    reader.readAsDataUrl(file);
    final dataUrl = await completer.future;

    setState(() {
      _splashImageDataUrl = dataUrl;
      html.window.localStorage['splash_image'] = dataUrl;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Splash image updated')));
    }
  }

  Future<void> _showSplashFromAdmin() async {
    final leave = await _confirmLeaveAdmin();
    if (!leave) return;
    setState(() => _currentIndex = 3);
  }

  // ============================
  // HELPERS
  // ============================
  String _digitsOnly(String v) => v.replaceAll(RegExp(r'[^0-9]'), '');
  bool _isDuplicateMobile(String mobile) {
    final d = _digitsOnly(mobile);
    return _customers.any((c) => _digitsOnly(c.mobile) == d);
  }

  /// Only letters, numbers and spaces for plain text fields
  bool _hasInvalidPlainText(List<String> fields) {
    final allowed = RegExp(r'^[a-zA-Z0-9\s]*$');
    for (final f in fields) {
      if (!allowed.hasMatch(f)) return true;
    }
    return false;
  }

  /// Email allowed, but block obvious XSS payloads
  bool _hasSuspiciousEmail(String email) {
    if (email.trim().isEmpty) return false;
    final bad = RegExp(r'(<|>|script|onerror|onload|javascript:|data:text/html)', caseSensitive: false);
    return bad.hasMatch(email);
  }

  String _newTicket() => 'T-${_sequence.toString().padLeft(4, '0')}';

  // ============================
  // REGISTRATION
  // ============================
  Future<bool> _registerCustomer({
    required String firstName,
    required String lastName,
    required String email,
    required String mobile,
    required String address,
    required String city,
    required String state,
    required String zipCode,
    required bool consentYes,
    required bool consentPrivacy,
  }) async {
    if (_state != RaffleState.registrationOpen) return false;

    // block duplicates by mobile digits
    if (_isDuplicateMobile(mobile)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This mobile number is already registered.')),
      );
      return false;
    }

    // gentle validation: plain text only (letters/numbers/spaces)
    if (_hasInvalidPlainText([firstName, lastName, address, city, state, zipCode])) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please use only letters and numbers.')),
      );
      return false;
    }

    // email protected against XSS
    if (_hasSuspiciousEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email (no special code).')),
      );
      return false;
    }

    final digits = _digitsOnly(mobile);
    final looksInvalid = digits.length < 10; // warn but DO NOT block

    final c = Customer(
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      email: email.trim(),
      mobile: digits, // store digits-only
      address: address.trim(),
      city: city.trim(),
      state: state.trim(),
      zipCode: zipCode.trim(),
      consentYes: consentYes,
      consentPrivacy: consentPrivacy,
      ticket: _newTicket(),
      createdAt: DateTime.now(),
    );

    setState(() {
      _customers.add(c);
      _sequence++;
    });

    if (looksInvalid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ The mobile phone seems short. Registered anyway.')),
      );
    }

    await _sendSmsConfirmation(c); // no-op if smsWebhookUrl is empty
    return true;
  }

  Future<void> _sendSmsConfirmation(Customer c) async {
    if (smsWebhookUrl.isEmpty) return; // no SMS until configured

    final date = _formatDate(_raffleDate);
    final time = _formatTime(_raffleDate);

    final body = 'Thanks ${c.firstName}! You are participating in the supermarket raffle. '
        'Your participant number is ${c.ticket}. The raffle will be on $date at $time.';

    try {
      await html.HttpRequest.request(
        smsWebhookUrl,
        method: 'POST',
        requestHeaders: {
          'Content-Type': 'application/json',
          if (smsApiKey.isNotEmpty) 'X-API-KEY': smsApiKey,
        },
        sendData: jsonEncode({'to': c.mobile, 'message': body}),
      );
    } catch (_) {/* ignore network issues in prototype */}
  }

  // ============================
  // ADMIN: STATES & DRAWING
  // ============================
  void _closeRegistration() {
    if (_state != RaffleState.registrationOpen) return;
    setState(() {
      _state = RaffleState.registrationClosed;
      _closedAt = DateTime.now();
    });
  }

  void _openRegistration() {
    if (_state == RaffleState.drawingInProgress || _state == RaffleState.drawingFinished) return;
    setState(() {
      _state = RaffleState.registrationOpen;
      _closedAt = null;
    });
  }

  void _startDrawing() {
    if (_state != RaffleState.registrationClosed) return;
    setState(() {
      _participantsSnapshot
        ..clear()
        ..addAll(_customers);
      _winners.clear();
      for (final c in _customers) {
        c.alreadyWon = false;
      }
      _state = RaffleState.drawingInProgress;
      _startedAt = DateTime.now();
      _finishedAt = null;
      _raffleExported = false;
      _lastPublicWinner = null;
    });
  }

  Customer? _drawWinner() {
    if (_state != RaffleState.drawingInProgress) return null;

    final remaining = _participantsSnapshot.where((c) => !c.alreadyWon).toList();
    if (remaining.isEmpty) {
      setState(() => _state = RaffleState.drawingFinished);
      return null;
    }

    final idx = _rng.nextInt(remaining.length);
    final winner = remaining[idx];
    setState(() {
      winner.alreadyWon = true; // avoid duplicates
      _winners.add(winner);
      _lastPublicWinner = winner; // remember for Live screen
    });
    return winner;
  }

  void _finishRaffle(BuildContext ctx) {
    if (!(_state == RaffleState.drawingInProgress || _state == RaffleState.drawingFinished)) return;
    setState(() {
      _state = RaffleState.drawingFinished;
      _finishedAt = DateTime.now();
      _lastPublicWinner = null; // hide last winner after finishing
    });
    _exportFullRaffle(ctx);
  }

  Future<void> _finishRaffleWithPin(BuildContext ctx) async {
    final ok = await _askPin();
    if (!ok) return;
    _finishRaffle(ctx);
  }

  void _newRaffle() {
    setState(() {
      _customers.clear();
      _participantsSnapshot.clear();
      _winners.clear();
      _state = RaffleState.registrationOpen;
      _sequence = 1;
      _closedAt = null;
      _startedAt = null;
      _finishedAt = null;
      _raffleExported = false;
      _csvCooldown = false;
      _lastPublicWinner = null;
    });
  }

  // ============================
  // EXPORTS (CSV)
  // ============================
  String _csvCustomers(List<Customer> list) {
    final sb = StringBuffer(
        '''ticket,first_name,last_name,email,mobile,address,city,state,zip,consent_yes,consent_privacy,created\n''');
    for (final c in list) {
      sb.writeln([
        c.ticket,
        _csvEscape(c.firstName),
        _csvEscape(c.lastName),
        _csvEscape(c.email),
        _csvEscape(c.mobile),
        _csvEscape(c.address),
        _csvEscape(c.city),
        _csvEscape(c.state),
        _csvEscape(c.zipCode),
        c.consentYes ? '1' : '0',
        c.consentPrivacy ? '1' : '0',
        c.createdAt.toIso8601String(),
      ].join(','));
    }
    return sb.toString();
  }

  String _csvRaffleFinal() {
    final base = _participantsSnapshot.isEmpty ? _customers : _participantsSnapshot;
    final sb = StringBuffer(
        '''ticket,first_name,last_name,email,mobile,address,city,state,zip,consent_yes,consent_privacy,created,winner\n''');
    for (final c in base) {
      sb.writeln([
        c.ticket,
        _csvEscape(c.firstName),
        _csvEscape(c.lastName),
        _csvEscape(c.email),
        _csvEscape(c.mobile),
        _csvEscape(c.address),
        _csvEscape(c.city),
        _csvEscape(c.state),
        _csvEscape(c.zipCode),
        c.consentYes ? '1' : '0',
        c.consentPrivacy ? '1' : '0',
        c.createdAt.toIso8601String(),
        c.alreadyWon ? '1' : '0',
      ].join(','));
    }
    return sb.toString();
  }

  String _csvEscape(String v) {
    if (v.isNotEmpty && ('=+-@'.contains(v[0]))) {
      v = "'" + v; // prefix to avoid CSV formula injection
    }
    final hasNewline = v.contains(String.fromCharCode(10));
    if (v.contains(',') || v.contains('"') || hasNewline) {
      return '"' + v.replaceAll('"', '""') + '"';
    }
    return v;
  }

  Future<void> _copyCsvToClipboard(BuildContext context, String csv) async {
    await Clipboard.setData(ClipboardData(text: csv));
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
  }

  void _downloadCsv(String filename, String csv) {
    final bytes = utf8.encode(csv);
    final blob = html.Blob([bytes], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)..download = filename;
    anchor.click();
    html.Url.revokeObjectUrl(url);
  }

  void _exportFullRaffle(BuildContext ctx) {
    final dt = _finishedAt ?? DateTime.now();
    final name = _raffleFileName(dt);
    _downloadCsv(name, _csvRaffleFinal());
    setState(() => _raffleExported = true);
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('CSV downloaded: $name')));
  }

  void _downloadAgainWithCooldown(BuildContext ctx) {
    if (!_raffleExported) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Finish the raffle first to generate the CSV.')));
      return;
    }
    if (_csvCooldown) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Please wait 3 seconds to download again.')));
      return;
    }
    setState(() => _csvCooldown = true);
    final dt = _finishedAt ?? DateTime.now();
    final name = _raffleFileName(dt);
    _downloadCsv(name, _csvRaffleFinal());
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _csvCooldown = false);
    });
  }

  // ============================
  // DATE/TIME UTILS (MM-DD-YYYY)
// ============================
  String _formatDate(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}-${dt.year}';
  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String _fileTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h-$m $ampm';
  }

  String _raffleFileName(DateTime dt) {
    final date = _formatDate(dt);
    final time = _fileTime(dt);
    final raw = 'Raffle $date - $time.csv';
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
  }

  // ============================
  // UI
  // ============================
  @override
  Widget build(BuildContext context) {
    final pages = [
      RegistrationPage(
        state: _state,
        onSubmit: (fn, ln, email, mobile, addr, city, st, zip, cYes, cPriv) => _registerCustomer(
          firstName: fn,
          lastName: ln,
          email: email,
          mobile: mobile,
          address: addr,
          city: city,
          state: st,
          zipCode: zip,
          consentYes: cYes,
          consentPrivacy: cPriv,
        ),
        raffleDate: _raffleDate,
        consentText: _consentText,
      ),
      AdminPage(
        state: _state,
        raffleTitle: _raffleTitle,
        consentText: _consentText,
        splashDataUrl: _splashImageDataUrl,
        customers: _customers,
        participants: _participantsSnapshot,
        winners: _winners,
        raffleDate: _raffleDate,
        raffleExported: _raffleExported,
        csvCooldown: _csvCooldown,
        onOpenRegistration: _openRegistration,
        onCloseRegistration: _closeRegistration,
        onStartDrawing: _startDrawing,
        onDraw: _drawWinner,
        onFinishRaffle: () => _finishRaffleWithPin(context),
        onConfirmReset: (ctx) => _confirmResetAndDownload(ctx),
        onExportParticipants: (ctx) => _copyCsvToClipboard(
            ctx, _csvCustomers(_participantsSnapshot.isEmpty ? _customers : _participantsSnapshot)),
        onExportWinners: (ctx) => _copyCsvToClipboard(ctx, _csvCustomers(_winners)),
        onDownloadRaffleCsv: (ctx) => _downloadAgainWithCooldown(ctx),
        onChangeDate: (dt) => setState(() => _raffleDate = dt),
        onSaveSettings: (ctx, title, pin, consent) =>
            _updateSettingsWithPin(ctx, newTitle: title, newPin: pin, newConsentText: consent),
        onChangeSplashImage: _changeSplashImageWithPin,
        onShowSplash: _showSplashFromAdmin,
      ),
      LiveDrawPage(
        state: _state,
        title: _raffleTitle,
        winner: _lastPublicWinner,
        winners: _winners,
        onDraw: _drawWinner,
        onFinishRaffle: () => _finishRaffleWithPin(context),
      ),
      SplashPage(
        title: _raffleTitle,
        dataUrl: _splashImageDataUrl,
        onTapAnywhere: () => setState(() => _currentIndex = 0),
      ),
    ];

    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _currentIndex, children: pages)),
      bottomNavigationBar: _currentIndex == 3
          ? null
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) async {
                if (i == _currentIndex) return;

                // Navigation rules:
                // - Leaving Registration -> PIN
                // - Leaving Admin -> confirm only
                // - Leaving Live -> PIN
                final from = _currentIndex;
                final to = i;

                if (from == 0 && to != 0) {
                  final ok = await _askPin();
                  if (ok) setState(() => _currentIndex = to);
                  return;
                }

                if (from == 1 && to != 1) {
                  final leave = await _confirmLeaveAdmin();
                  if (leave) setState(() => _currentIndex = to);
                  return;
                }

                if (from == 2 && to != 2) {
                  final ok = await _askPin();
                  if (ok) setState(() => _currentIndex = to);
                  return;
                }

                setState(() => _currentIndex = to);
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.app_registration_outlined), label: 'Registration'),
                NavigationDestination(icon: Icon(Icons.settings_suggest_outlined), label: 'Admin'),
                NavigationDestination(icon: Icon(Icons.live_tv_outlined), label: 'Live'),
              ],
            ),
    );
  }

  Future<bool> _askPin() async {
    final pinCtrl = TextEditingController();
    bool ok = false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Admin access'),
        content: TextField(
          controller: pinCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'PIN',
            hintText: 'Enter PIN',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (pinCtrl.text.trim() == _adminPin) {
                ok = true;
                Navigator.pop(context);
              }
            },
            child: const Text('Enter'),
          ),
        ],
      ),
    );
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Incorrect PIN')));
    }
    pinCtrl.dispose();
    return ok;
  }

  Future<bool> _confirmLeaveAdmin() async {
    bool ok = false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Leave Admin'),
        content: const Text(
            'Are you sure you want to leave the admin area? You will need to enter the PIN again to come back.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () { ok = true; Navigator.pop(context); }, child: const Text('Yes, leave')),
        ],
      ),
    );
    return ok;
  }

  void _confirmResetAndDownload(BuildContext ctx) async {
    bool ok = false;
    await showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('New raffle'),
        content: const Text(
            'Are you sure you want to reset everything? The current raffle CSV will be downloaded again before resetting.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () { ok = true; Navigator.pop(ctx); }, child: const Text('Yes, reset')),
        ],
      ),
    );
    if (!ok) return;
    _downloadAgainWithCooldown(ctx);
    _newRaffle();
  }
}

// ============================
// SPLASH PAGE
// ============================
class SplashPage extends StatelessWidget {
  final String title;
  final String? dataUrl; // data:image/...;base64,...
  final VoidCallback onTapAnywhere;

  const SplashPage({
    super.key,
    required this.title,
    required this.dataUrl,
    required this.onTapAnywhere,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTapAnywhere,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
    if (dataUrl != null && dataUrl!.isNotEmpty)
      Image.network(dataUrl!, fit: BoxFit.fill)
    else
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _BrandLogo(fontSize: 72), // <--- LOGO GRANDE
          const SizedBox(height: 12),
          Text(
            title, // “RaffleFast Raffle” (editable desde Admin)
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black38, offset: Offset(0,1), blurRadius: 3)],
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Tap anywhere to start',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
            Positioned(
              bottom: 28,
              right: 28,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Tap anywhere to continue', style: TextStyle(color: Colors.white)),
              ),
            ),
                    if (kShowSplashGuides)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _GuidesPainter()),
              ),
            ),
            
            ],






        ),
      ),
    );
  }
}



class _GuidesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pOuter = Paint()
      ..color = const Color(0x99FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Borde exterior
    canvas.drawRect(Offset.zero & size, pOuter);

    // Zona segura (8% de margen en el lado más corto)
    final margin = size.shortestSide * 0.08;
    final safe = Rect.fromLTWH(margin, margin, size.width - 2 * margin, size.height - 2 * margin);
    final pSafe = Paint()
      ..color = const Color(0xCCFFC107) // ámbar
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(safe, pSafe);

    // Regla de tercios
    final pGrid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    for (int i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), pGrid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), pGrid);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


class _BrandLogo extends StatelessWidget {
  final double fontSize;
  const _BrandLogo({super.key, this.fontSize = 64});

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.0,
      shadows: const [
        Shadow(color: Colors.black26, offset: Offset(0, 2), blurRadius: 6),
      ],
    );
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: baseStyle,
        children: const [
          TextSpan(text: 'Raffle', style: TextStyle(color: Color(0xFF34a853))), // verde Google-ish
          TextSpan(text: 'Fast',  style: TextStyle(color: Color(0xFF0f9d58))),
        ],
      ),
    );
  }
}






// ============================
// LIVE DRAW PAGE (public display)
// ============================
class LiveDrawPage extends StatefulWidget {
  final RaffleState state;
  final String title;
  final Customer? winner;                // last shown winner
  final List<Customer> winners;          // all winners (for public list)
  final Customer? Function() onDraw;
  final VoidCallback onFinishRaffle;

  const LiveDrawPage({
    super.key,
    required this.state,
    required this.title,
    required this.winner,
    required this.winners,
    required this.onDraw,
    required this.onFinishRaffle,
  });

  @override
  State<LiveDrawPage> createState() => _LiveDrawPageState();
}

class _LiveDrawPageState extends State<LiveDrawPage> {
  bool _rolling = false;
  String _rollText = '';
  final Random _rng = Random();

  Future<void> _handleDraw() async {
    if (widget.state != RaffleState.drawingInProgress) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Start the drawing in Admin first.')));
      return;
    }
    setState(() { _rolling = true; _rollText = _fakeTicket(); });
    final start = DateTime.now();
    while (DateTime.now().difference(start).inMilliseconds < 1200) {
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      setState(() { _rollText = _fakeTicket(); });
    }
    widget.onDraw(); // Root updates last winner; Live rebuilds via parent
    if (!mounted) return;
    setState(() { _rolling = false; });
  }

  String _fakeTicket() => 'T-${(_rng.nextInt(9999) + 1).toString().padLeft(4, '0')}';

  Future<void> _showWinnersDialog() async {
    await showDialog(
      context: context,
      builder: (_) {
        final items = widget.winners;
        return AlertDialog(
          title: const Text('Winners'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: items.isEmpty
                ? const Center(child: Text('No winners yet'))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = items[i];
                      return ListTile(
                        leading: const Icon(Icons.stars_outlined),
                        title: Text(c.firstName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Ticket: ${c.ticket}'),
                        trailing: Text('#${i + 1}'),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canDraw = widget.state == RaffleState.drawingInProgress;
    final canFinish = widget.state == RaffleState.drawingInProgress || widget.state == RaffleState.drawingFinished;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF0f9d58), Color(0xFF34a853)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 12),
          Text(_statusText(widget.state), style: const TextStyle(fontSize: 18, color: Colors.white70)),
          const SizedBox(height: 28),
          Container(
            constraints: const BoxConstraints(maxWidth: 900),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)]),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
              child: _rolling
                  ? Column(key: const ValueKey('rolling'), children: [
                      const Text('Drawing...', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_rollText, style: const TextStyle(fontSize: 60, letterSpacing: 2)),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ])
                  : (widget.winner == null)
                      ? const Text('Press "Draw Winner" to begin', key: ValueKey('idle'), style: TextStyle(fontSize: 26))
                      : _WinnerBanner(key: ValueKey('winner-${_WinnerBanner.idSeed}'), winner: widget.winner!),
            ),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: canDraw ? _handleDraw : null,
                icon: const Icon(Icons.casino_outlined, size: 28),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('Draw Winner', style: TextStyle(fontSize: 18)),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: canFinish ? widget.onFinishRaffle : null,
                icon: const Icon(Icons.flag_outlined, size: 28),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('Finish Raffle (download CSV)', style: TextStyle(fontSize: 18)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _showWinnersDialog,
                icon: const Icon(Icons.emoji_events_outlined, size: 24),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('Show Winners'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusText(RaffleState s) {
    switch (s) {
      case RaffleState.registrationOpen:
        return 'Registration open';
      case RaffleState.registrationClosed:
        return 'Registration closed — ready to start drawing in Admin';
      case RaffleState.drawingInProgress:
        return 'Drawing in progress';
      case RaffleState.drawingFinished:
        return 'Drawing finished';
    }
  }
}

class _WinnerBanner extends StatelessWidget {
  static int idSeed = 0; // helps AnimatedSwitcher uniqueness
  final Customer winner;
  _WinnerBanner({super.key, required this.winner}) {
    idSeed++; // change key seed on each build of a different winner
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('🎉 WINNER 🎉', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(winner.ticket, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900, letterSpacing: 2)),
        const SizedBox(height: 8),
        Text(winner.firstName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ============================
// REGISTRATION PAGE
// ============================
class RegistrationPage extends StatefulWidget {
  final RaffleState state;
  final Future<bool> Function(
    String firstName,
    String lastName,
    String email,
    String mobile,
    String address,
    String city,
    String state,
    String zip,
    bool consentYes,
    bool consentPrivacy,
  ) onSubmit;
  final DateTime raffleDate;
  final String consentText;

  const RegistrationPage({
    super.key,
    required this.state,
    required this.onSubmit,
    required this.raffleDate,
    required this.consentText,
  });

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

class _RegistrationPageState extends State<RegistrationPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _mobile = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();

  bool _consentYes = true;
  bool _consentPrivacy = true;
  bool _consentError = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _mobile.dispose();
    _address.dispose();
    _city.dispose();
    _state.dispose();
    _zip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.state == RaffleState.registrationOpen;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.app_registration_outlined),
                      const SizedBox(width: 8),
                      Text(
                        open ? 'Participant registration' : 'Registration is closed',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'The raffle will take place on ${_date(widget.raffleDate)} at ${_time(widget.raffleDate)}.',
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                  const Divider(height: 24),
                  Form(
                    key: _formKey,
                    child: AbsorbPointer(
                      absorbing: !open,
                      child: Opacity(
                        opacity: open ? 1 : 0.6,
                        child: Column(
                          children: [
                            Row(children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _firstName,
                                  decoration: const InputDecoration(labelText: 'First Name *', border: OutlineInputBorder()),
                                  validator: _req,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _lastName,
                                  decoration: const InputDecoration(labelText: 'Last Name *', border: OutlineInputBorder()),
                                  validator: _req,
                                ),
                              ),
                            ]),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _email,
                                  decoration: const InputDecoration(labelText: 'Email Address', hintText: 'name@example.com', border: OutlineInputBorder()),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _mobile,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: const InputDecoration(labelText: 'Mobile Phone *', hintText: '5551234567', border: OutlineInputBorder()),
                                  validator: _req,
                                ),
                              ),
                            ]),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _address,
                              decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: _city,
                                  decoration: const InputDecoration(labelText: 'City', border: OutlineInputBorder()),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _state,
                                  decoration: const InputDecoration(labelText: 'State', hintText: 'NY', border: OutlineInputBorder()),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _zip,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: const InputDecoration(labelText: 'Zip Code *', hintText: '10001', border: OutlineInputBorder()),
                                  validator: _req,
                                ),
                              ),
                            ]),
                            const SizedBox(height: 16),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Would you like to receive promotional material from us?'),
                            ),
                            Row(
                              children: [
                                Checkbox(value: _consentYes, onChanged: (v) => setState(() => _consentYes = v ?? true)),
                                const Text('Yes'),
                                const SizedBox(width: 16),
                                Checkbox(value: _consentPrivacy, onChanged: (v) => setState(() => _consentPrivacy = v ?? true)),
                                const Text('Privacy and Consent'),
                              ],
                            ),
                            if (_consentError)
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: 8.0),
                                  child: Text('Both checkboxes are required.', style: TextStyle(color: Colors.red)),
                                ),
                              ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(widget.consentText),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () async {
                                  if (_formKey.currentState!.validate()) {
                                    final consentOk = _consentYes && _consentPrivacy;
                                    setState(() => _consentError = !consentOk);
                                    if (!consentOk) return;

                                    final ok = await widget.onSubmit(
                                      _firstName.text,
                                      _lastName.text,
                                      _email.text,
                                      _mobile.text,
                                      _address.text,
                                      _city.text,
                                      _state.text,
                                      _zip.text,
                                      _consentYes,
                                      _consentPrivacy,
                                    );
                                    if (ok && mounted) {
                                      _firstName.clear();
                                      _lastName.clear();
                                      _email.clear();
                                      _mobile.clear();
                                      _address.clear();
                                      _city.clear();
                                      _state.clear();
                                      _zip.clear();
                                      _consentYes = true;
                                      _consentPrivacy = true;
                                      _consentError = false;
                                      setState(() {});
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registration submitted')));
                                    }
                                  }
                                },
                                icon: const Icon(Icons.save_outlined),
                                label: const Text('Register'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // >>> MM-DD-YYYY <<<
  String _date(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}-${dt.year}';
  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String? _req(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;
}

// ============================
// ADMIN PAGE
// ============================
class AdminPage extends StatelessWidget {
  final RaffleState state;
  final String raffleTitle;
  final String consentText;
  final String? splashDataUrl;

  final List<Customer> customers;
  final List<Customer> participants;
  final List<Customer> winners;
  final DateTime raffleDate;
  final bool raffleExported;
  final bool csvCooldown;

  final VoidCallback onOpenRegistration;
  final VoidCallback onCloseRegistration;
  final VoidCallback onStartDrawing;
  final Customer? Function() onDraw;
  final VoidCallback onFinishRaffle;
  final void Function(BuildContext) onConfirmReset;
  final void Function(BuildContext) onExportParticipants;
  final void Function(BuildContext) onExportWinners;
  final void Function(BuildContext) onDownloadRaffleCsv;
  final void Function(DateTime) onChangeDate;

  // Settings & Splash
  final Future<void> Function(BuildContext ctx, String? newTitle, String? newPin, String? newConsentText) onSaveSettings;
  final Future<void> Function() onChangeSplashImage;
  final Future<void> Function() onShowSplash;

  const AdminPage({
    super.key,
    required this.state,
    required this.raffleTitle,
    required this.consentText,
    required this.splashDataUrl,
    required this.customers,
    required this.participants,
    required this.winners,
    required this.raffleDate,
    required this.raffleExported,
    required this.csvCooldown,
    required this.onOpenRegistration,
    required this.onCloseRegistration,
    required this.onStartDrawing,
    required this.onDraw,
    required this.onFinishRaffle,
    required this.onConfirmReset,
    required this.onExportParticipants,
    required this.onExportWinners,
    required this.onDownloadRaffleCsv,
    required this.onChangeDate,
    required this.onSaveSettings,
    required this.onChangeSplashImage,
    required this.onShowSplash,
  });

  @override
  Widget build(BuildContext context) {
    final total = customers.length;
    final frozen = participants.isEmpty ? total : participants.length;
    final winnersCount = winners.length;
    final eligible = (participants.isEmpty
        ? customers.where((c) => !c.alreadyWon).length
        : participants.where((c) => !c.alreadyWon).length);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: LayoutBuilder(
        builder: (context, c) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _controlPanel(context, total, frozen, winnersCount, eligible)),
              const SizedBox(width: 16),
              Expanded(child: _lists(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _controlPanel(BuildContext context, int total, int frozen, int winnersCount, int eligible) {
    final canFinish = state == RaffleState.drawingInProgress || state == RaffleState.drawingFinished;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: const [
                Icon(Icons.settings_suggest_outlined),
                SizedBox(width: 8),
                Text('Admin panel', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))
              ]),
              const Divider(height: 24),
              Wrap(spacing: 12, runSpacing: 12, children: [
                Chip(label: Text('Customers: $total')),
                Chip(label: Text('Frozen: $frozen')),
                Chip(label: Text('Winners: $winnersCount')),
                Chip(label: Text('Eligible: $eligible')),
                _stateChip(),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: state == RaffleState.registrationOpen ? onCloseRegistration : null,
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Stop registration'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: state == RaffleState.registrationClosed ? onStartDrawing : null,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Start drawing'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: state == RaffleState.drawingInProgress
                      ? () {
                          final w = onDraw();
                          if (w != null) {
                            showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('🎉 Winner'),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${w.firstName} ${w.lastName}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    Text('Ticket: ${w.ticket}'),
                                    Text('Mobile: ${w.mobile}'),
                                  ],
                                ),
                                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No more eligible participants or drawing finished.')));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.casino_outlined),
                  label: const Text('Draw winner'),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: canFinish && !raffleExported ? () => onFinishRaffle() : null,
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Finish raffle (download CSV)'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => onExportParticipants(context),
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Participants CSV (copy)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: winners.isEmpty ? null : () => onExportWinners(context),
                    icon: const Icon(Icons.emoji_events_outlined),
                    label: const Text('Winners CSV (copy)'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: raffleExported && !csvCooldown ? () => onDownloadRaffleCsv(context) : null,
                icon: const Icon(Icons.download_outlined),
                label: Text(csvCooldown ? 'Wait 3s…' : 'Download raffle CSV (again)'),
              ),
              const SizedBox(height: 16),

              // Date & time
              const Text('Raffle date & time', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('${_date(raffleDate)} — ${_time(raffleDate)}')),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDate: raffleDate);
                      if (d == null) return;
                      final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: raffleDate.hour, minute: raffleDate.minute));
                      final dt = DateTime(d.year, d.month, d.day, t?.hour ?? raffleDate.hour, t?.minute ?? raffleDate.minute);
                      onChangeDate(dt);
                    },
                    icon: const Icon(Icons.edit_calendar_outlined),
                    label: const Text('Change'),
                  )
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: raffleExported ? () => onConfirmReset(context) : null,
                icon: const Icon(Icons.restart_alt),
                label: const Text('New raffle (reset all)'),
              ),

              // ============================
              // Settings
              // ============================
              const Divider(height: 32),
              Row(children: const [
                Icon(Icons.tune_outlined),
                SizedBox(width: 8),
                Text('Raffle settings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              Text('Current title: $raffleTitle', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _showSettingsDialog(
                  context,
                  initialTitle: raffleTitle,
                  initialConsent: consentText,
                  onSave: onSaveSettings,
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit title, consent & admin PIN'),
              ),

              // ============================
              // Splash screen controls
              // ============================
              const Divider(height: 32),
              Row(children: const [
                Icon(Icons.image_outlined),
                SizedBox(width: 8),
                Text('Splash screen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: splashDataUrl != null && splashDataUrl!.isNotEmpty
                      ? Image.network(splashDataUrl!, fit: BoxFit.fill)
                      : const Center(child: Text('No splash image set')),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => onChangeSplashImage(),
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('Change splash image'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowSplash(),
                    icon: const Icon(Icons.slideshow_outlined),
                    label: const Text('Show splash screen'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _showSettingsDialog(
    BuildContext context, {
    required String initialTitle,
    required String initialConsent,
    required Future<void> Function(BuildContext ctx, String? newTitle, String? newPin, String? newConsentText) onSave,
  }) async {
    final titleCtrl = TextEditingController(text: initialTitle);
    final pinCtrl = TextEditingController();
    final consentCtrl = TextEditingController(text: initialConsent);
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Edit settings'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Raffle title (shown in Live)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: consentCtrl,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Consent text (shown in Registration)',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'New admin PIN (optional)',
                    hintText: 'Leave empty to keep current PIN',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Saving will require the current admin PIN.', style: TextStyle(color: Colors.black54)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final newTitle = titleCtrl.text.trim();
              final newPin = pinCtrl.text.trim().isEmpty ? null : pinCtrl.text.trim();
              final newConsent = consentCtrl.text.trim();
              await onSave(context, newTitle, newPin, newConsent);
              // ignore: use_build_context_synchronously
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    titleCtrl.dispose();
    pinCtrl.dispose();
    consentCtrl.dispose();
  }

  Widget _lists(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Card(
        elevation: 2,
        child: Column(
          children: [
            const TabBar(tabs: [Tab(text: 'Participants'), Tab(text: 'Winners')]),
            Expanded(
              child: TabBarView(
                children: [
                  _listView(context, participants.isEmpty ? customers : participants, showWinnerFlag: true),
                  _listView(context, winners, showWinnerFlag: false, winner: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listView(BuildContext context, List<Customer> data, {bool showWinnerFlag = true, bool winner = false}) {
    if (data.isEmpty) return const Center(child: Text('No data'));
    return ListView.separated(
      itemBuilder: (_, i) {
        final c = data[i];
        final addrLine = [c.address, c.city, c.state, c.zipCode].where((e) => e.trim().isNotEmpty).join(', ');
        return ListTile(
          leading: CircleAvatar(child: Text(c.ticket.split('-').last)),
          title: Text('${c.firstName} ${c.lastName}'),
          subtitle: Text('''Mobile: ${c.mobile}
Address: $addrLine'''),
          isThreeLine: true,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(c.ticket, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (showWinnerFlag && c.alreadyWon) const SizedBox(height: 6),
              if (showWinnerFlag && c.alreadyWon) const Chip(label: Text('WINNER'), visualDensity: VisualDensity.compact),
              if (winner) const SizedBox.shrink(),
            ],
          ),
        );
      },
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemCount: data.length,
    );
  }

  Widget _stateChip() {
    String txt;
    Color? color;
    switch (state) {
      case RaffleState.registrationOpen:
        txt = 'Registration open';
        color = Colors.green[100];
        break;
      case RaffleState.registrationClosed:
        txt = 'Registration closed';
        color = Colors.orange[100];
        break;
      case RaffleState.drawingInProgress:
        txt = 'Drawing in progress';
        color = Colors.blue[100];
        break;
      case RaffleState.drawingFinished:
        txt = 'Drawing finished';
        color = Colors.grey[300];
        break;
    }
    return Chip(label: Text(txt), backgroundColor: color);
  }

  String _date(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}-${dt.year}';
  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }
}
