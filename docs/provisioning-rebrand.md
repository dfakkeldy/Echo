# Provisioning Profile Rebrand Guide

**Branch:** `feat/code-audit-remaining`
**Date:** 2026-06-10
**Context:** All `com.orbit*` identifiers were migrated to `com.echo.*` (§9.5 of CODE_AUDIT.md). The code compiles clean but device builds fail until provisioning profiles are regenerated.

---

## Prerequisites: Create these two first

Go to **[developer.apple.com](https://developer.apple.com/account)** → **Certificates, Identifiers & Profiles** → **Identifiers**.

### App Group

Click **+** → **App Groups**:

| Field | Value |
|-------|-------|
| Description | `Echo Audiobooks` |
| Identifier | `group.com.echo.audiobooks` |

Click **Continue** → **Register**.

### iCloud Container

Click **+** → **iCloud Containers**:

| Field | Value |
|-------|-------|
| Description | `Echo Audiobooks` |
| Identifier | `iCloud.com.echo.audiobooks` |

Click **Continue** → **Register**.

---

## Configure each App ID

For each bundle ID below, go to **Identifiers** → **App IDs** → click **+** (or edit an existing one), then the **Capabilities** tab.

> The capabilities list is scrollable. Some options (Network Client, User Selected File) only appear as sub-options after you check their parent capability (App Sandbox).

---

### 1. iOS: `com.echo.audiobooks`

| Capability | Where to find it | What to select |
|-----------|-----------------|----------------|
| **App Groups** | Scroll to "App Groups", check it | Click **Configure** → check `group.com.echo.audiobooks` |
| **iCloud** | Scroll to "iCloud", check it | Check **CloudKit** → under "Containers" select `iCloud.com.echo.audiobooks` |
| CarPlay Audio | _(skip for now — commented out in entitlements)_ | |

---

### 2. macOS: `com.echo.audiobooks.macos`

| Capability | Where to find it | What to select |
|-----------|-----------------|----------------|
| **App Sandbox** | Top of the list, check it | Enables sub-capabilities below |
| **Outgoing Connections** | Under App Sandbox → "Network" | Check **Outgoing Connections (Client)** |
| **User Selected File** | Under App Sandbox → "File Access" | Set **User Selected File** to **Read/Write** |
| **App-Scope Bookmarks** | Under App Sandbox → "File Access" | Check **Security-Scoped Bookmarks for App** |
| **App Groups** | Scroll to "App Groups", check it | Click **Configure** → check `group.com.echo.audiobooks` |
| **iCloud** | Scroll to "iCloud", check it | Check **CloudKit** → under "Containers" select `iCloud.com.echo.audiobooks` |

---

### 3. watchOS App: `com.echo.audiobooks.watchkitapp`

| Capability | What to select |
|-----------|----------------|
| **App Groups** | Check → `group.com.echo.audiobooks` |

---

### 4. watchOS Extension: `com.echo.audiobooks.watchkitapp.widget`

| Capability | What to select |
|-----------|----------------|
| **App Groups** | Check → `group.com.echo.audiobooks` |

---

## Provisioning Profiles

Your project uses **automatic signing** (`CODE_SIGN_STYLE = Automatic`), so you don't need to manually create provisioning profiles.

After registering the App IDs above:

1. In Xcode: **Product** → **Clean Build Folder** (⇧⌘K)
2. **Product** → **Build** (⌘B)

Xcode will detect the new bundle IDs, match them to the App IDs you registered, and generate provisioning profiles automatically.

If Xcode reports a signing error about the team, go to **Xcode → Settings → Accounts**, select your Apple ID, and click the refresh icon.

---

## IAP Product (post-release setup)

In **[App Store Connect](https://appstoreconnect.apple.com)** → your app record → **In-App Purchases** → **+**:

| Field | Value |
|-------|-------|
| Type | Non-Consumable |
| Reference Name | `Echo Pro Unlock` |
| Product ID | `com.echo.pro.unlock` |

This can wait until you create the App Store Connect app record — it's not needed for development builds.

---

## One-time caveat

After the first build with new profiles, the app gets a **fresh sandbox container**. Existing development data stored under the old `group.com.orbitaudiobooks` container won't carry over. For development, you'll start with clean state. The `Persistence.swift` migration handles UserDefaults key migration automatically, but the underlying sandbox directory path changes.

---

## Current entitlements reference

### iOS (`EchoCore/EchoCore.entitlements`)
- App Groups: `group.com.echo.audiobooks`
- iCloud: `iCloud.com.echo.audiobooks` (CloudKit, Development environment)

### macOS (`Echo macOS/Echo_macOS.entitlements`)
- App Sandbox
- App Groups: `group.com.echo.audiobooks`
- Network Client (outgoing connections)
- User Selected File: Read/Write
- App-Scope Bookmarks
- iCloud: `iCloud.com.echo.audiobooks` (CloudKit, Development environment)

### Watch App (`Echo Watch App/EchoWatchApp.entitlements`)
- App Groups: `group.com.echo.audiobooks`

### Widget (`Echo Widget/EchoWidget.entitlements`)
- App Groups: `group.com.echo.audiobooks`

---

## Cleanup (optional)

Once the new profiles are working, you can remove the old `com.orbit*` App IDs from the developer portal. Don't delete them until you've confirmed the new setup works on device.
