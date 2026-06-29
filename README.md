# NFC Instant Action

NFC Instant Action adalah prototype aplikasi koneksi instan antara Android dan PC lewat jaringan lokal. NFC dipakai sebagai trigger, sementara data seperti URL, clipboard, dan file dikirim lewat Wi-Fi lokal ke PC server.

## Screenshot

![Sampel 1](Sampel%201.png)

![Sampel 2](Sampel%202.png)

## Komponen

- `android_app/` - aplikasi Flutter Android.
- `Pc Local Server/` - aplikasi PC server lokal dengan UI desktop.

## Cara Pakai Singkat

1. Jalankan PC app:
   ```powershell
   cd "Pc Local Server"
   .\start-pc-app.cmd
   ```

2. Di Android app:
   - isi `PC Address`
   - isi `Pairing Code`
   - tap `Trust Phone`

3. Setelah trusted:
   - `Run Tap Action` untuk simulasi NFC
   - `Find PC` jika IP PC berubah

Saat sticker NFC sudah tersedia, tag akan dipakai untuk membuka app dan menjalankan alur yang sama seperti `Run Tap Action`.
