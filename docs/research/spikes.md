# Hasil spike dan verifikasi lapangan

## RustDesk — 2026-11-23

- **Sebelum:** RustDesk 1.4.9, x86_64, berjalan lewat Rosetta. `RustDesk_hwcodec.toml` mencatat signature 257 dan `ram_encode: []`, artinya tidak ada encoder hardware. Encoder yang terpakai AV1 software pada 3440×1440.
- **Sesudah:** RustDesk **1.5.3**, **arm64**. Sumber: rilis GitHub `rustdesk-1.5.3-aarch64.dmg`, sha256 `e6d30fa1633d772c48935907c208ca4e555a856fb2038af3aaa87a327c29360b`.
  - Tanda tangan: `com.carriez.rustdesk`, Team `HZF9JMC8YN`, Notarized Developer ID. Identifier dan Team sama dengan build lama.
  - `RustDesk_hwcodec.toml`: signature 65793, `ram_encode: [hevc_videotoolbox]`.
  - Sesi dari iPad lewat Tailscale: `usable: vp8=true, av1=true, h264=false, h265=true` → `encoder: H265`.
- **Izin macOS:** tidak perlu diberikan ulang. Gambar, mouse, dan keyboard langsung berfungsi dari iPad. Identifier dan Team sama, jadi izin TCC ikut terbawa.
- **Setting server:** rendezvous dan relay tetap utuh, karena `~/Library/Preferences/com.carriez.RustDesk` tidak disentuh.
- **Issue #16457** (H.265 macet setiap 1–3 menit di macOS): ditutup 2026-10-08, sebelum rilis 1.5.3. Perlu dipantau di sesi panjang.
- **Cara pasang:** `scripts/rustdesk-swap.sh`, dijalankan dengan sudo.
  - Percobaan pertama gagal setelah tahap "stopping", karena `$APP…` dengan elipsis Unicode terbaca sebagai nama variabel lain oleh bash 3.2 di bawah sudo. Diperbaiki di commit 92d74c6, lalu percobaan kedua berhasil.
- **Rollback:** jalankan script yang sama dengan `~/RustDesk-backup/RustDesk-1.4.9-x86_64.app`. Backup setting tersimpan di `~/RustDesk-backup/prefs-2026-11-23.tgz` (0600).

## SP1 — layar virtual (sebagian) — 2026-11-23 ±16:50

Alat: `ipadmode-spike`, di-build di scratch terpisah (`IPADMODE_SCRATCH=~/Library/Caches/ipadmode-spike-build`). Safetynet dipasang 90 detik. Tidak ada monitor yang diputus.

| Uji | Hasil |
|---|---|
| Buat `--points 1180x820` | READY setelah 0,30 dtk; online+aktif +0,18 dtk; mode **1180x820 pt / 2360x1640 px @60** (HiDPI 2x) |
| SIGTERM | layar hilang dalam **0,16 dtk** |
| Buat ulang, lalu SIGKILL | layar hilang dalam **0,15 dtk** |
| `--points 1416x984` | mode aktif **1416x984 pt / 2832x1968 px**. pertanyaan terbuka terjawab: mode pertama di daftar `modes` menjadi mode aktif |
| Setelah semua uji | Legion (id 1) tetap main 3440x1440@240; P24 (id 3) tetap 1080x1920 (**potret**) |

Belum diuji, perlu dicoba manual:
- ganti mode lewat System Settings, lalu hapus layar setelah ganti mode;
- layar virtual tertangkap RustDesk.

## SP2 — memutus monitor — 2026-11-23 ±17:10

Uji dijalankan pada P24 (id 3, potret 1080x1920). Legion tetap menyala. Safetynet dipasang 180 detik. Saya tersambung lewat RustDesk; sesinya tidak terganggu.

| Lingkup | Cara proses berakhir | Monitor mati setelah | Monitor kembali setelah proses berakhir |
|---|---|---|---|
| `.forAppOnly` | keluar normal (rc 0) | 0,29 dtk | **TIDAK** (tetap mati 8 dtk, perlu `enable-all`) |
| `.forAppOnly` | SIGTERM | 0,05 dtk | 0,08 dtk (alat spike tidak punya handler SIGTERM, jadi ini tidak bisa diandalkan) |
| `.forAppOnly` | SIGKILL | 0,23 dtk | **TIDAK** |
| `.forAppOnly` | abort (`--crash`) | 0,31 dtk | **TIDAK** |
| `.forSession` | keluar normal | 0,07 dtk | tetap mati (sesuai harapan); `enable-all --scope session` menyalakan lagi dalam 0,17 dtk |

Temuan:
- **`.forAppOnly` TIDAK mengembalikan konfigurasi saat proses mati** di macOS 27.0.1. Keluar normal, SIGKILL, dan abort semuanya membiarkan monitor mati. Lapis L6 dari spec untuk kasus crash tidak berlaku.
- **Keputusan: `ConfigScope` = `.forSession`.** Pemulihan saat daemon crash sepenuhnya bergantung pada watchdog (L4) dan proses anak `vdisplay` (lihat R25).
- Menyalakan monitor kembali cepat: 0,16–0,17 dtk.
- **Orientasi potret P24 tetap terjaga** setelah dinyalakan kembali (1080x1920).
- Monitor yang mati melaporkan mode `1x1` (`CGDisplayCopyDisplayMode`). Backend tidak boleh menyimpan `1x1` di snapshot; perlakukan sebagai `nil`.
- Uji logout untuk `.forSession` belum dilakukan (dijadwalkan bersama fase Sidecar).

## SP1 — bagian manual (lewat RustDesk) — 2026-11-23 ±17:25

- System Settings › Displays menampilkan "iPad Remote" sebagai *Extended display*, dengan profil warna "iPad Remote".
  - Daftar ringkas resolusinya: 1534×1066, 1321×918, **1180×820 (Default)**, 1024×712. Mode lain ada di "Show all resolutions".
  - 1024×712 bukan mode yang kami tawarkan; macOS menambahkannya sendiri.
- Ganti ke 1321×918 berhasil: `list` → **1321x918 pt / 2642x1836 px @60**.
- RustDesk 1.5.3 dari iPad bisa memilih monitor "iPad Remote", dan gambarnya tampil.
- Setelah mode diganti, SIGTERM ke proses pemilik menghapus layar dalam **0,37 dtk**. Proses berakhir selalu menghapus layar, termasuk setelah ganti mode.
- **SP1 lulus.**

## SP3 — RustDesk saat monitor diputus — 2026-11-23 23:28

`remote-sim --scope session`: layar virtual dibuat, dijadikan main, ditunggu 1 dtk, lalu Legion dan P24 diputus. Saya tersambung lewat RustDesk 1.5.3 dari iPad.

- Selama mode, layar virtual (id 28) adalah satu-satunya layar aktif dan main di (0,0).
  - Resolusinya **1321x918**, padahal yang diminta 1180x820. macOS mengingat pilihan System Settings dari SP1 untuk identitas layar ini (vendor/product/serial sama). **Daemon harus menerapkan resolusi dari config secara eksplisit.**
- **Pengamatan langsung: RustDesk iPad langsung pindah ke layar seukuran iPad (desktop + menu bar), tanpa sambung ulang.** G1 terpenuhi.
  - Log RustDesk tidak mencatat "Displays changed" selama jendela ini; catatan baru muncul saat monitor dinyalakan lagi. Jadi log tidak bisa dipakai sebagai bukti perpindahan.
- **Pemulihan dengan urutan I3** (`enable-all` → origin dipulihkan, virtual dipindah ke kanan → virtual dihapus): susunan akhir persis seperti semula (Legion main 0,0; P24 potret −1080,−326).
  - Di tengah pemulihan, P24 sempat muncul landscape di (1321,0) dan Legion butuh lebih dari 2 dtk untuk aktif. Setelah itu stabil.
  - RustDesk sempat mencatat `encode fail` satu kali dan `Failed to get display 1` saat jumlah layar berubah, lalu pulih sendiri di monitor0. Sesi tidak putus.
- Uji celah tanpa layar (kill -9) **dilewati**. Dengan `.forSession`, hasilnya sudah pasti: monitor tetap mati sampai ada yang menyalakannya. Mitigasinya watchdog (L4) dan R25 (anak `vdisplay` menyalakan monitor dulu sebelum keluar).
- Uji layar kunci di layar virtual dilewati (hanya informasi); dicakup di uji penerimaan.

## SP4 — monitor menyala sendiri setelah tidur/bangun? — 2026-11-23 23:35

- P24 diputus (`--scope session`), lalu `pmset displaysleepnow` dan dibangunkan dengan `caffeinate -u`.
- **P24 tetap mati** setelah bangun (dicek 4 dan 8 dtk sesudahnya). macOS tidak menyalakan lagi monitor yang diputus.
- Setelah tidur, monitor butuh **±2–4 dtk** untuk aktif lagi setelah `enable-all`, karena harus bangun dari standby. Sebelumnya 0,17 dtk.

## Gerbang R — LULUS (2026-11-23)

| Keputusan | Nilai | Dasar |
|---|---|---|
| `IPadModeDefaults.configScope` | **`.session`** | SP2: `.forAppOnly` tidak kembali saat proses mati |
| `IPadModeDefaults.settleDelay` | **1 dtk** | SP3: dengan jeda 1 dtk klien sudah pindah |
| Waktu tunggu monitor aktif saat exit | **naikkan ke 10 dtk** (R27) | SP3/SP4: monitor dari standby butuh 2–4 dtk |
| Penegakan ulang (§7.7 aturan 2) | tetap dipertahankan, untuk cabut-colok | SP4: tidur/bangun tidak memicu monitor menyala |
| Pemulihan monitor | `enable-all` langsung; monitor aktif 0,17 dtk, atau 2–4 dtk dari standby | memenuhi syarat Gerbang R bersama watchdog 0,5 dtk |

## Temuan sampingan: proses server RustDesk 1.5.3

- LaunchAgent `com.carriez.RustDesk_server` keluar dengan **kode 0** setelah ±16:43 dan tidak dijalankan ulang (`KeepAlive` = SuccessfulExit false). Sesi sekarang dilayani **aplikasi utama RustDesk** (log: `~/Library/Logs/RustDesk/RustDesk_rCURRENT.log`).
- **Risiko:** kalau aplikasi utama ditutup, mungkin tidak ada server RustDesk yang berjalan. Pemulihan lewat SSH: `sudo launchctl kickstart -k gui/501/com.carriez.RustDesk_server`. Perlu diuji.

## Temuan malam 2026-11-24: proses anak `vdisplay` dan pandangan layar

### Crash `MainActor.assumeIsolated` setelah `dispatchMain()`

- Binary mencatat SDK 14.0, sehingga runtime Swift memakai pemeriksaan MainActor versi lama. Pemeriksaan itu hanya lulus di **main thread yang asli**.
- `dispatchMain()` mematikan main thread (pthread_exit), dan blok main queue lalu dijalankan thread lain. Akibatnya `MainActor.assumeIsolated` di handler GCD crash dengan "Incorrect actor executor assumption", status 5, sehingga setiap stop menghasilkan laporan crash.
- **Keputusan (R71/R75):** setiap peran tetap memakai main thread asli dan tidak pernah memanggil `dispatchMain()`.
- Tes siklus hidup dry-run (`IPADMODE_VDISPLAY_DRY_RUN=1`, tanpa membuat layar) menjalankan binary asli dan menjaga agar crash jenis ini tidak muncul lagi.

### Proses yang pernah bertransaksi tidak melihat perubahan dari proses lain (R75)

Alat: `staleview` (alat uji sekali pakai). Setiap percobaan memakai safetynet, dan susunan layar diperiksa kembali sama setelahnya. Proses uji mematikan P24 dalam transaksinya sendiri (`.forSession`); 2,5 detik kemudian proses lain menyalakannya lagi.

| Cara proses menunggu | Pandangan proses setelah P24 dinyalakan dari luar |
|---|---|
| `CFRunLoopRunInMode` | **basi** selama 8 dtk |
| `usleep` | **basi** |
| CFRunLoop + `CGDisplayRegisterReconfigurationCallback` | **basi**; callback tidak muncul untuk perubahan dari luar |
| `NSApplication.run` (`.accessory` maupun `.prohibited`) | **segar** dalam ±0,8 dtk |
| proses CF yang **belum pernah** bertransaksi | segar |
| CF + transaksi kosong (begin+complete tanpa perubahan) sebelum membaca | segar |

- Menyalakan layar yang sudah menyala mengembalikan error 1001 (`kCGErrorIllegalArgument`; `kCGErrorFailure` = 1000).
- **Keputusan:** daemon, watchdog, dan proses anak memakai event loop AppKit (`NSApp.run`; untuk watchdog dan anak dengan kebijakan `.prohibited`). Tanpa ini, watchdog yang pernah memulihkan monitor sekali tidak akan melihat monitor dimatikan pada sesi berikutnya. Tes hardware membaca layar lewat transaksi kosong (`freshDisplays`).

### R25 di hardware

- Monitor yang dinyalakan lagi bisa berkedip selama bangun dari standby: online (tidak aktif) → offline → online+aktif, ±3 dtk.
- Selama transisi itu monitor bisa **hilang** dari daftar layar, karena vendor sempat terbaca 0 dan shim membuang ID tersebut.
- **Keputusan (N1/N3):** layar virtual baru dilepas kalau setiap monitor yang pernah terlihat sudah tercatat online dan ada satu yang menyala, atau kalau batas 6 dtk lewat. Permintaan menyalakan diulang paling sering 1×/dtk, dan R25 digerakkan timer tanpa memblokir main thread.
- **Hasil:** `childRestoresMonitorsWhenParentDies` lulus (4,16 dtk). P24 kembali ke posisi semula.

### Lain-lain

- macOS langsung menjadikan layar virtual sebagai **main** begitu dibuat, karena macOS mengingat susunan untuk set layar ini. Susunan kembali normal setelah layar virtual dilepas.
- Safetynet spike lama sempat menyusun ulang monitor walau tidak ada masalah: P24 pindah ke kanan Legion. Posisinya langsung dipulihkan, dan sekarang safetynet hanya mengubah susunan kalau main-nya layar virtual.
