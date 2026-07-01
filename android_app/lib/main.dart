import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const InstantActionApp());
}

class InstantActionApp extends StatelessWidget {
  const InstantActionApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF0D1117);
    const surface = Color(0xFF161B22);
    const surfaceHigh = Color(0xFF1F2733);
    const text = Color(0xFFE6EDF3);
    const muted = Color(0xFF8B949E);
    const primary = Color(0xFF2DD4BF);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Instant Action',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
          primary: primary,
          surface: surface,
          surfaceContainerHighest: surfaceHigh,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: text,
          elevation: 0,
          centerTitle: false,
        ),
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: text,
              displayColor: text,
            ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          labelStyle: const TextStyle(color: muted),
          prefixIconColor: muted,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF30363D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: primary, width: 1.4),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: const Color(0xFF06201D),
            disabledBackgroundColor: const Color(0xFF252B34),
            disabledForegroundColor: muted,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: primary,
            disabledForegroundColor: muted,
          ),
        ),
      ),
      home: const HomeScreen(),
      onGenerateRoute: (_) {
        return MaterialPageRoute(builder: (_) => const HomeScreen());
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _prefs = MethodChannel('instant_action/preferences');
  static const _appName = 'NFC Instant Action PC Server';

  final _baseUrlController =
      TextEditingController(text: 'http://192.168.1.6:8765');
  final _pairingTokenController = TextEditingController();
  final _urlController = TextEditingController();
  final _textController = TextEditingController();

  bool _busy = false;
  int _tabIndex = 0;
  String _status = 'Ready';
  String _deviceId = '';
  String _deviceToken = '';
  String _pcId = '';
  String _deviceName = 'Android device';

  @override
  void initState() {
    super.initState();
    _prefs.setMethodCallHandler(_handleNativeCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _pairingTokenController.dispose();
    _urlController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config =
        await _prefs.invokeMapMethod<String, String>('loadConfig') ?? {};
    _deviceId = config['deviceId']?.isNotEmpty == true
        ? config['deviceId']!
        : _newDeviceId();
    _deviceToken = config['deviceToken'] ?? '';
    _pcId = config['pcId'] ?? '';
    _deviceName = config['deviceName']?.isNotEmpty == true
        ? config['deviceName']!
        : 'Android device';

    if ((config['baseUrl'] ?? '').isNotEmpty) {
      _baseUrlController.text = config['baseUrl']!;
    }
    _pairingTokenController.text = config['pairingToken'] ?? '';

    await _saveConfig(showStatus: false);
    if (mounted) {
      setState(() =>
          _status = _deviceToken.isEmpty ? 'Register device first' : 'Ready');
    }
  }

  Future<void> _bootstrap() async {
    await _loadConfig();
    final link = await _prefs.invokeMethod<String>('consumeInitialDeepLink');
    await _handleDeepLink(link);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'deepLink') {
      unawaited(_handleDeepLink(call.arguments as String?));
    }
  }

  Future<void> _handleDeepLink(String? link) async {
    if (link == null || link.isEmpty || !mounted) return;

    final uri = Uri.tryParse(link);
    if (uri?.scheme != 'nfcinstant' || uri?.host != 'tap') return;

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _tabIndex = 0);
    await _simulateTap();
  }

  Future<void> _saveConfig({bool showStatus = true}) async {
    _ensureDeviceId();
    await _prefs.invokeMethod('saveConfig', {
      'baseUrl': _normalizedBaseUrl(),
      'pairingToken': _pairingTokenController.text.trim(),
      'deviceId': _deviceId,
      'deviceToken': _deviceToken,
      'pcId': _pcId,
    });
    if (showStatus && mounted) setState(() => _status = 'Config saved');
  }

  Future<void> _testHealth() async {
    await _run('Testing health', () async {
      final result = await _getJson('/health');
      final pcId = result['pc_id'];
      if (pcId is String && pcId.isNotEmpty) _pcId = pcId;
      await _saveConfig(showStatus: false);
      return 'PC online: ${result['app'] ?? 'unknown'}';
    });
  }

  Future<void> _registerDevice() async {
    await _run('Registering device', () async {
      _ensureDeviceId();
      final result = await _postJson(
        '/api/devices/register',
        {
          'device_id': _deviceId,
          'device_name': _deviceName,
        },
        pairing: true,
      );

      if (result['ok'] != true) {
        throw Exception(result['error'] ?? 'Registration failed');
      }

      _deviceToken = result['device_token'] as String;
      _pcId = result['pc_id'] as String;
      await _saveConfig(showStatus: false);
      return 'Device registered';
    });
  }

  Future<void> _findPc() async {
    await _run('Finding PC', () async {
      final current = Uri.parse(_normalizedBaseUrl());
      final host = current.host;
      final parts = host.split('.');
      if (parts.length != 4) throw Exception('Use IPv4 URL first');

      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      final port = current.hasPort ? current.port : 8765;

      for (var start = 1; start <= 254; start += 32) {
        final futures = <Future<String?>>[];
        for (var last = start; last < start + 32 && last <= 254; last++) {
          futures.add(_probePc('http://$prefix.$last:$port'));
        }
        final results = await Future.wait(futures);
        String? match;
        for (final result in results) {
          if (result != null) {
            match = result;
            break;
          }
        }
        if (match != null) {
          _baseUrlController.text = match;
          await _saveConfig(showStatus: false);
          return 'PC found: $match';
        }
      }

      throw Exception('PC not found on $prefix.0/24');
    });
  }

  Future<String?> _probePc(String baseUrl) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 350);
      final request = await client.getUrl(Uri.parse('$baseUrl/pair'));
      final response =
          await request.close().timeout(const Duration(milliseconds: 650));
      final json = await _readJson(response);
      if (json['app'] != _appName) return null;
      if (_pcId.isNotEmpty && json['pc_id'] != _pcId) return null;
      return baseUrl;
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendUrl() async {
    await _sendIntent({
      'type': 'url',
      'source': 'manual',
      'payload': {'url': _urlController.text.trim()},
    });
  }

  Future<void> _sendClipboard() async {
    await _sendIntent({
      'type': 'clipboard',
      'source': 'manual',
      'payload': {'text': _textController.text},
    });
  }

  Future<void> _sendCommand(String commandId) async {
    await _sendIntent({
      'type': 'command',
      'source': 'manual',
      'payload': {'command_id': commandId},
    });
  }

  Future<void> _pickAndSendFile() async {
    await _saveConfig(showStatus: false);
    await _prefs.invokeMethod('pickAndSendFile');
    if (mounted) setState(() => _status = 'Choose file to send');
  }

  Future<void> _simulateTap() async {
    final text = _textController.text.trim();
    final url = _urlController.text.trim();

    if (url.startsWith('http://') || url.startsWith('https://')) {
      await _sendUrl();
      return;
    }

    if (text.isNotEmpty) {
      await _sendClipboard();
      return;
    }

    setState(() => _status = 'No context. Show menu later.');
  }

  Future<void> _sendIntent(Map<String, Object?> intent) async {
    await _run('Sending intent', () async {
      if (_deviceToken.isEmpty) throw Exception('Register device first');
      final result = await _postJson('/api/intent', intent);
      if (result['ok'] != true) throw Exception(result['error'] ?? 'Failed');
      return 'Sent: ${intent['type']}';
    });
  }

  Future<void> _run(String pending, Future<String> Function() task) async {
    setState(() {
      _busy = true;
      _status = pending;
    });

    try {
      final message = await task().timeout(const Duration(seconds: 12));
      setState(() => _status = message);
    } catch (error) {
      setState(() => _status = 'Error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final uri = _uri(path);
    final client = HttpClient();
    final request = await client.getUrl(uri);
    final response = await request.close();
    return _readJson(response);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> body, {
    bool pairing = false,
  }) async {
    final uri = _uri(path);
    final client = HttpClient();
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    if (pairing) {
      request.headers
          .add('X-Pairing-Token', _pairingTokenController.text.trim());
    } else {
      request.headers.add('X-Device-Id', _deviceId);
      request.headers.add('X-Device-Token', _deviceToken);
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    return _readJson(response);
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException('Unexpected response: $text');
  }

  Uri _uri(String path) => Uri.parse('${_normalizedBaseUrl()}$path');

  String _normalizedBaseUrl() {
    return _baseUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
  }

  String _newDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'android-$hex';
  }

  void _ensureDeviceId() {
    if (_deviceId.isEmpty) _deviceId = _newDeviceId();
  }

  bool get _isTrusted => _deviceToken.isNotEmpty;

  bool get _hasPc => _pcId.isNotEmpty;

  Widget _buildTab() {
    return switch (_tabIndex) {
      0 => _buildActionTab(),
      1 => _buildConnectionTab(),
      _ => _buildSettingsTab(),
    };
  }

  Widget _buildActionTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeroPanel(
          busy: _busy,
          trusted: _isTrusted,
          connected: _hasPc,
          status: _status,
          onRun: _pickAndSendFile,
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'PC Commands',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _sendCommand('lock_pc'),
                      icon: const Icon(Icons.lock),
                      label: const Text('Lock PC'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _sendCommand('sleep_pc'),
                      icon: const Icon(Icons.bedtime),
                      label: const Text('Sleep PC'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _sendCommand('open_chrome'),
                  icon: const Icon(Icons.web),
                  label: const Text('Open Chrome'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Manual Context',
          child: Column(
            children: [
              TextField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Clipboard Text',
                  prefixIcon: Icon(Icons.content_paste),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : _sendUrl,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('Send URL'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : _sendClipboard,
                      icon: const Icon(Icons.content_copy),
                      label: const Text('Clipboard'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusPanel(status: _status, busy: _busy),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Connection Setup',
          child: Column(
            children: [
              TextField(
                controller: _baseUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'PC Address',
                  prefixIcon: Icon(Icons.computer),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pairingTokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Pairing Code',
                  prefixIcon: Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _testHealth,
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Test PC'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : _registerDevice,
                      icon: const Icon(Icons.verified_user),
                      label: const Text('Trust Phone'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _findPc,
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('Find PC'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _saveConfig(),
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          title: 'This Phone',
          child: Column(
            children: [
              _InfoRow(label: 'Name', value: _deviceName),
              _InfoRow(label: 'Trusted', value: _isTrusted ? 'Yes' : 'No'),
              _InfoRow(label: 'Device ID', value: _deviceId),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Paired PC',
          child: Column(
            children: [
              _InfoRow(label: 'Address', value: _normalizedBaseUrl()),
              _InfoRow(label: 'PC ID', value: _pcId.isEmpty ? '-' : _pcId),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Action'),
        actions: [
          IconButton(
            tooltip: 'Find PC on network',
            onPressed: _busy ? null : _findPc,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF0F2F31),
              foregroundColor: const Color(0xFF2DD4BF),
              disabledBackgroundColor: const Color(0xFF252B34),
            ),
            icon: const Icon(Icons.travel_explore),
          ),
          IconButton(
            tooltip: 'Save config',
            onPressed: _busy ? null : () => _saveConfig(),
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(
            key: ValueKey(_tabIndex),
            child: _buildTab(),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.nfc), label: 'Action'),
          NavigationDestination(icon: Icon(Icons.lan), label: 'Connection'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.busy,
    required this.trusted,
    required this.connected,
    required this.status,
    required this.onRun,
  });

  final bool busy;
  final bool trusted;
  final bool connected;
  final String status;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: const Color(0xFF30363D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F2F31),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.nfc, color: colors.primary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tap Action',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StateChip(
                  label: connected ? 'PC Ready' : 'No PC', active: connected),
              const SizedBox(width: 8),
              _StateChip(
                  label: trusted ? 'Trusted' : 'Untrusted', active: trusted),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: busy ? null : onRun,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.attach_file),
              label: const Text('Pick & Send File'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: const Color(0xFF30363D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child:
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF11261A) : const Color(0xFF252B34),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? const Color(0xFF3FB950) : const Color(0xFF8B949E),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                  color: Color(0xFF8B949E), fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.status, required this.busy});

  final String status;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        border: Border.all(color: const Color(0xFF30363D)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.bolt, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              status,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
