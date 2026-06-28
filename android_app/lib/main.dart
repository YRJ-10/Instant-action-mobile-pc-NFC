import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

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
  final _baseUrlController = TextEditingController(text: 'http://192.168.1.2:8765');
  final _tokenController = TextEditingController();
  final _urlController = TextEditingController(text: 'https://example.com');
  final _textController = TextEditingController(text: 'hello from android');

  bool _busy = false;
  String _status = 'Ready';

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    _urlController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _testHealth() async {
    await _run('Testing health', () async {
      final result = await _getJson('/health');
      return 'PC online: ${result['app'] ?? 'unknown'}';
    });
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
      final result = await _postJson('/api/intent', intent);
      return result['ok'] == true ? 'Sent: ${intent['type']}' : 'Failed';
    });
  }

  Future<void> _run(String pending, Future<String> Function() task) async {
    setState(() {
      _busy = true;
      _status = pending;
    });

    try {
      final message = await task().timeout(const Duration(seconds: 8));
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

  Future<Map<String, dynamic>> _postJson(String path, Map<String, Object?> body) async {
    final uri = _uri(path);
    final client = HttpClient();
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.add('X-Device-Token', _tokenController.text.trim());
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

  Uri _uri(String path) {
    final base = _baseUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Action'),
        actions: [
          IconButton(
            tooltip: 'Test connection',
            onPressed: _busy ? null : _testHealth,
            icon: const Icon(Icons.wifi_tethering),
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
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Device token',
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _testHealth,
              icon: const Icon(Icons.check_circle),
              label: const Text('Test PC'),
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
