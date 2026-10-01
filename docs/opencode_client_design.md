# OpenCode Client — Design Implementation Specification

## Abstract

This document defines the visual and interaction design for the OpenCode macOS client shown in the approved mockups.

The interface is built around one central idea:

> **The application does not look like a normal desktop window with controls placed inside a large rectangular shell.**

Instead, the application is composed of a **main workframe** with smaller **floating controls orbiting around it**.

The main workframe is the largest visual surface. It contains the active conversation, code, plans, diffs, terminal output, agent activity, search results, and other working content.

Navigation, project controls, session controls, attachment controls, and message controls exist as independent floating bubbles around the workframe.

There are two primary layouts:

1. **Compact View**
   - Horizontal project/session navigation.
   - Intended for smaller windows and focused use.
   - Navigation is arranged in one horizontal row above the workframe.

2. **Detailed View**
   - Vertical project/session navigation.
   - Intended for larger windows and multi-session work.
   - Projects form a vertical floating stack to the left of the workframe.
   - Sessions belonging to each project appear directly below that project.

The two layouts must use the same component language, spacing system, corner treatment, interaction rules, and workframe.

The implementation should use **SwiftUI for the majority of the interface**, with **custom SwiftUI components for every important visual element**. AppKit should be used only where SwiftUI does not provide sufficient control over the macOS window itself, especially for the transparent, non-standard application chrome and floating-window behavior.

---

# 1. Design Principles

## 1.1 The Workframe Is the Center of the Interface

The workframe is the primary visual object.

It is:

- large;
- rounded;
- visually stable;
- centered within the available working area;
- the only major continuous surface;
- responsible for displaying the active OpenCode session.

Everything else should visually appear secondary to it.

The interface should not look like:

```text
┌─────────────────────────────────────────────────────────┐
│ toolbar                                                 │
│ ┌────────────┐ ┌──────────────────────────────────────┐ │
│ │ sidebar    │ │ content                              │ │
│ │            │ │                                      │ │
│ └────────────┘ └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

It should behave more like:

```text
      [ floating controls ]   [ project ]   [ session ]

                  ╭──────────────────────╮
                  │                      │
                  │      WORKFRAME       │
                  │                      │
                  ╰──────────────────────╯

          (attach) [     message field     ] (send)
```

The empty area around these elements is intentional.

There must not be a visible full-size background panel connecting them.

---

## 1.2 Floating Components Must Still Feel Ordered

"Floating" does not mean arbitrary placement.

Every floating element must follow:

- a shared spacing grid;
- aligned baselines;
- predictable margins;
- consistent corner radii;
- consistent minimum heights;
- consistent shadows;
- clear parent/child relationships.

The interface should feel structurally precise even though the controls are visually detached.

---

## 1.3 One Control Per Action

Do not duplicate actions.

Examples:

- one attachment button;
- one new-session control;
- one sidebar toggle;
- one send button;
- one close control per session;
- one project expansion control.

Do not provide both:

- a paperclip and a second `+` button for attachments;
- multiple ways to create the same session in the same region;
- duplicated close buttons inside and outside the same session bubble.

---

## 1.4 Visual Hierarchy

The visual hierarchy should be:

1. Active workframe.
2. Active project.
3. Active session.
4. Other projects.
5. Other sessions.
6. Secondary actions.
7. Window-level controls.

The selected project and selected session should be visible immediately without needing strong color.

Use:

- fill contrast;
- weight;
- elevation;
- subtle border changes;
- text weight.

Do not depend only on color.

---

# 2. Implementation Direction

## 2.1 Preferred Architecture

Use a **hybrid SwiftUI + AppKit approach**.

### SwiftUI should implement

- project bubbles;
- session bubbles;
- toolbar bubbles;
- message input;
- attachment button;
- send button;
- sidebar;
- workframe content;
- conversation rows;
- code blocks;
- diff views;
- plan/task views;
- terminal cards;
- search results;
- layout switching;
- hover states;
- animation;
- drag and drop;
- menus;
- focus handling where practical.

### AppKit should implement or assist with

- the actual macOS window configuration;
- removal of conventional titlebar chrome;
- transparent window background;
- traffic-light positioning if the native controls are retained;
- window dragging regions;
- advanced pointer/hover behavior if SwiftUI becomes limiting;
- text editor integration if a native `NSTextView` becomes necessary;
- advanced code-editor functionality if SwiftUI text rendering is insufficient.

The design does **not** require separate `NSWindow` instances for every floating control.

The visual elements should normally remain inside one application window and simply render against a transparent root background.

This avoids:

- difficult focus handling;
- z-order problems;
- multiple-window movement bugs;
- accessibility fragmentation;
- unnecessary AppKit complexity.

---

## 2.2 Root Window

The application window should behave as one transparent canvas.

Recommended properties:

- transparent or visually empty root background;
- hidden standard titlebar;
- standard resize behavior;
- standard minimize/maximize behavior;
- traffic lights retained where possible;
- no opaque full-window content background;
- no toolbar strip spanning the window;
- no permanent sidebar background.

The user should visually perceive:

```text
desktop/background
        ↓
floating controls
        ↓
main workframe
        ↓
floating input controls
```

not:

```text
desktop
        ↓
large application rectangle
        ↓
controls inside application rectangle
```

---

## 2.3 Custom Components

The important visual components should be custom SwiftUI components rather than stock controls with minor styling.

Core reusable components should include:

- `FloatingBubble`
- `CircularBubbleButton`
- `ProjectBubble`
- `SessionBubble`
- `CloseBubble`
- `SidebarToggleBubble`
- `AttachmentBubble`
- `SendBubble`
- `FloatingInputField`
- `Workframe`
- `WorkframeHeader`
- `ProjectStack`
- `HorizontalProjectStrip`
- `AgentMessage`
- `UserMessage`
- `CodeCard`
- `DiffCard`
- `TaskPlanCard`
- `TerminalCard`
- `SearchResultCard`

The goal is visual consistency, not use of standard macOS component appearance.

---

# 3. Common Elements

## 3.1 Shared Shape Language

All major controls use:

- rounded pills;
- rounded rectangles;
- circles;
- large corner radii;
- little or no hard-edged geometry.

### Pill controls

Use for:

- project bubbles;
- session bubbles;
- new-project controls;
- text fields;
- compact navigation tabs.

### Circular controls

Use for:

- close buttons;
- attachment;
- send;
- sidebar toggle;
- new session where appropriate;
- icon-only actions.

### Rounded large rectangles

Use for:

- main workframe;
- code cards;
- task cards;
- search cards;
- diff cards.

---

## 3.2 Corner Radius

Use a small number of radius families.

Suggested visual hierarchy:

- **workframe:** large radius;
- **major cards:** medium-large radius;
- **project/session pills:** capsule or near-capsule;
- **circular controls:** true circles.

The exact values can scale with interface density.

The important rule is that the interface must look like one system.

---

## 3.3 Padding

Padding must remain consistent across both layouts.

Recommended conceptual spacing units:

- **XS:** close spacing inside icon controls;
- **S:** internal control padding;
- **M:** space between adjacent floating controls;
- **L:** space between control groups and the workframe;
- **XL:** outer breathing room.

Do not manually tune every component independently.

Use shared spacing constants.

---

## 3.4 Shadows and Elevation

Floating elements need visible separation from the background.

Use:

- soft shadow;
- low opacity;
- broad blur;
- small vertical offset.

Avoid:

- hard black shadows;
- thick outlines;
- excessive glass effects.

The workframe may use slightly more elevation than small bubbles.

Selected bubbles may also gain slightly more elevation.

---

## 3.5 Borders

Borders should be subtle.

Use them only to:

- preserve shape on bright backgrounds;
- distinguish overlapping light surfaces;
- indicate focus;
- indicate hover or selection.

Do not use strong permanent outlines.

---

## 3.6 Color

Color is secondary to shape.

The interface must work in:

- light themes;
- dark themes;
- tinted themes;
- user-selected accent colors.

Project icons may use color to improve identification, but text and hierarchy must remain readable without it.

The original bright-blue sketches are shape references, not a required palette.

---

## 3.7 Typography

Use the standard macOS text hierarchy as a starting point, but with carefully controlled sizes.

Recommended categories:

- project/session title;
- workframe title;
- body conversation text;
- metadata;
- timestamps;
- code;
- secondary descriptions.

Do not make the UI typography too small.

The floating layout already reduces visual clutter. It does not need unusually dense text.

---

# 4. Window-Level Controls

## 4.1 Traffic Lights

The macOS traffic lights may remain visible.

They should appear as their own small floating control cluster.

They must not sit inside a full-width titlebar.

Example:

```text
( ● ● ● )   (sidebar)
```

The control cluster should align with the navigation system.

In compact view, it belongs at the start of the horizontal navigation row.

In detailed view, it belongs above the vertical project stack.

---

## 4.2 Sidebar Toggle

The sidebar toggle is a separate circular or compact rounded bubble.

It controls whether the detailed project stack is visible.

### Function

- click: show/hide detailed sidebar;
- keyboard shortcut: supported;
- animated transition between visible and hidden states.

It must not be embedded inside the main workframe.

---

# 5. Main Workframe

## 5.1 General Form

The workframe is a large rounded rectangle.

It should remain visually consistent between compact and detailed layouts.

It contains:

- active session header;
- conversation;
- code;
- tool use;
- plans;
- agent activity;
- file views;
- search;
- terminal output.

Its content may be complex.

Its outside silhouette should remain simple.

---

## 5.2 Workframe Header

The header should include only session-specific information.

Typical order:

```text
[session icon]  Session Name                   Project Name  [...]
```

Possible contents:

- active session title;
- project name;
- lightweight status;
- overflow menu.

Do not place global project navigation here.

The project navigation already exists outside the workframe.

---

## 5.3 Scrolling

The workframe content scrolls vertically.

The workframe itself should remain stationary.

The floating input row remains below the workframe rather than becoming part of the conversation scroll.

---

## 5.4 Content Types

The workframe should support rich OpenCode-specific content.

Examples:

- normal assistant response;
- user message;
- plan;
- todo/task list;
- code block;
- unified or split diff;
- terminal output;
- subagent status;
- tool execution status;
- file result;
- search result;
- diagnostic output;
- structured error;
- permission request.

These should appear as consistent internal cards, not as new floating exterior windows.

---

# 6. Message Input Area

## 6.1 Layout

The message controls always follow the same order:

```text
( attachment )  [            input field            ]  ( send )
```

This applies to both compact and detailed views.

---

## 6.2 Attachment Button

The attachment control is a single circular bubble immediately to the left of the message field.

It should open:

- file picker;
- image picker if supported;
- recent attachments;
- drag/drop attachment state.

Do not add another plus button for the same function.

---

## 6.3 Input Field

The input field is a long floating pill.

It should support:

- multiline expansion;
- keyboard focus;
- command completion;
- optional slash commands;
- drag/drop;
- pasting files;
- rich text only if needed later.

It should visually remain one continuous object.

The field can grow vertically up to a defined maximum before its text scrolls internally.

---

## 6.4 Send Button

The send button is a circular bubble to the right.

States:

- ready;
- disabled;
- sending;
- stop/cancel while agent is running if the same control is reused.

The design should avoid adding a second stop button unless required by workflow.

A state transformation is preferable:

```text
send → running → stop
```

---

# 7. Common Project and Session Model

The layouts differ, but they represent the same hierarchy:

```text
Project
├── Session
├── Session
└── Session

Project
├── Session
└── Session
```

The layout must never visually flatten this hierarchy.

---

## 7.1 Project Bubble

A project bubble should contain:

```text
[project icon]  Project Name             [state/chevron]
```

Possible states:

- inactive;
- active;
- expanded;
- collapsed;
- loading;
- attention required.

A project bubble is a parent.

Sessions belonging to it must visually remain associated with it.

---

## 7.2 Session Bubble

A session bubble represents one OpenCode conversation/session/tab.

It should contain:

```text
Session Name
```

Optionally:

- small status;
- unread indicator;
- running indicator;
- error marker;
- plan/build state.

Do not overload it with many icons.

---

## 7.3 Close Bubble

In the detailed vertical view, each session has an independent circular close bubble placed to the left.

Example:

```text
(x) [ Refactor API ]
```

The close bubble should:

- close the session;
- request confirmation only when necessary;
- remain visually separate from the session bubble;
- use the same spacing for every session.

The close control must not overlap the project bubble or session bubble.

---

# 8. Compact View

## 8.1 Purpose

Compact View is intended for:

- smaller windows;
- split-screen use;
- laptop-sized layouts;
- users focused on one active project/session;
- fast switching between a small number of open sessions.

It sacrifices persistent project hierarchy for horizontal efficiency.

---

## 8.2 Overall Layout

The component order is:

```text
[traffic lights] [sidebar toggle] [project/session] [project/session] [project/session] [new]

                  ╭──────────────────────────────────╮
                  │                                  │
                  │            WORKFRAME             │
                  │                                  │
                  ╰──────────────────────────────────╯

        (attachment) [        message input        ] (send)
```

Everything is horizontally centered around the workframe.

No background surface joins these rows.

---

## 8.3 Top Navigation Row

The top navigation row contains floating controls in this order:

1. traffic lights;
2. sidebar/view toggle;
3. currently open project/session pills;
4. new session or new context button.

The row should use one baseline.

Controls must not appear randomly offset vertically.

---

## 8.4 Project/Session Representation

Compact mode intentionally compresses hierarchy.

Each open context may appear as one pill.

Examples:

```text
[ Beeline ]
[ Cubics ]
[ Voxel Engine ]
```

or:

```text
[ Beeline / Refactor API ]
[ Cubics / UI Polish ]
```

The exact text presentation can adapt to available width.

### Active item

The active item should have:

- stronger fill;
- stronger text;
- slightly stronger shadow;
- possibly active project icon.

### Inactive items

Use lighter styling.

---

## 8.5 Horizontal Overflow

When too many contexts are open:

- do not wrap to a second row;
- do not shrink pills until text becomes unreadable;
- do not push the workframe downward unpredictably.

Preferred behavior:

1. preserve the leading window/global controls;
2. preserve the active session;
3. horizontally scroll or collapse less relevant tabs;
4. optionally expose an overflow bubble.

Example:

```text
[●●●] [▣] [Beeline] [Cubics] [Voxel] […] [+]
```

The active item should always remain visible.

---

## 8.6 New Session Button

The final circular button in the row creates a new session/context.

It is not an attachment button.

This is acceptable because its context and location are different.

Its function should be obvious through:

- position;
- hover label;
- accessibility label.

---

## 8.7 Compact View With Internal Side Panels

The workframe may contain temporary internal panels.

Examples:

- file browser;
- task plan;
- search filters;
- code review file list.

These panels belong **inside the workframe**.

They are not the same as the global project/session navigation.

Example:

```text
TOP FLOATING PROJECT STRIP

╭──────────────────────────────────────╮
│ Files │                              │
│       │      active code review      │
│       │                              │
╰──────────────────────────────────────╯

BOTTOM FLOATING INPUT
```

This distinction is important.

---

## 8.8 Compact Planning State

For planning:

- top project/session controls remain unchanged;
- workframe may split into a task list and conversation;
- current plan step may be highlighted;
- plan cards remain inside the workframe.

The external UI should not rearrange itself simply because the active tool changed.

---

## 8.9 Compact Code Review State

For code review:

- external controls remain unchanged;
- internal workframe may show file list;
- diff is the dominant internal surface;
- comments can be attached to diff lines.

The project/session strip remains stable above.

---

## 8.10 Compact Search State

For search:

- external controls remain unchanged;
- search UI appears inside workframe;
- results should be structured and clickable;
- file type/path/result count may be displayed.

Do not create a separate floating search window.

---

# 9. Detailed View

## 9.1 Purpose

Detailed View is intended for:

- large displays;
- wide application windows;
- users working across many sessions;
- users managing multiple projects;
- long-running coding workflows;
- subagent-heavy workflows.

It exposes project hierarchy persistently.

---

## 9.2 Overall Layout

The detailed layout is:

```text
[traffic lights] [sidebar control]

[ Project A ]        ╭──────────────────────────────╮
 (x) [ Session 1 ]   │                              │
 (x) [ Session 2 ]   │                              │
 (x) [ Session 3 ]   │          WORKFRAME           │
                     │                              │
[ Project B ]        │                              │
 (x) [ Session 1 ]   ╰──────────────────────────────╯
 (x) [ Session 2 ]

[ Project C ]             (attach) [ input ] (send)
 (x) [ Session 1 ]

[ + New Project ]
```

The sidebar and the workframe are visually independent.

There is no full-height sidebar background.

---

# 10. Detailed View Sidebar

## 10.1 Sidebar Is Not a Panel

The left project stack must not be rendered as:

```text
┌─────────────────┐
│ project         │
│ session         │
│ session         │
│ project         │
│ session         │
└─────────────────┘
```

It should be:

```text
[ Project ]

 (x) [ Session ]
 (x) [ Session ]

[ Project ]

 (x) [ Session ]
```

with the desktop/root background visible between and around components.

This is essential to the design.

---

## 10.2 Project Group Order

Each project group is:

1. project bubble;
2. vertical gap;
3. first session row;
4. next session row;
5. remaining sessions;
6. larger group gap before next project.

Example:

```text
[ Beeline        v ]
   (x) [ Chat 1       ]
   (x) [ Refactor API ]
   (x) [ Design       ]

         larger gap

[ Cubics         v ]
   (x) [ Chat 1       ]
   (x) [ Animation    ]
```

The session bubbles must never be placed over or inside the project bubble.

---

## 10.3 Session Indentation

Sessions should be visually subordinate to projects.

Possible methods:

- session pill begins slightly farther right;
- close bubble sits in a left gutter;
- project bubble is slightly wider;
- session pill has lighter fill;
- project text is slightly heavier.

Example:

```text
[ Project ---------------- ]

   (x) [ Session -------- ]
   (x) [ Session -------- ]
```

Do not over-indent.

The structure should remain compact.

---

## 10.4 Close Control Placement

Every session row uses:

```text
(x) [ session name ]
```

The close circle:

- uses a fixed diameter;
- aligns to the vertical center of the session pill;
- uses fixed spacing from the session pill;
- does not shift based on title length.

Hover may reveal stronger contrast.

---

## 10.5 Project Expansion

A project bubble may be collapsed.

Expanded:

```text
[ Beeline      v ]
 (x) [ Chat 1 ]
 (x) [ Chat 2 ]
```

Collapsed:

```text
[ Beeline      > ]
```

Collapsing a project hides its session bubbles but does not close sessions.

---

## 10.6 Selected Project

The active project should be distinguishable by:

- slightly stronger fill;
- stronger icon treatment;
- stronger text;
- possibly a subtle glow/shadow change.

Do not make the entire project group one giant highlighted block.

Each element remains independent.

---

## 10.7 Selected Session

The active session pill is highlighted independently of its project.

Example:

```text
[ Beeline ]

 (x) [ Chat 1       ]   ← normal
 (x) [ Refactor API ]   ← active
 (x) [ Design       ]   ← normal
```

This allows the user to see both:

- which project is active;
- which session within it is active.

---

## 10.8 Project Count

When many projects exist, the project stack should scroll independently.

The workframe must not move because the project list becomes longer.

Use a transparent `ScrollView`.

Do not add a visible rectangular scroll-container background.

Scroll indicators can be:

- hidden by default;
- visible on interaction;
- styled minimally.

---

## 10.9 New Project Control

At the bottom of the project stack:

```text
[ + New Project ]
```

This is a floating pill.

It should not be permanently attached to a sidebar background.

Depending on scroll behavior, it may:

- live after the final project;
- remain pinned to the lower sidebar region.

Pinned behavior is acceptable if it does not visually create a panel.

---

# 11. Detailed View Workframe

The detailed view workframe should usually be larger than the compact view workframe.

It should provide more horizontal space for:

- larger diffs;
- split code views;
- terminal output;
- project summaries;
- agent activity;
- file previews.

The left project stack should not reduce the workframe more than necessary.

The workframe remains the dominant object.

---

# 12. Detailed View Browsing State

When browsing projects, the workframe may show a project overview.

Example content:

```text
Project Summary

Recent sessions
Recent files
Recent agent actions
Current branch
Pending tasks
```

The project sidebar still behaves normally.

A collapsed project remains represented only by its project bubble.

An expanded project shows its sessions below.

---

# 13. Detailed View Active Coding State

During active coding, the workframe may show:

- conversation;
- tool execution;
- terminal commands;
- tests;
- subagent activity;
- applied patch status;
- code output.

The project stack should remain stable.

A long-running agent must not cause the sidebar to reposition.

---

# 14. Subagent Presentation

The mockups allow room for future subagent UI.

Subagents should be represented inside the workframe, not as additional outer floating windows.

Possible presentation:

```text
Agent Activity
────────────────────
Explorer      complete
Planner       complete
Implementer   running
Reviewer      queued
```

or cards embedded in conversation.

If a subagent creates a persistent conversation/session, it may later become a session bubble.

Do not automatically add every temporary tool invocation to the sidebar.

---

# 15. Responsive Layout Switching

## 15.1 Layout Modes

The application should support:

- compact horizontal mode;
- detailed vertical mode;
- optional user-forced mode.

A breakpoint can select the default.

However, manual selection should override automatic behavior.

---

## 15.2 Transition

Switching between layouts should animate position, not recreate the visual system.

Conceptually:

```text
horizontal pills
      ↓
reorganize
      ↓
vertical project stack
```

The workframe should appear to remain the same object.

Useful SwiftUI tools:

- matched geometry;
- spring animation;
- shared component IDs.

Avoid crossfading the whole application.

---

## 15.3 Narrow Detailed View

If the user keeps detailed mode active in a narrow window:

- reduce sidebar width;
- truncate project/session names;
- preserve close bubbles;
- preserve workframe minimum width;
- allow sidebar collapse.

Do not overlap the sidebar on top of the workframe unless deliberately entering an overlay mode.

---

# 16. Interaction Behavior

## 16.1 Hover

Desktop controls should respond to hover.

Possible hover effects:

- small elevation increase;
- slight fill change;
- close icon becomes stronger;
- tooltip after delay.

Do not scale buttons aggressively.

---

## 16.2 Selection

Clicking a project:

- makes it active;
- may select its most recent session if no child session is already active;
- expands it in detailed mode if appropriate.

Clicking a session:

- activates that session;
- updates the workframe;
- updates the message input context.

---

## 16.3 Reordering

Projects and sessions should eventually support drag reordering.

Detailed mode:

- project groups move as units;
- sessions can reorder within a project;
- moving a session between projects should only be permitted if the data model supports it.

Compact mode:

- open context pills can reorder horizontally.

Reordering should not interfere with normal click selection.

---

## 16.4 Context Menus

Right-click project bubble:

- rename;
- reveal/open project;
- close project;
- project settings;
- new session.

Right-click session bubble:

- rename;
- duplicate/fork if supported;
- close;
- pin;
- copy session identifier if useful.

Menus should use standard macOS menu behavior.

---

# 17. Keyboard Behavior

The interface should remain fully usable without the pointer.

Recommended behavior:

- next session;
- previous session;
- next project;
- previous project;
- toggle detailed/compact view;
- toggle sidebar;
- focus message input;
- new session;
- close current session;
- open command/search UI.

Keyboard focus should visibly indicate the focused floating control.

---

# 18. Drag and Drop

## 18.1 Attachments

Files dropped:

- on input field;
- on attachment bubble;
- optionally on workframe;

should attach to the current prompt where valid.

A temporary drop target can appear.

Do not create a permanent drag area.

---

## 18.2 Project Opening

Dropping a folder onto the application may offer:

```text
Open as Project
```

The resulting project appears as a normal project bubble.

---

# 19. Workframe Internal Design

## 19.1 Conversation Messages

Messages should use relatively restrained bubbles.

Avoid creating one giant colored bubble around long assistant responses.

Assistant responses can use:

- icon;
- text;
- embedded cards;
- code blocks.

User messages can use a distinct compact bubble.

---

## 19.2 Code Cards

Code cards should support:

- language label;
- copy;
- optional file name;
- line numbers;
- horizontal scrolling;
- syntax highlighting.

They should use a darker or otherwise clearly distinct surface when appropriate.

---

## 19.3 Diff Cards

Diff cards should support:

- unified mode;
- side-by-side mode;
- file title;
- added/removed counts;
- inline comments;
- copy;
- open file.

Large diffs can use the workframe width in detailed mode.

---

## 19.4 Task Plan Cards

Task cards should support:

- title;
- status;
- completed steps;
- active step;
- pending steps;
- collapsed/expanded state.

They belong inside the conversation.

---

## 19.5 Terminal Cards

Terminal cards should support:

- command;
- live output;
- success/failure state;
- expandable logs;
- copy.

The terminal card should not visually mimic an entire terminal application.

It is content inside the OpenCode session.

---

# 20. States and Status

Floating bubbles may need small status indicators.

Possible session states:

- idle;
- running;
- waiting for permission;
- completed;
- failed;
- unread output.

Use minimal indicators:

```text
●
```

or a small badge.

Avoid filling the sidebar with status text.

---

# 21. Accessibility

All custom controls must expose standard accessibility semantics.

Required:

- meaningful labels;
- selected state;
- expanded/collapsed state;
- close action;
- keyboard navigation;
- sufficient hit targets;
- sufficient contrast.

Do not make the visual circle the exact hit area if it becomes too small.

The hit region may be larger than the drawn control.

---

# 22. Animation

Animations should reinforce hierarchy.

Use animation for:

- project expand/collapse;
- compact ↔ detailed transition;
- session selection;
- opening/closing sessions;
- insertion/removal of projects;
- input expansion;
- agent status changes.

Avoid:

- constant pulsing;
- large bounces;
- long decorative transitions;
- moving the workframe unnecessarily.

Preferred motion should feel:

- quick;
- soft;
- controlled;
- spatially understandable.

---

# 23. SwiftUI and AppKit Boundary

## 23.1 Keep SwiftUI in Control of Layout

The floating visual design is fully achievable in SwiftUI.

Do not move to AppKit simply because the controls look unusual.

SwiftUI is suitable for:

- stacks;
- overlays;
- custom shapes;
- transparent backgrounds;
- shadows;
- hover;
- animations;
- drag/drop;
- scroll views;
- matched geometry.

---

## 23.2 Use AppKit for the Window

AppKit is recommended for the outer window because the client requires non-standard chrome.

Use an `NSWindow` configuration that allows:

- titlebar hiding;
- transparent titlebar/background;
- custom drag regions;
- native resizing;
- native macOS window behavior.

Embed the SwiftUI root using `NSHostingView` or SwiftUI's application lifecycle with window customization.

---

## 23.3 Code Editor

Start with SwiftUI for code display.

If editing becomes a major feature, use an AppKit-backed editor component.

A custom `NSTextView` wrapper is preferable to forcing a complex code editor into a basic SwiftUI `TextEditor`.

Potential later options include:

- custom `NSTextView`;
- Tree-sitter-backed highlighting;
- CodeMirror/Monaco in `WKWebView` only if a web editor is intentionally accepted.

For a native macOS client, prefer a native AppKit text component before embedding a browser editor.

---

# 24. Component Layout Summary

## Compact View

```text
TOP ROW

[ traffic ]
[ sidebar ]
[ project/session ]
[ project/session ]
[ project/session ]
[ new ]

MAIN

╭────────────────────────────────────────╮
│                                        │
│               WORKFRAME                │
│                                        │
╰────────────────────────────────────────╯

INPUT

(attach) [               input               ] (send)
```

---

## Detailed View

```text
LEFT                                      RIGHT

[ traffic ] [ sidebar ]

[ Project A ]                             ╭─────────────────────────────╮
 (x) [ Session A1 ]                       │                             │
 (x) [ Session A2 ]                       │                             │
 (x) [ Session A3 ]                       │          WORKFRAME          │
                                          │                             │
[ Project B ]                             │                             │
 (x) [ Session B1 ]                       ╰─────────────────────────────╯
 (x) [ Session B2 ]

[ Project C ]                                  (attach) [ input ] (send)
 (x) [ Session C1 ]

[ + New Project ]
```

---

# 25. Non-Goals

The implementation must not drift into a conventional desktop shell.

Do not add:

- full-window opaque background;
- permanent full-width toolbar;
- permanent rectangular sidebar panel;
- large titlebar;
- duplicated controls;
- floating chat windows for every session;
- overlapping session bubbles;
- session bubbles placed on top of project bubbles;
- random bubble positioning;
- inconsistent spacing;
- unrelated card styles;
- excessive glassmorphism;
- unnecessary gradients.

The defining visual feature is **structured floating UI**, not generic translucent panels.

---

# 26. Acceptance Criteria

The design implementation is correct when:

- the main workframe is visually independent;
- the root window has no visible large background panel;
- all navigation controls appear to float around the workframe;
- compact mode uses one horizontal navigation row;
- detailed mode uses project groups stacked vertically;
- every detailed-mode session is visibly associated with one project;
- session bubbles never overlap project bubbles;
- every detailed-mode session has a separate close bubble on its left;
- the attachment button appears only once and sits left of the input field;
- the send button appears at the right of the input field;
- spacing is uniform;
- active project and session are immediately clear;
- internal tool states appear inside the workframe;
- changing tools does not rearrange the outer interface;
- layout switching retains the same visual component language;
- the interface still looks intentional with several projects and many sessions open.

---

# Conclusion

The OpenCode client should feel less like a conventional macOS application shell and more like a focused workspace assembled from independent, structured controls.

The **workframe is the anchor**.

Everything else exists around it:

- projects;
- sessions;
- window controls;
- attachments;
- message input;
- send controls.

Compact View organizes these controls horizontally for limited space and fast switching.

Detailed View exposes the full project hierarchy vertically, with each project owning a clearly separated stack of session bubbles.

Both views must preserve the same rules:

- no opaque background window panel behind everything;
- no unnecessary duplication;
- no ambiguous hierarchy;
- no overlapping project/session controls;
- consistent floating geometry;
- consistent input placement;
- one shared workframe design.

The preferred implementation is **SwiftUI-first**, using custom SwiftUI components for the full visual system, with **AppKit used selectively for macOS window behavior and any advanced native editing requirements**.

This keeps the application visually unconventional without making the implementation unnecessarily unconventional.
