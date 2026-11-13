# check.py: self-check of option-buttons.patch on the installed ccgram (run by apply.sh).
# Fixtures are real Claude Code pane captures (AskUserQuestion, permission prompt).
from ccgram.handlers.interactive.interactive_ui import (
    _build_interactive_keyboard,
    parse_direct_choices,
)

ASK = """\
 ☐ Yaklaşım

Hangi yaklaşım?

❯ 1. Temkinli sınır (Önerilen)
     Değişikliği dar kapsamda tutar, riskli alanlara dokunmadan ilerler.
  2. Kesin düzeltme
     Sorunu kök nedeninden çözer, daha geniş bir değişiklik yapar.
  3. Type something.
────────────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

PERMISSION = """\
 Bash command
 Create perm.txt in /tmp/ccgram-btn and confirm it exists
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch /tmp/ccgram-btn/perm.txt && ls -l /tmp/ccgram-btn/perm.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp/ccgram-btn from this project
   3. No

 Esc to cancel · Tab to amend
"""

# second tab of a two-question AskUserQuestion, multiSelect (digits toggle the boxes)
MULTI = """\
←  ☒ Renk  ☐ Diller  ✔ Submit  →

Hangi diller?

❯ 1. [ ] Go
         Go dilini seç
  2. [✔] Rust
         Rust dilini seç
  3. [ ] Python
         Python dilini seç
  4. [ ] Type something
     Submit
────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""

SUBMIT = """\
←  ☒ Renk  ☒ Diller  ✔ Submit  →

Review your answers

 ● Renk?
   → Kırmızı

Ready to submit your answers?

❯ 1. Submit answers
  2. Cancel
"""


def rows(content):
    kb = _build_interactive_keyboard("@1", direct_choices=parse_direct_choices(content), sequence=1)
    return [[b.text for b in row] for row in kb.inline_keyboard]


assert rows(ASK) == [
    ["1 · Temkinli sınır (Önerilen)"],
    ["2 · Kesin düzeltme"],
    ["3 · Type something.", "4 · Chat about this", "⎋ Esc", "🔄"],
], rows(ASK)
assert rows(PERMISSION) == [
    ["1 · Yes"],
    ["2 · Yes, and always allow access to /tmp/ccgram-btn from this project"],
    ["3 · No"],
    ["⎋ Esc", "🔄"],
], rows(PERMISSION)
assert rows(SUBMIT) == [["1 · Submit answers"], ["2 · Cancel"], ["⎋ Esc", "🔄"]], rows(SUBMIT)
assert rows(MULTI)[:4] == [
    ["1 · [ ] Go"],
    ["2 · [✔] Rust"],
    ["3 · [ ] Python"],
    ["4 · [ ] Type something", "5 · Chat about this"],
], rows(MULTI)
assert "⇥ Tab" in rows(MULTI)[4], rows(MULTI)  # navigation kept for Submit
# prose with numbered lines and no menu footer or cursor gets no buttons
assert parse_direct_choices("Plan:\n1. a\n2. b\n") == (), parse_direct_choices("Plan:\n1. a\n2. b\n")
print("ccgram-patches: check ok")
