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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Instant Action',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF15616D)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const HomeScreen(),
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

  final _baseUrlController = TextEditingController(text: 'http://192.168.1.6:8765');
  final _pairingTokenController = TextEditingController();
  final _urlController = TextEditingController(text: 'https://example.com');
  final _textController = TextEditingController(text: 'hello from android');

  bool _busy = false;
  String _status = 'Ready';
  String _deviceId = '';
  String _deviceToken = '';
  String _pcId = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
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
    final config = await _prefs.invokeMapMethod<String, String>('loadConfig') ?? {};
    _deviceId = config['deviceId']?.isNotEmpty == true ? config['deviceId']! : _newDeviceId();
    _deviceToken = config['deviceToken'] ?? '';
    _pcId = config['pcId'] ?? '';

    if ((config['baseUrl'] ?? '').isNotEmpty) {
      _baseUrlController.text = config['baseUrl']!;
    }
    _pairingTokenController.text = config['pairingToken'] ?? '';

    await _saveConfig(showStatus: false);
    if (mounted) {
      setState(() => _status = _deviceToken.isEmpty ? 'Register device first' : 'Ready');
    }
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
          'device_name': Platform.localHostname,
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
      final response = await request.close().timeout(const Duration(milliseconds: 650));
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
      request.headers.add('X-Pairing-Token', _pairingTokenController.text.trim());
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
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'android-$hex';
  }

  void _ensureDeviceId() {
    if (_deviceId.isEmpty) _deviceId = _newDeviceId();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Action'),
        actions: [
          IconButton(
            tooltip: 'Find PC',
            onPressed: _busy ? null : _findPc,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Save config',
            onPressed: _busy ? null : _saveConfig,
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusPanel(status: _status, busy: _busy),
            const SizedBox(height: 16),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'PC server URL',
                prefixIcon: Icon(Icons.computer),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pairingTokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Pairing token',
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 12),
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
                    label: const Text('Register'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL context',
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Clipboard text',
                prefixIcon: Icon(Icons.content_paste),
              ),
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _simulateTap,
              icon: const Icon(Icons.nfc),
              label: const Text('Simulate Tap'),
            ),
          ],
        ),
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
