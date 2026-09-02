import Foundation

// FR-5 (zsh first) + per-tab shell history (founder 2026-08-31: "if i hit up
// it goes to the whole shell's history not the individual tab's history").
//
// Mechanism: memterm spawns each zsh pane with ZDOTDIR pointing at a small
// integration directory it writes at launch. The integration files source the
// user's real startup files (with ZDOTDIR restored around them, so their
// config sees the world unmodified) and then install hooks:
//   - preexec appends each command line to a per-pane .hist file in zsh
//     extended-history format (': <epoch>:0;<cmd>');
//   - a one-shot precmd seeds that file into the shell's own history with
//     `fc -R` at the FIRST prompt — empirically validated (macOS 26.2 zsh):
//     zsh loads the global $HISTFILE after .zshrc but before the first
//     precmd, so seeding at first precmd (never at rc end) makes the pane's
//     entries the NEWEST — ↑ walks this tab's commands first, then falls
//     into global history. fc -R'd entries are NOT written back to the
//     global HISTFILE at exit (verified), so global history is untouched;
//   - FR-5 bonus: OSC 7 cwd reports (chpwd + startup) and OSC 133 A/C/D
//     prompt marks (precmd/preexec), upgrading kernel-only cwd capture.
//
// Empirical facts this design rests on (all verified with real /bin/zsh in a
// sandbox before wiring — see the integration tests, which re-verify):
//   - preexec/precmd fire for piped-stdin interactive shells (`zsh -l -i`);
//   - a syntax or runtime error inside a SOURCED user rc aborts only that
//     file, never the calling integration rc — hooks still install;
//   - user-defined `precmd()`/`preexec()` functions and the hook arrays run
//     side by side natively (oh-my-zsh / powerlevel10k coexistence);
//   - login shells (memterm spawns "-zsh") read .zshenv/.zprofile/.zshrc
//     from $ZDOTDIR sequentially, and restoring ZDOTDIR before .zlogin makes
//     zsh read the user's own .zlogin natively;
//   - `fc -R` parses the extended-history format including timestamps;
//   - measured startup overhead ≈ 2–3 ms per shell (< 50 ms budget).
//
// Consent invariant: history seeding recalls text into the shell's OWN
// history — the user presses Enter to run anything. memterm never writes to
// the pty here; everything below happens inside zsh.
//
// Note: per-pane opt-out (beyond the global shell_integration key) is a
// possible later addition — it only needs the spawn path to skip the env.

public enum ShellIntegration {

    /// Bumped whenever the integration file contents change; stamped into
    /// every generated file. The app rewrites the files at each launch so
    /// they are always current.
    /// v2: repair the /etc/zshrc HISTFILE default — macOS's /etc/zshrc sets
    /// HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history, and with ZDOTDIR pointed at
    /// the integration dir that silently redirected the user's GLOBAL history
    /// into the state dir for any setup that doesn't set HISTFILE itself
    /// (oh-my-zsh only sets it when unset, so the default macOS + omz setup
    /// was affected).
    /// v3: freeze-before-trim (founder-amended FR-56, the council's data-loss
    /// finding) — the start-of-shell trim no longer DISCARDS the head lines:
    /// they roll into the `.hist.trimmed` sidecar first, and the trim only
    /// runs when the roll succeeded. The sidecar archives (and forgets, and
    /// orphan-sweeps) together with the .hist itself, so a close never loses
    /// commands the cap already pushed out of the live file.
    public static let version = 3

    /// Cap semantics (mirrored in the .zshrc trim): when the .hist file
    /// exceeds `trimThreshold` lines at shell start, it is rewritten to the
    /// last `trimKeep` lines — the rest rolls into the sidecar (v3).
    public static let trimThreshold = 2000
    public static let trimKeep = 1000

    /// zsh only this stage; other shells spawn exactly as before.
    public static func isZsh(shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    /// EXACT Swift mirror of the .zshrc hook's filename sanitization
    /// (`${MEMTERM_PANE_ID//[^A-Za-z0-9-]/_}`): ASCII letters, digits, and
    /// '-' pass; every other code point becomes '_'. This must match zsh
    /// byte-for-byte — the shell WRITES the file and Swift DELETES it
    /// (FR-56/57), so any divergence (e.g. ScrollbackText.safePaneId keeps
    /// all unicode alphanumerics, zsh does not) would leave a .hist file the
    /// forget flows never remove. Containment holds: '/' and '.' can never
    /// survive, so traversal shapes cannot escape the history dir.
    public static func histSafePaneId(_ paneId: String) -> String {
        let mapped = String(paneId.unicodeScalars.map { s -> Character in
            let v = s.value
            let ok = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                  || (v >= 0x30 && v <= 0x39) || v == 0x2D // A-Z a-z 0-9 -
            return ok ? Character(s) : "_"
        })
        return mapped.isEmpty ? "_invalid" : mapped
    }

    /// On-disk location of one pane's shell-history file. Same containment
    /// guarantee as scrollback files, via the zsh-parity sanitizer above.
    public static func histFileURL(dir: URL, paneId: String) -> URL {
        dir.appendingPathComponent("\(histSafePaneId(paneId)).hist")
    }

    /// The freeze-before-trim sidecar (v3): lines the start-of-shell trim
    /// rolled out of the live .hist. Written by the zsh hook, archived and
    /// deleted by Swift alongside the .hist — same sanitizer, same
    /// containment.
    public static func histTrimSidecarURL(dir: URL, paneId: String) -> URL {
        dir.appendingPathComponent("\(histSafePaneId(paneId)).hist.trimmed")
    }

    /// The command text of one extended-history line (": <epoch>:0;<cmd>"),
    /// for the archive's FTS index. A line without the prefix (hand-edited
    /// or foreign) is returned whole — indexing too much beats losing it.
    /// nil for blank lines.
    public static func commandText(historyLine: String) -> String? {
        let trimmed = historyLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix(": "),
              let semi = trimmed.firstIndex(of: ";") else { return trimmed }
        let cmd = String(trimmed[trimmed.index(after: semi)...])
        return cmd.isEmpty ? nil : cmd
    }

    // MARK: - History-line formatting (mirror of the preexec hook, for tests)

    /// zsh extended-history format. Newlines/carriage returns are flattened
    /// to spaces (one entry = one line, which keeps the trim logic a cheap
    /// line count and survives fc -R round-trips); quotes and percent signs
    /// pass through verbatim (the hook uses `print -r`, no % processing).
    /// Returns nil for a command that is empty after flattening.
    public static func formatHistoryLine(epoch: Int, command: String) -> String? {
        let flattened = command
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !flattened.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return ": \(epoch):0;\(flattened)"
    }

    /// The start-of-shell trim: over `threshold` lines → keep the last `keep`.
    public static func trimmedHistory(lines: [String], threshold: Int = trimThreshold,
                                      keep: Int = trimKeep) -> [String] {
        guard lines.count > threshold else { return lines }
        return Array(lines.suffix(keep))
    }

    /// v3 freeze-before-trim mirror: what the .zshrc trim keeps live and
    /// what it rolls into the sidecar. `rolled` is empty when under the
    /// threshold; kept + rolled always partition the input losslessly.
    public static func trimHistory(lines: [String], threshold: Int = trimThreshold,
                                   keep: Int = trimKeep) -> (kept: [String], rolled: [String]) {
        guard lines.count > threshold else { return (lines, []) }
        return (Array(lines.suffix(keep)), Array(lines.dropLast(keep)))
    }

    // MARK: - Child environment

    /// Environment entries ("KEY=value") for a zsh pane with integration on.
    /// `base` is the default spawn environment (the app passes SwiftTerm's
    /// `Terminal.getEnvironmentVariables()`, which is exactly what a nil
    /// environment would have produced — integration only ADDS to it).
    /// `userZdotdir` is memterm's own $ZDOTDIR if set, else $HOME.
    public static func environment(base: [String], paneId: String, histDir: String,
                                   userZdotdir: String, integrationDir: String) -> [String] {
        let ours = ["MEMTERM_PANE_ID", "MEMTERM_HIST_DIR", "MEMTERM_USER_ZDOTDIR", "ZDOTDIR"]
        var env = base.filter { entry in
            !ours.contains { entry.hasPrefix("\($0)=") }
        }
        env.append("MEMTERM_PANE_ID=\(paneId)")
        env.append("MEMTERM_HIST_DIR=\(histDir)")
        env.append("MEMTERM_USER_ZDOTDIR=\(userZdotdir)")
        env.append("ZDOTDIR=\(integrationDir)")
        return env
    }

    // MARK: - Integration file contents

    private static var header: String {
        "# memterm shell integration v\(version) — regenerated at every app launch; do not edit."
    }

    /// $ZDOTDIR/.zshenv: source the user's real .zshenv with ZDOTDIR restored
    /// around it. Their .zshenv may itself change ZDOTDIR (custom setups) —
    /// whatever it leaves is where their remaining startup files live, so it
    /// is captured back into MEMTERM_USER_ZDOTDIR.
    public static var zshenvContent: String { """
    \(header)
    typeset -g _memterm_zdotdir="${ZDOTDIR:-}"
    ZDOTDIR="${MEMTERM_USER_ZDOTDIR:-$HOME}"
    [[ -f "$ZDOTDIR/.zshenv" ]] && builtin source "$ZDOTDIR/.zshenv"
    export MEMTERM_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
    ZDOTDIR="$_memterm_zdotdir"
    unset _memterm_zdotdir

    """ }

    /// $ZDOTDIR/.zprofile: memterm spawns login shells ("-zsh"), so the
    /// user's .zprofile must be forwarded too (PATH setup lives there for
    /// many setups; /etc/zprofile's path_helper already ran before this).
    public static var zprofileContent: String { """
    \(header)
    typeset -g _memterm_zdotdir="${ZDOTDIR:-}"
    ZDOTDIR="${MEMTERM_USER_ZDOTDIR:-$HOME}"
    [[ -f "$ZDOTDIR/.zprofile" ]] && builtin source "$ZDOTDIR/.zprofile"
    ZDOTDIR="$_memterm_zdotdir"
    unset _memterm_zdotdir

    """ }

    /// $ZDOTDIR/.zshrc: source the user's real .zshrc (errors in THEIR rc
    /// abort only their file — verified), restore ZDOTDIR (unset when the
    /// user had none, so .zlogin and the pane's world look pristine), THEN
    /// install the memterm hooks via add-zsh-hook.
    public static var zshrcContent: String { """
    \(header)
    # /etc/zshrc (which ran just before this file) defaults
    # HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history — with ZDOTDIR still pointing at
    # the integration dir here, that would hijack the user's GLOBAL history
    # into memterm's state dir. Repair it to what a wrapper-less shell would
    # have gotten; anything the user's own files set (before or after) wins
    # untouched, because only the exact hijacked value is rewritten.
    if [[ "${HISTFILE:-}" == "$ZDOTDIR/.zsh_history" ]]; then
      HISTFILE="${MEMTERM_USER_ZDOTDIR:-$HOME}/.zsh_history"
    fi
    ZDOTDIR="${MEMTERM_USER_ZDOTDIR:-$HOME}"
    [[ -f "$ZDOTDIR/.zshrc" ]] && builtin source "$ZDOTDIR/.zshrc"
    if [[ "$ZDOTDIR" == "$HOME" ]]; then unset ZDOTDIR; fi

    # ---- memterm hooks (after the user's rc; add-zsh-hook coexists with
    # oh-my-zsh / powerlevel10k and with user-defined precmd()/preexec()) ----
    if [[ -n "$MEMTERM_PANE_ID" && -n "$MEMTERM_HIST_DIR" && -d "$MEMTERM_HIST_DIR" ]]; then
      autoload -Uz add-zsh-hook
      zmodload zsh/datetime 2>/dev/null
      typeset -g _memterm_hist_file="$MEMTERM_HIST_DIR/${MEMTERM_PANE_ID//[^A-Za-z0-9-]/_}.hist"
      if [[ ! -f "$_memterm_hist_file" ]]; then
        # Create 0600 up front — zsh's append would use the umask otherwise.
        : >| "$_memterm_hist_file" 2>/dev/null && command chmod 600 "$_memterm_hist_file" 2>/dev/null
      elif (( $(command wc -l < "$_memterm_hist_file" 2>/dev/null || echo 0) > \(trimThreshold) )); then
        # Start-of-shell trim keeps preexec cheap (one entry = one line).
        # v3 freeze-before-trim (FR-56 amended): the head lines ROLL into the
        # .trimmed sidecar (0600, archives with the session) FIRST, and the
        # trim only runs when the roll landed — trimming never discards.
        typeset -gi _memterm_hist_total=$(command wc -l < "$_memterm_hist_file" 2>/dev/null || echo 0)
        if command head -n $(( _memterm_hist_total - \(trimKeep) )) "$_memterm_hist_file" >>| "$_memterm_hist_file.trimmed" 2>/dev/null; then
          command chmod 600 "$_memterm_hist_file.trimmed" 2>/dev/null
          command tail -n \(trimKeep) "$_memterm_hist_file" >| "$_memterm_hist_file.tmp" 2>/dev/null \\
            && command mv "$_memterm_hist_file.tmp" "$_memterm_hist_file"
        fi
        unset _memterm_hist_total
      fi
      _memterm_preexec() {
        # Extended-history line per command; newlines flattened so one entry
        # is one line. OSC 133 C marks command-output start (FR-5/6).
        local cmd="${1//$'\\n'/ }"
        cmd="${cmd//$'\\r'/ }"
        [[ -n "$cmd" ]] && print -r -- ": ${EPOCHSECONDS:-$(command date +%s)}:0;${cmd}" >>| "$_memterm_hist_file" 2>/dev/null
        printf '\\e]133;C\\a'
      }
      _memterm_seed() {
        # One-shot, at the FIRST prompt: global $HISTFILE is loaded after
        # .zshrc but before the first precmd (verified), so seeding here puts
        # this tab's commands newest — ↑ walks them first. Never at rc end.
        add-zsh-hook -d precmd _memterm_seed
        [[ -s "$_memterm_hist_file" ]] && builtin fc -R "$_memterm_hist_file" 2>/dev/null
      }
      _memterm_precmd() { printf '\\e]133;D\\a\\e]133;A\\a' }
      _memterm_report_cwd() { printf '\\e]7;file://%s%s\\a' "${HOST:-localhost}" "${PWD// /%20}" }
      add-zsh-hook preexec _memterm_preexec
      add-zsh-hook precmd _memterm_seed
      add-zsh-hook precmd _memterm_precmd
      add-zsh-hook chpwd _memterm_report_cwd
      _memterm_report_cwd
    fi

    """ }

    /// The (fileName, content) set the app writes into the integration dir.
    public static var files: [(name: String, content: String)] {
        [(".zshenv", zshenvContent), (".zprofile", zprofileContent), (".zshrc", zshrcContent)]
    }

    /// Writes/refreshes the integration files. Returns true only when every
    /// file landed — the caller must NOT point ZDOTDIR at a half-written dir
    /// (a missing .zshrc there would silently skip the user's rc).
    @discardableResult
    public static func install(into dir: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for file in files {
                let url = dir.appendingPathComponent(file.name)
                try file.content.write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            // v1 wrote no HISTFILE repair, so shells hijacked by /etc/zshrc
            // saved GLOBAL history into this dir. Remove the stray file: its
            // entries all came from memterm panes (only they use this
            // ZDOTDIR), so each is already captured in that pane's .hist —
            // and an untracked history file in the state dir would outlive
            // every FR-56/57 forget gesture.
            try? fm.removeItem(at: dir.appendingPathComponent(".zsh_history"))
            return true
        } catch {
            return false
        }
    }
}
