//! Fonts that are embedded with Phantty as fallbacks.
//! These are only used if the requested font cannot be found via the system font backend.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.
//!
//! JetBrains Mono is licensed under the SIL Open Font License 1.1.

/// Default fallback font - JetBrains Mono Regular
pub const regular = @embedFile("res/JetBrainsMono-Regular.ttf");

/// Bold variant
pub const bold = @embedFile("res/JetBrainsMono-Bold.ttf");
