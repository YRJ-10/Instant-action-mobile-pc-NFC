# Android App

Flutter client awal untuk mengetes koneksi Android ke PC Local Server.

## Fitur awal

- input PC server URL
- input pairing token dari output PC server
- register Android sebagai trusted device
- simpan config lokal di app
- test `GET /health`
- find PC kalau IP berubah
- kirim URL dummy ke PC
- kirim teks ke clipboard PC
- simulasi tap NFC berdasarkan isi input

## Jalankan

```powershell
cd android_app
flutter pub get
flutter run
```

Catatan: Android harus satu Wi-Fi dengan PC. Gunakan IP PC, bukan `127.0.0.1`.
