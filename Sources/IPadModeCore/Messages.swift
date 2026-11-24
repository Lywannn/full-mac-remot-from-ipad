public enum Messages {
    public static let confirmTitle = "Tampilan iPad aktif."
    public static func confirmBody(_ n: Int) -> String { "Kembali otomatis dalam \(n) detik." }
    public static let keep = "Pertahankan"
    public static let revert = "Kembalikan"
    /// `seconds` is the confirmation window; 0 means no confirmation.
    public static func remoteEntered(seconds n: Int) -> String {
        n > 0 ? "Mode Remote iPad aktif — konfirmasi di layar dalam \(n) detik." : "Mode Remote iPad aktif."
    }
    public static let remoteAlreadyActive = "Mode Remote iPad sudah aktif."
    public static let backToNormal = "Kembali ke Normal."
    public static let enterFailed = "Gagal masuk mode Remote — Mac tetap Normal. Lihat `ipadmode logs`."
    public static let exitFailed = "Gagal menyalakan monitor — layar iPad tetap dipakai. Coba Layar Normal lagi atau tekan ⌃⌥⌘N."
    public static let startupRestoreFailed = "Monitor belum menyala setelah ipadmode dimulai ulang — dicoba lagi tiap 10 detik. Lihat `ipadmode logs`."
    public static let noPhysicalMonitor = "Tidak ada monitor fisik yang tersambung — layar iPad tetap dipakai."
    public static let locked = "Mac terkunci — buka kunci dulu, lalu coba lagi."
    public static let busy = "Sedang berpindah mode, coba lagi sebentar."
    /// B-11: the emergency hotkey could not be registered at start.
    public static let hotkeyUnavailable = "Hotkey ⌃⌥⌘N tidak bisa didaftarkan — pakai tombol Layar Normal."
    public static let sidecarActive = "Sidecar sedang aktif; putuskan dulu atau pakai iPad Sidecar."
    public static let unavailable = "Mode tidak tersedia: API layar tidak ditemukan setelah update macOS. Mac tetap Normal. Jalankan `ipadmode doctor`."
    public static let revertedTimeout = "Tidak ada konfirmasi — kembali ke Normal."
    public static let revertedLocked = "Mac terkunci — kembali ke Normal."
    public static let targetLost = "Layar iPad hilang — monitor dinyalakan lagi."
    public static let virtualFailed = "Layar virtual gagal dibuat — Mac tetap Normal."
    public static let recovered = "Monitor dipulihkan otomatis setelah gangguan. Lihat `ipadmode logs`."
    public static let safeMode = "ipadmode dalam mode aman setelah beberapa kali crash. Mac tetap Normal. Jalankan `ipadmode doctor`."
    public static func flapping(_ name: String) -> String { "Monitor \(name) terus menyala sendiri — dibiarkan menyala." }
    /// A-5: Normal is back, but this monitor (or these, comma-separated) did not come on.
    public static func monitorStillOff(_ name: String) -> String { "Monitor \(name) belum menyala — coba Layar Normal lagi." }
    public static func resolutionSet(_ r: Resolution) -> String { "Resolusi diganti ke \(r.text)." }
    public static func resolutionFailed(_ r: Resolution) -> String {
        "Gagal mengganti resolusi ke \(r.text) — resolusi tidak berubah. Lihat `ipadmode logs`."
    }
    public static let resolutionInvalid = "Resolusi tidak didukung. Pilihan: 1180x820, 1321x918, 1416x984, 1534x1066, 1652x1148."
    public static let daemonDown = "ipadmode tidak berjalan. Jalankan scripts/install.sh lalu `ipadmode doctor`."
    public static let sidecarUnsupported = "Mode Sidecar belum tersedia di versi ini."
    public static let disabled = "ipadmode dimatikan; Mac Normal. Nyalakan lagi dengan `ipadmode enable`."
    public static let badRequest = "Permintaan tidak dikenali — versi ipadmode CLI dan daemon berbeda. Jalankan scripts/install.sh."

    // MARK: CLI
    public static let usage = """
        Pemakaian: ipadmode <perintah>

        remote [--confirm-seconds N]  Masuk mode Remote iPad (N detik konfirmasi, 0 = tanpa konfirmasi, maksimal 600)
        sidecar                       Masuk mode Sidecar (belum tersedia)
        normal                        Kembali ke monitor Normal
        status [--json] [--offline]   Tampilkan mode, layar, dan proses; --offline membaca file tanpa daemon (aman lewat SSH)
        resolution WxH                Ganti resolusi layar iPad (1180x820, 1321x918, 1416x984, 1534x1066, 1652x1148)
        logs                          Tampilkan 50 baris terakhir log daemon dan watchdog
        doctor                        Periksa kesehatan ipadmode dan Mac (kode keluar 2 jika ada yang kritis)
        disable                       Matikan ipadmode dan kembalikan Mac ke Normal (aman dari SSH)
        enable                        Nyalakan lagi ipadmode setelah disable
        daemon | watchdog | vdisplay  Peran internal, dijalankan oleh LaunchAgent
        --help                        Tampilkan bantuan ini

        Kode keluar: 0 ok, 1 ditolak daemon, 2 gagal (daemon), 3 daemon mati/dimatikan, 4 tidak didukung,
        5 daemon sibuk, 6 jawaban tidak valid, 64 salah pakai
        """
    public static let enableHint = "Tidak bisa menyalakan agen dari sesi ini. Jalankan dari Terminal di sesi GUI: launchctl kickstart gui/$(id -u)/local.ipadmode.daemon"
    public static let enabled = "ipadmode dinyalakan lagi."
    public static let disableUnverified = "Peringatan: monitor belum terlihat menyala dalam 10 detik. Periksa dengan `ipadmode status --offline`."
    public static let disableNormalWarning = "Peringatan: kembali ke Normal tidak dikonfirmasi; melanjutkan mematikan ipadmode."
    public static func markerWriteFailed(_ why: String) -> String { "Gagal menulis penanda disabled: \(why)" }
    public static let logsMissing = "(belum ada log)"
    public static func logsHeader(_ name: String) -> String { "== \(name) ==" }
    public static let invalidStatusResponse = "Jawaban daemon tidak lengkap atau tidak dikenali. Jalankan scripts/install.sh."

    // MARK: Doctor
    public static let doctorOK = "OK"
    public static let doctorWarning = "PERINGATAN"
    public static let doctorFailure = "GAGAL"
    public static func doctorAPI(_ name: String, available: Bool) -> String {
        available ? "API layar \(name) tersedia." : "API layar \(name) tidak ditemukan. Mode Remote tidak akan jalan."
    }
    public static func doctorAgentLoaded(_ label: String) -> String { "Agen \(label) termuat." }
    public static func doctorAgentMissing(_ label: String) -> String {
        "Agen \(label) belum termuat. Jalankan scripts/install.sh."
    }
    public static func doctorHeartbeatFresh(_ who: String, pid: Int32) -> String { "Detak \(who) segar (PID \(pid))." }
    public static func doctorHeartbeatStale(_ who: String) -> String { "Detak \(who) tidak ada atau sudah basi." }
    public static func doctorHeartbeatStalePID(_ who: String, pid: Int32) -> String {
        "Detak \(who) sudah basi (PID terakhir \(pid))."
    }
    public static let doctorSocketDead = "Daemon berdetak tetapi tidak menjawab perintah (soket gagal dibuat?). Mulai ulang dengan `launchctl kickstart -k gui/$(id -u)/local.ipadmode.daemon`."
    public static let doctorSocketOK = "Soket daemon menjawab."
    public static let doctorRustDeskArm = "RustDesk berjalan native arm64."
    public static func doctorRustDeskNotArm(_ archs: String) -> String { "RustDesk bukan arm64 (\(archs)); perbarui ke build Apple Silicon." }
    public static let doctorRustDeskUnreadable = "RustDesk tidak ditemukan atau arsitekturnya tidak terbaca."
    public static let doctorRustDeskServerOK = "Server RustDesk (--server) berjalan."
    public static func doctorRustDeskServerDown(uid: UInt32) -> String {
        "Agen server RustDesk (--server) tidak berjalan; sesi saat ini dilayani aplikasi RustDesk. Kalau aplikasi RustDesk tertutup, pulihkan dengan: sudo launchctl kickstart -k gui/\(uid)/com.carriez.RustDesk_server"
    }
    public static func doctorPortOpen(_ port: Int) -> String { "Port \(port) menerima koneksi." }
    public static func doctorPortClosed(_ port: Int) -> String { "Port \(port) tidak menerima koneksi di 127.0.0.1." }
    public static let doctorAutorestartOn = "Mulai ulang otomatis setelah listrik padam aktif."
    public static let doctorAutorestartOff = "Mulai ulang otomatis setelah listrik padam mati (pmset autorestart 0)."
    public static let doctorAutorestartUnknown = "Pengaturan autorestart tidak terbaca dari `pmset -g`."
    public static let doctorFileVaultOn = "FileVault aktif (hanya info). Setelah listrik padam, Mac berhenti di layar FileVault; buka lewat ~/bin/mac-unlock di mps."
    public static let doctorFileVaultOff = "FileVault mati."
    public static let doctorFileVaultUnknown = "Status FileVault tidak terbaca."
    public static let doctorUpdatesOff = "Update macOS otomatis mati."
    public static let doctorUpdatesOn = "Update macOS otomatis aktif; Mac bisa restart sendiri saat Anda remote."
    public static let doctorUpdatesUnknown = "Pengaturan update otomatis tidak terbaca (anggap belum diatur)."
    public static let doctorConfigOK = "Config valid."
    public static func doctorConfigWarning(_ w: String) -> String { "Config: \(w)" }
    public static let doctorNotDisabled = "ipadmode tidak dimatikan."
    public static let doctorDisabled = "ipadmode sedang dimatikan (marker disabled ada). Nyalakan dengan `ipadmode enable`."
    public static let doctorSafeModeOff = "Mode aman tidak aktif."
    public static let doctorSafeModeOn = "Mode aman aktif setelah beberapa kali crash. Setelah 10 menit, mulai ulang daemon dengan `launchctl kickstart -k gui/$(id -u)/local.ipadmode.daemon`."
    public static let daemonReplyFailed = "Daemon tidak menjawab dengan benar — lihat `ipadmode logs`."
    public static let doctorSocketBad = "Daemon berdetak tetapi jawabannya tidak dikenali; lihat `ipadmode logs`."
    public static let enableMarkerFailed = "Gagal menghapus penanda disabled; ipadmode belum dinyalakan."
    public static let enableNotInstalled = "Agen ipadmode belum terpasang. Jalankan scripts/install.sh."
}
