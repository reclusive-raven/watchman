# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working rules

Follow global instructions. Run focused checks of changed behavior and affected dependencies; ordinary web checks need one suitable local browser, with no blanket OS or architecture matrix. Project testing runs locally on the Mac; use UTM only for actual OS-specific needs. Preserve the separate ML worker workflow.

Before work, read the relevant sections of [the project reference](agent_reference.md) for commands, subsystem constraints and procedures. Its detailed rules still apply. Keep this file to essential instructions; update the reference when procedures change.

## Reference sections

[What Is Watchman](agent_reference.md#what-is-watchman) · [Build & Deploy Commands](agent_reference.md#build--deploy-commands) · [Agent (Rust, cross-compiled for Linux)](agent_reference.md#agent-rust-cross-compiled-for-linux) · [One-time: grant read access to RAPL counters so cpu_w is non-null.](agent_reference.md#one-time-grant-read-access-to-rapl-counters-so-cpu_w-is-non-null) · [App (Swift/SwiftUI)](agent_reference.md#app-swiftswiftui) · [Architecture](agent_reference.md#architecture) · [Agent (`agent/src/`)](agent_reference.md#agent-agentsrc) · [App (`app/Watchman/`)](agent_reference.md#app-appwatchman) · [SQLite Schema](agent_reference.md#sqlite-schema) · [Thresholds](agent_reference.md#thresholds) · [Gotchas](agent_reference.md#gotchas) · [Git workflow](agent_reference.md#git-workflow)
