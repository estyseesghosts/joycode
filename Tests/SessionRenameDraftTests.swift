import Foundation
import XCTest
@testable import Joycode

// MARK: - SessionRenameDraft value-model tests

final class SessionRenameDraftTests: XCTestCase {

    // MARK: - Initialization

    // 1. Initial state is clean and text matches authoritative
    func testInitialStateIsCleanAndMatchesAuthoritative() {
        let draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Original")
        XCTAssertEqual(draft.sessionID, "ses-1")
        XCTAssertEqual(draft.authoritativeTitle, "Original")
        XCTAssertEqual(draft.text, "Original")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // MARK: - Clean same-id updates

    // 2. Clean draft follows authoritative title change for same session
    func testCleanDraftFollowsAuthoritativeTitleChangeForSameSession() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "New")
        XCTAssertEqual(result, .followed)
        XCTAssertEqual(draft.text, "New")
        XCTAssertEqual(draft.authoritativeTitle, "New")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 3. Sync with unchanged title returns .unchanged
    func testSyncWithUnchangedTitleReturnsUnchanged() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Same")
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "Same")
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(draft.text, "Same")
    }

    // 4. Clean draft follows multiple successive title changes
    func testCleanDraftFollowsMultipleTitleChanges() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "V1")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "V2")
        XCTAssertEqual(draft.text, "V2")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "V3")
        XCTAssertEqual(draft.text, "V3")
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - Dirty changes and conflict

    // 5. Dirty draft + authoritative title change → conflict exposed
    func testDirtyDraftAndAuthoritativeTitleChangeExposesConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        XCTAssertTrue(draft.isDirty)

        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(draft.conflict, SessionRenameDraft.Conflict(serverTitle: "Server Updated"))
        // Draft text and dirty state preserved
        XCTAssertEqual(draft.text, "My Edit")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.authoritativeTitle, "Server Updated")
    }

    // 6. Dirty draft + same authoritative title → no conflict
    func testDirtyDraftWithUnchangedTitleDoesNotConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Same")
        draft.editText("My Edit")
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "Same")
        XCTAssertEqual(result, .unchanged)
        XCTAssertNil(draft.conflict)
    }

    // 7. Edit back to authoritative clears dirty flag
    func testEditBackToAuthoritativeClearsDirtyFlag() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("Changed")
        XCTAssertTrue(draft.isDirty)
        draft.editText("Title")
        XCTAssertFalse(draft.isDirty)
    }

    // 8. Edit with whitespace-trimmed match clears dirty flag
    func testEditWithWhitespaceTrimmedMatchClearsDirtyFlag() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("  Title  \n")
        XCTAssertFalse(draft.isDirty, "Whitespace-trimmed match should clear dirty")
    }

    // 9. Conflict resolution: accept server
    func testAcceptServerResolvesConflictAndBecomesClean() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)

        draft.acceptServer()
        XCTAssertEqual(draft.text, "Server Updated")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
        XCTAssertEqual(draft.authoritativeTitle, "Server Updated")
    }

    // 10. Conflict resolution: keep edit
    func testKeepEditDismissesConflictAndPreservesDirty() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)

        draft.keepEdit()
        XCTAssertEqual(draft.text, "My Edit")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.conflict, "Conflict should be dismissed")
    }

    // MARK: - Identity reset

    // 11. Identity change resets draft regardless of clean state
    func testIdentityChangeResetsCleanDraft() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title 1")
        let result = draft.sync(sessionID: "ses-2", authoritativeTitle: "Title 2")
        XCTAssertEqual(result, .identityReset)
        XCTAssertEqual(draft.sessionID, "ses-2")
        XCTAssertEqual(draft.text, "Title 2")
        XCTAssertEqual(draft.authoritativeTitle, "Title 2")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 12. Identity change resets draft even when dirty
    func testIdentityChangeResetsDirtyDraft() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title 1")
        draft.editText("My Edit")
        XCTAssertTrue(draft.isDirty)

        let result = draft.sync(sessionID: "ses-2", authoritativeTitle: "Title 2")
        XCTAssertEqual(result, .identityReset)
        XCTAssertEqual(draft.sessionID, "ses-2")
        XCTAssertEqual(draft.text, "Title 2")
        XCTAssertFalse(draft.isDirty)
    }

    // 13. Identity change resets draft even when in conflict
    func testIdentityChangeResolvesConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Changed")
        XCTAssertNotNil(draft.conflict)

        draft.sync(sessionID: "ses-2", authoritativeTitle: "Other")
        XCTAssertNil(draft.conflict)
        XCTAssertFalse(draft.isDirty)
    }

    // 14. Identity change to empty string (session cleared)
    func testIdentityChangeToEmptyResetsDraft() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("Dirty")
        draft.sync(sessionID: "", authoritativeTitle: "")
        XCTAssertEqual(draft.sessionID, "")
        XCTAssertEqual(draft.text, "")
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - Own confirmation

    // 15. confirmRename makes draft clean with new title
    func testConfirmRenameMakesDraftCleanWithNewTitle() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("New")
        XCTAssertTrue(draft.isDirty)

        draft.confirmRename(newTitle: "New")
        XCTAssertEqual(draft.text, "New")
        XCTAssertEqual(draft.authoritativeTitle, "New")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 16. confirmRename clears any pending conflict
    func testConfirmRenameClearsConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Changed")
        XCTAssertNotNil(draft.conflict)

        draft.confirmRename(newTitle: "My Edit")
        XCTAssertNil(draft.conflict)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.text, "My Edit")
    }

    // 17. confirmRename is idempotent on a clean draft
    func testConfirmRenameIdempotentOnCleanDraft() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.confirmRename(newTitle: "Title")
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.text, "Title")
    }

    // MARK: - Escape / revert

    // 18. revert restores text to authoritative and clears dirty
    func testRevertRestoresTextAndClearsDirty() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Original")
        draft.editText("Something else")
        XCTAssertTrue(draft.isDirty)

        draft.revert()
        XCTAssertEqual(draft.text, "Original")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 19. revert clears conflict
    func testRevertClearsConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)

        draft.revert()
        XCTAssertEqual(draft.text, "Server Updated")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 20. revert on already-clean draft is a no-op
    func testRevertOnCleanDraftIsNoop() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.revert()
        XCTAssertEqual(draft.text, "Title")
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - No-op / blank eligibility

    // 21. blank text is not eligible
    func testBlankTextIsNotEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("")
        XCTAssertFalse(draft.isEligible)
    }

    // 22. whitespace-only text is not eligible
    func testWhitespaceOnlyTextIsNotEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("   \n  ")
        XCTAssertFalse(draft.isEligible)
    }

    // 23. text equal to authoritative title is not eligible (no-op)
    func testTextEqualToAuthoritativeIsNotEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Same")
        draft.editText("Same")
        XCTAssertFalse(draft.isEligible)
    }

    // 24. text equal to authoritative after trimming is not eligible
    func testTextEqualToAuthoritativeAfterTrimmingIsNotEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        draft.editText("  Title  ")
        XCTAssertFalse(draft.isEligible)
    }

    // 25. different non-blank text is eligible
    func testDifferentNonblankTextIsEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("New")
        XCTAssertTrue(draft.isEligible)
    }

    // 26. initial clean draft is not eligible (text matches authoritative)
    func testInitialCleanDraftIsNotEligible() {
        let draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Title")
        XCTAssertFalse(draft.isEligible, "Clean draft matching authoritative is a no-op")
    }

    // 27. unresolved conflict disables eligibility (Finding 1)
    func testUnresolvedConflictDisablesEligibility() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)
        // Even though text differs from authoritative, conflict blocks submission
        XCTAssertFalse(draft.isEligible, "Unresolved conflict must block submission")
    }

    // 28. eligibility restored after accept server (Finding 1 follow-up)
    func testEligibilityRestoredAfterAcceptServerWhenTextDiffers() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertFalse(draft.isEligible, "Conflict blocks eligibility")

        draft.acceptServer()
        // Text is now "Server Updated" == authoritative → no-op
        XCTAssertFalse(draft.isEligible, "acceptServer makes text == authoritative")
    }

    // 29. eligibility restored after keep edit when text differs from authoritative
    func testEligibilityRestoredAfterKeepEditWhenTextDiffers() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertFalse(draft.isEligible)

        draft.keepEdit()
        XCTAssertTrue(draft.isEligible, "keepEdit: conflict cleared, text differs from authoritative")
    }

    // MARK: - Regression: matching authoritative confirmation after unknown (Finding 2)

    // 30. Dirty text whose trimmed value matches new authoritative becomes clean
    func testSyncDirtyTextMatchingNewAuthoritativeBecomesClean() {
        // Simulates: user typed "New", rename was unknown, checkRename confirms
        // the server title is now "New" — draft should auto-clean.
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("New")
        XCTAssertTrue(draft.isDirty)

        // Server confirms the title is "New" (matching user's edit)
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "New")
        XCTAssertEqual(result, .followed, "Matching dirty text should auto-clean, not conflict")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
        XCTAssertEqual(draft.text, "New")
    }

    // 31. Dirty text matching new authoritative with whitespace also auto-cleans
    func testSyncDirtyTextTrimmedMatchingNewAuthoritativeBecomesClean() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("  New  ")
        XCTAssertTrue(draft.isDirty)

        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "New")
        XCTAssertEqual(result, .followed)
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
        XCTAssertEqual(draft.text, "New")
    }

    // MARK: - Regression: editing to authoritative clears stale conflict (Finding 2)

    // 32. editText back to authoritative clears stale conflict
    func testEditTextBackToAuthoritativeClearsStaleConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)
        XCTAssertTrue(draft.isDirty)

        // User edits text back to the current authoritative title
        draft.editText("Server Updated")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict, "Editing back to authoritative must clear stale conflict")
    }

    // 33. editText to whitespace-trimmed authoritative clears stale conflict
    func testEditTextToTrimmedAuthoritativeClearsStaleConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertNotNil(draft.conflict)

        draft.editText("  Server Updated  ")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict, "Trimmed match must clear stale conflict")
    }

    // MARK: - Regression: canceled rename preserves draft (Finding 3)

    // 34. Canceled rename (identity unchanged, title unchanged) preserves draft
    func testCanceledRenamePreservesDraft() {
        // Simulates: user typed "New", rename was submitted, then canceled.
        // Store reverts to original title (no change from draft's perspective).
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Original")
        draft.editText("New")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.text, "New")

        // Canceled rename: store state goes back to idle, title stays "Original"
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Original")
        // Text should be preserved — dirty state unchanged
        XCTAssertEqual(draft.text, "New")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // 35. Canceled rename with external title change shows conflict
    func testCanceledRenameWithExternalTitleChangeShowsConflict() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Original")
        draft.editText("New")

        // External change while rename was in flight
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "External Change")
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(draft.text, "New")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNotNil(draft.conflict)
        XCTAssertEqual(draft.conflict?.serverTitle, "External Change")
    }

    // MARK: - Regression: identity changes always sync (Finding 3)

    // 36. Identity change during dirty+conflict state always syncs
    func testIdentityChangeDuringDirtyConflictAlwaysSyncs() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Changed")
        XCTAssertNotNil(draft.conflict)
        XCTAssertTrue(draft.isDirty)

        // Identity change must always sync, even during conflict
        let result = draft.sync(sessionID: "ses-2", authoritativeTitle: "Other Session")
        XCTAssertEqual(result, .identityReset)
        XCTAssertEqual(draft.sessionID, "ses-2")
        XCTAssertEqual(draft.text, "Other Session")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    // MARK: - Regression: unresolved conflict disables submit (Finding 1 / Finding 4)

    // 37. Conflict + different text → not eligible (submit disabled)
    func testConflictWithDifferentTextDisablesSubmit() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertFalse(draft.isEligible, "Must resolve conflict before submitting")
    }

    // 38. After keepEdit + text differs from authoritative → eligible
    func testAfterKeepEditTextDiffersFromAuthoritativeIsEligible() {
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Server")
        draft.editText("My Edit")
        draft.sync(sessionID: "ses-1", authoritativeTitle: "Server Updated")
        XCTAssertFalse(draft.isEligible)

        draft.keepEdit()
        XCTAssertTrue(draft.isEligible)
        XCTAssertEqual(draft.text, "My Edit")
    }

    // MARK: - Regression: own rename auto-clean via sync (Finding 3)

    // 39. Own rename's authoritative title matching dirty text auto-cleans
    func testOwnRenameAuthoritativeMatchingDirtyTextAutoCleans() {
        // Simulates: user typed "New", rename succeeded (authoritative becomes "New").
        // With always-sync, the sync auto-cleans because dirty text matches.
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("New")
        XCTAssertTrue(draft.isDirty)

        // Store publishes authoritative "New" (our rename applied)
        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "New")
        XCTAssertEqual(result, .followed, "Own rename: dirty text matching new authoritative auto-cleans")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
        XCTAssertEqual(draft.text, "New")
    }

    // 40. Own rename with non-matching authoritative shows conflict
    func testOwnRenameNonMatchingAuthoritativeShowsConflict() {
        // Simulates: user typed "New", but another rename happened concurrently
        // and the authoritative title is now "Different".
        var draft = SessionRenameDraft(sessionID: "ses-1", authoritativeTitle: "Old")
        draft.editText("New")

        let result = draft.sync(sessionID: "ses-1", authoritativeTitle: "Different")
        XCTAssertEqual(result, .conflict)
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.text, "New")
        XCTAssertEqual(draft.conflict?.serverTitle, "Different")
    }
}