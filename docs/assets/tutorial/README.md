# Tutorial screenshots

## Windows demonstration screenshots

Captured from a real, visible WispTerm Windows window on 2026-09-11, built locally with `zig build` from commit `aca086115d20b12e3e0fee42c2ad14740a7f9875`.

The capture process follows the PowerShell/Win32 workflow in `docs/development.md`: activate the target window, navigate the UI, and capture pixels from its bounds. Form images capture only the observed dialog region. Images are not generated mockups or recolored to follow the website theme.

The application runs with an isolated APPDATA directory and Chinese UI, using illustrative SSH profiles (`gpu.example.com`, `cpu.example.com`), a blank API key, and explicitly labeled sample conversations and memories. No personal histories, private keys, or live server credentials are used. Forwarding rules remain stopped and no model API or SSH login is performed for these screenshots.

Images cover the session launcher, AI profile form, SSH form, Conversation Center, Memory Center, memory source settings, forwarding list and forwarding form. Full workbench captures are 1600 × 1000 pixels; dialog regions retain their original capture resolution. Every image is linked to its original PNG in the tutorial.

## macOS LLM configuration screenshots

Captured from the installed WispTerm 1.40.6 macOS app on 2026-10-25 using Computer Use. These are original JPEG window captures, without generated UI, cropping, or image retouching. Menu captures use a 680 × 600 window; form captures use a 1100 × 920 window so all fields and actions fit.

| File | Visible step |
| --- | --- |
| `llm-manage-command-macos.jpg` | Command Center with Manage AI Profiles selected |
| `llm-new-entry-macos.jpg` | New LLM Provider selected in the management list |
| `llm-new-form-macos.jpg` | New profile form, with the API key blank |
| `llm-edit-entry-macos.jpg` | Edit LLM Provider selected in the management list |
| `llm-edit-select-macos.jpg` | Existing profile selected for editing |
| `llm-edit-form-macos.jpg` | Existing values loaded, with Save selected |

The existing `Opencode` profile is used only to show the editing workflow. Its API key stays masked by the application; no credential was read, entered, changed, or saved. No profile was created or updated, and no model request was sent. Forms were dismissed after capture. The endpoint and model shown in the existing profile are not a recommended configuration; readers should use their provider's current values. Default values may differ between app versions. The tutorial captions distinguish these macOS captures from the Windows demonstration set above.
