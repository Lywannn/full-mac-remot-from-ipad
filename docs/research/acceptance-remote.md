# Uji penerimaan mode Remote

Dijalankan pada 2026-11-24 pukul 09.25–09.42, setelah instalasi nyata (`scripts/install.sh --dock`, build release dari commit a39faa0).

Cara kerja selama uji:

- Mac sedang tidak dipakai. Sebelum setiap langkah dicek bahwa tidak ada input selama ≥60 detik (HID idle).
- Setiap langkah yang mengubah layar memakai safetynet spike, yang dimatikan lagi setelah susunan layar diverifikasi.
- Status layar dibaca dari proses terpisah (`layout dump`).

Susunan baseline: Legion (id 1) sebagai layar utama 3440x1440 di (0,0), dan P24 (id 3) 1920x1080 di (−1920,−326). Setelah semua uji, susunan ini persis kembali.

Tanda # adalah nomor skenario kegagalan di dokumen desain.

| Langkah | Skenario | Hasil |
|---|---|---|
| Instalasi | `install.sh --dock` | ✅ `doctor` OK semua. Satu-satunya peringatan adalah agen `--server` RustDesk yang sudah dikenal. Daemon dan watchdog `running`. Tidak ada rujukan ke SSD X. Dua item ditambahkan ke Dock. Symlink `/usr/local/bin/ipadmode` tidak dibuat karena tidak ada sudo tanpa password; perintahnya dicetak. |
| S1 | Alur utama (`remote --confirm-seconds 0`, lalu `normal`) | ✅ Masuk Remote dalam 3,36 dtk: hanya "iPad Remote" yang aktif, sebagai main di (0,0). Perintah `normal` selesai dalam 4,36 dtk, dan susunan baseline tercapai 1,23 dtk kemudian. ⚠️ **A1:** resolusinya 1321x918, bukan 1180x820 sesuai config. |
| S2 | #1 tanpa konfirmasi | ✅ `confirm.timedOut` tepat 20 dtk setelah perintah, lalu kembali ke baseline pada 22,9 dtk. |
| S4 | #4 daemon `kill -9` saat mode aktif | ✅ Proses anak menjalankan R25 dan monitor menyala lagi dalam **0,23 dtk**. Susunan baseline pulih 1,4 dtk kemudian. launchd menyalakan ulang daemon dalam keadaan Normal, dengan pemberitahuan `Messages.recovered`. |
| S5 (2×) | #5 daemon `kill -STOP` | ✅ Watchdog mendeteksi heartbeat basi, menyalakan monitor, lalu SIGTERM → SIGKILL. Monitor kembali dalam **4,81 dtk** dan **4,88 dtk**. Percobaan kedua dilayani **proses watchdog yang sama**, yang membuktikan R75 di hardware. |
| S6 | #6 watchdog `kill -9` | ✅ launchd menyalakannya lagi dalam 0,02 dtk. |
| S7 | #11 API privat hilang (simulasi) | ✅ Permintaan ditolak dengan `Messages.unavailable` dan tidak ada yang berubah. Percobaan pertama ditolak dengan `Messages.safeMode`, karena 3 crash uji S4/S5 dalam 10 menit memang memicu mode aman sesuai spec. `doctor` melaporkannya dengan benar (R81). |
| S8 | #12 kendali lewat SSH via `mps` | ✅ `status --offline` dan `normal` lewat `~/bin/mac` berfungsi. Kembali ke baseline 0,07 dtk setelah perintah. |
| S9 | #15 klik ganda | ✅ Permintaan kedua ditolak: "Sedang berpindah mode, coba lagi sebentar." ⚠️ **A2:** perintah `normal` ±1 dtk setelah masuk Remote gagal (`CGCompleteDisplayConfiguration` error). I1 tetap terjaga: layar virtual dipertahankan dan pesan gagal tampil. Perintah `normal` berikutnya berhasil. |
| S12 | `disable` lewat SSH saat aktif, lalu `enable` | ✅ `disable` mengembalikan Normal dalam 0,09 dtk. Setelah 12 dtk daemon dan watchdog berhenti dan tidak dinyalakan ulang. `enable` dari sesi GUI menyalakan keduanya lagi. |

## Temuan yang sudah diperbaiki

- **A1:** resolusi dari config tidak dipertahankan. Pilihan mode `.forAppOnly` dari proses anak lolos verifikasi saat READY. Setelah daemon mengubah konfigurasi, macOS menerapkan lagi mode yang tersimpan di System Settings untuk identitas layar ini.
- **A2:** jalur kembali Normal tidak mencoba ulang ketika CoreGraphics gagal sesaat.

## Belum diuji (perlu dicoba langsung di depan Mac)

- #19: kunci Mac (⌃⌘Q) saat mode aktif. Mode harus berakhir, dan layar kunci tampil di monitor.
- Panel konfirmasi: klik **Pertahankan**, tombol Return (pertahankan), dan Escape (kembalikan).
- #16: hotkey ⌃⌥⌘N dari keyboard Mac dan lewat RustDesk.
- #20: perintah `remote` saat Mac terkunci. Harus ditolak.
- #8: logout saat mode aktif.
- #2: sesi RustDesk diputus lalu disambung lagi dalam 1 menit. Mode harus tetap aktif.
- RustDesk ikut pindah ke layar virtual memakai daemon asli. Ini sudah diamati di SP3 memakai alat spike.
