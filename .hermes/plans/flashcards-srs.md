# Flashcards + Spaced Repetition — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add flashcard + SM-2 spaced repetition to HermesNative alongside existing multiple-choice quiz.

**Architecture:** SRS is a peer to the quiz system, not a fork. Shared sheet, mode toggle, separate data models and services. Cards self-grade with "Knew it" / "Almost" / "Didn't know". SM-2 engine computes intervals. Decks persist as JSON across sessions.

**Tech Stack:** SwiftUI, Swift 6, macOS 14+ / iOS 17+, no new dependencies.

---

### Task 1: Create Flashcard models (`Models/Quiz/FlashcardModels.swift`)

**Files:**
- Create: `Sources/HermesNative/Models/Quiz/FlashcardModels.swift`

### Task 2: Build SM-2 spaced repetition engine (`Services/SRSEngine.swift`)

**Files:**
- Create: `Sources/HermesNative/Services/SRSEngine.swift`

### Task 3: Build SRS persistence store (`Services/SRSStore.swift`)

**Files:**
- Create: `Sources/HermesNative/Services/SRSStore.swift`

### Task 4: Build Flashcard card view (`Views/Quiz/FlashcardView.swift`)

**Files:**
- Create: `Sources/HermesNative/Views/Quiz/FlashcardView.swift`

### Task 5: Build Flashcard deck view (`Views/Quiz/FlashcardDeckView.swift`)

**Files:**
- Create: `Sources/HermesNative/Views/Quiz/FlashcardDeckView.swift`

### Task 6: Extend QuizViewModel with flashcard mode

**Files:**
- Modify: `Sources/HermesNative/ViewModels/Quiz/QuizViewModel.swift`

### Task 7: Add mode selector to QuizSheet

**Files:**
- Modify: `Sources/HermesNative/Views/Quiz/QuizSheet.swift`

### Task 8: Wire agent-side flashcard detection in ChatViewModel

**Files:**
- Modify: `Sources/HermesNative/ViewModels/ChatViewModel.swift`

### Task 9: Build SRS Dashboard view

**Files:**
- Create: `Sources/HermesNative/Views/Quiz/SRSDashboardView.swift`

### Task 10: Build & verify

**Files:**
- Run: `cd ~/projects/HermesNative && xcodegen generate && xcodebuild -scheme HermesNative-macOS -destination 'platform=macOS' build 2>&1 | tail -20`