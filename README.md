# Dutch

Dutch is an iOS SwiftUI app for scanning receipts, splitting shared expenses, and settling balances with friends.

## Features

- Receipt and statement upload from camera or photo library
- Local Apple Vision OCR for receipt parsing
- Manual entry for transactions and items
- People and group-based bill splitting
- Review screen for editing items, totals, payers, and participants
- Settlement calculation for who owes whom
- Venmo and Zelle profile/payment setup
- Shareable settlement summaries

## Project

Open the workspace, not the project file:

```bash
open Dutch.xcworkspace
```

Main app scheme:

```text
Dutch
```

Build from terminal:

```bash
xcodebuild -workspace Dutch.xcworkspace -scheme Dutch -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Repository Structure

```text
Dutch.xcworkspace/          Xcode workspace
Dutch.xcodeproj/            Xcode project
Dutchi/                     Main iOS app source
DutchiShareExtension/       Share extension
Pods/                       CocoaPods dependencies
Podfile                     CocoaPods target configuration
database.rules.json         Firebase database rules
```

Note: the visible app/workspace name is `Dutch`, while some internal source folders and CocoaPods target names still use `Dutchi`.

## Requirements

- Xcode
- iOS 16+
- CocoaPods dependencies installed through the checked-in workspace
- Swift Package dependencies resolved by Xcode

## GitHub

Current remote:

```text
https://github.com/thkang091/Dutch.git
```

Commit and push changes:

```bash
git add -A
git commit -m "Update Dutch app"
git push
```
