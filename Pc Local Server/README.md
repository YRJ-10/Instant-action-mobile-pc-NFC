# PC Local Server

Server lokal untuk menerima aksi dari Android via Wi-Fi.

## Jalankan

```powershell
cd "Pc Local Server"
.\start-server.ps1
```

Atau:

```powershell
node .\server.mjs
```

Saat pertama jalan, server membuat `config.json` otomatis berisi token pairing.

## Endpoint

- `GET /health`
- `GET /pair`
- `POST /api/intent`
- `POST /api/files?filename=name.ext`

Header wajib untuk endpoint `POST`:

```http
X-Device-Token: token-dari-config-json
```

## Contoh intent

URL:

```json
{
  "type": "url",
  "source": "manual",
  "payload": {
    "url": "https://example.com"
  }
}
```

Clipboard:

```json
{
  "type": "clipboard",
  "source": "manual",
  "payload": {
    "text": "hello from android"
  }
}
```

File base64:

```json
{
  "type": "file",
  "source": "manual",
  "payload": {
    "filename": "note.txt",
    "content_base64": "aGVsbG8="
  }
}
```

Command:

```json
{
  "type": "command",
  "source": "manual",
  "payload": {
    "command_id": "open_inbox"
  }
}
```

Command bebas tidak didukung. Tambahkan command ke `allowed_commands` di `config.json`.
