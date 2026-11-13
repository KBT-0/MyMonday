"""Notification texts of the server/ops jobs. OPS_LANG in local.env picks the language (en, tr).
Add a language by adding a dict with the same keys; missing keys fall back to English."""

MESSAGES = {
    "en": {
        # lead_watch
        "ev_permission": "🔐 waiting for permission",
        "ev_question": "❓ asking a question",
        "ev_stop": "✅ done, waiting for you",
        "ev_failure": "⛔ failed",
        "ev_ended": "⚪ session ended",
        "mac_offline": "Mac offline (lid closed or asleep)",
        "lead_waits_30": "{names} waiting 30 minutes for an answer",
        "mode1_back": "{why}: back to work mode 1, lead notifications come here instantly again.",
        "events_unreadable": "lead_watch: cannot read events from the workstation (rc={rc}/{rc2}), 3 tries. Needs a look.",
        "stop_delayed": "[{lead}] ✅ finished {mins} minutes ago, waiting for you",
        "kind_question": "question",
        "kind_permission": "permission",
        "remind": "[{lead}] ⏰ waiting {mins} minutes for a {what} answer",
        "waiting_now": "Waiting for you: {names}",
        "lead_crashed": "[{lead}] ⚪ claude is no longer running (no session-end event: crashed or killed)",
        "ssh_broken": "lead_watch: the workstation is online on the tailnet but ssh has failed for {mins} minutes. Needs a look.",
        # spend_summary
        "spend": "💸 Today ${today:.2f} · Month ${month:.2f}{left} · Cache hits {hit} (Hermes estimate{since})",
        "spend_left": " · Left ~${left:.2f}",
        "spend_since": ", since {hhmm}",
    },
    "tr": {
        "ev_permission": "🔐 izin bekliyor",
        "ev_question": "❓ soru soruyor",
        "ev_stop": "✅ bitti, seni bekliyor",
        "ev_failure": "⛔ hata verdi",
        "ev_ended": "⚪ oturum kapandı",
        "mac_offline": "Mac çevrimdışı (kapak kapalı ya da uykuda)",
        "lead_waits_30": "{names} 30 dakikadır cevap bekliyor",
        "mode1_back": "{why}: 1. çalışma moduna döndüm, lead bildirimlerini yine anında buradan atacağım.",
        "events_unreadable": "lead_watch: iş istasyonundan olay okunamıyor (rc={rc}/{rc2}), 3 deneme. Kontrol gerekiyor.",
        "stop_delayed": "[{lead}] ✅ {mins} dakikadır bitmiş, seni bekliyor",
        "kind_question": "soru",
        "kind_permission": "izin",
        "remind": "[{lead}] ⏰ {mins} dakikadır {what} cevabı bekliyor",
        "waiting_now": "Seni bekleyenler: {names}",
        "lead_crashed": "[{lead}] ⚪ claude artık çalışmıyor (oturum kapanış olayı yok: çöktü ya da sonlandırıldı)",
        "ssh_broken": "lead_watch: iş istasyonu tailnet'te çevrimiçi ama ssh {mins} dakikadır başarısız. Kontrol gerekiyor.",
        "spend": "💸 Bugün ${today:.2f} · Ay ${month:.2f}{left} · Cache isabet {hit} (Hermes tahmini{since})",
        "spend_left": " · Kalan ~${left:.2f}",
        "spend_since": ", {hhmm} sonrası",
    },
}
