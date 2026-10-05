import Foundation

/// Value model tracking the rename draft's identity, text, and sync state
/// with the authoritative session title. Extracted for testability; the
/// view layer owns busy-state gating and conflict UI presentation.
struct SessionRenameDraft: Equatable {
    /// Current session identity (raw ID string).
    var sessionID: String

    /// The authoritative title for the current session (from the store).
    private(set) var authoritativeTitle: String

    /// The current draft text (what the user sees/edits).
    private(set) var text: String

    /// True when the user has manually changed text away from `authoritativeTitle`.
    private(set) var isDirty: Bool

    /// Non-nil when the authoritative title changed while the draft was dirty.
    /// Contains the new server title so the view can offer a conflict choice.
    private(set) var conflict: Conflict?

    struct Conflict: Equatable {
        let serverTitle: String
    }

    // MARK: - Initialization

    /// Creates a clean draft synchronised to the given authoritative title.
    init(sessionID: String, authoritativeTitle: String) {
        self.sessionID = sessionID
        self.authoritativeTitle = authoritativeTitle
        self.text = authoritativeTitle
        self.isDirty = false
        self.conflict = nil
    }

    // MARK: - Sync with authoritative source

    enum SyncResult: Equatable {
        /// Session identity changed — draft fully reset.
        case identityReset
        /// Same session, same title — no change needed.
        case unchanged
        /// Same session, clean draft, title changed — draft followed.
        case followed
        /// Same session, dirty draft, title changed — conflict exposed.
        case conflict
    }

    /// Reconcile the draft with the current store state. Call when the store's
    /// active session may have changed (external refresh, load, etc.).
    @discardableResult
    mutating func sync(sessionID newID: String, authoritativeTitle newTitle: String) -> SyncResult {
        // Identity changed → full reset
        if newID != sessionID {
            sessionID = newID
            authoritativeTitle = newTitle
            text = newTitle
            isDirty = false
            conflict = nil
            return .identityReset
        }

        // Same session, title unchanged
        if newTitle == authoritativeTitle {
            return .unchanged
        }

        // Same session, title changed
        authoritativeTitle = newTitle
        if isDirty {
            // If dirty text's trimmed value matches new authoritative title,
            // the draft is effectively clean (e.g. checkRename confirming an
            // earlier unknown, or the user's edit landing on the server value).
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText == newTitle {
                text = newTitle
                isDirty = false
                conflict = nil
                return .followed
            }
            // Dirty → conflict: expose server title for explicit choice
            conflict = Conflict(serverTitle: newTitle)
            return .conflict
        } else {
            // Clean → follow authoritative
            text = newTitle
            conflict = nil
            return .followed
        }
    }

    // MARK: - User edits

    /// User modified the draft text.
    mutating func editText(_ newText: String) {
        text = newText
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        isDirty = trimmed != authoritativeTitle
        // If the user edited back to the authoritative title (or trimmed
        // equivalent), clear any stale conflict — no divergence remains.
        if !isDirty {
            conflict = nil
        }
    }

    // MARK: - Conflict resolution

    /// Accept the server's new title (discard user edit).
    mutating func acceptServer() {
        text = authoritativeTitle
        isDirty = false
        conflict = nil
    }

    /// Keep the user's current edit (dismiss conflict notification).
    mutating func keepEdit() {
        conflict = nil
    }

    // MARK: - Actions

    /// After a successful own-rename completes the draft becomes clean
    /// and reflects the new authoritative title.
    mutating func confirmRename(newTitle: String) {
        authoritativeTitle = newTitle
        text = newTitle
        isDirty = false
        conflict = nil
    }

    /// Revert to authoritative title (Escape key).
    mutating func revert() {
        text = authoritativeTitle
        isDirty = false
        conflict = nil
    }

    // MARK: - Eligibility

    /// Whether the current text is a valid rename submission (not blank,
    /// not no-op, no unresolved conflict). Does NOT consider busy state —
    /// that is the view's concern.
    var isEligible: Bool {
        guard conflict == nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != authoritativeTitle else { return false }
        return true
    }
}